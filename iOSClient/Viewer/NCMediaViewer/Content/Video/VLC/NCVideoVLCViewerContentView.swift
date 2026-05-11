// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import SwiftUI
import UIKit
import MobileVLCKit
import NextcloudKit

// MARK: - VLC Viewer SwiftUI Bridge

/// Minimal SwiftUI bridge for VLC playback.
///
/// This bridge always returns the same UIKit controller instance.
/// This prevents SwiftUI rotation/layout rebuilds from creating multiple VLC players.
struct NCVideoVLCViewerContentView: UIViewControllerRepresentable {
    let metadata: tableMetadata
    let url: URL
    let userAgent: String?
    let shouldAutoPlay: Bool

    func makeUIViewController(context: Context) -> NCVideoVLCViewController {
        let viewController = NCVideoVLCStablePlayer.shared.viewController

        viewController.configure(
            metadata: metadata,
            url: url,
            userAgent: userAgent,
            shouldAutoPlay: shouldAutoPlay
        )

        return viewController
    }

    func updateUIViewController(
        _ viewController: NCVideoVLCViewController,
        context: Context
    ) {
        viewController.configure(
            metadata: metadata,
            url: url,
            userAgent: userAgent,
            shouldAutoPlay: shouldAutoPlay
        )
    }

    static func dismantleUIViewController(
        _ viewController: NCVideoVLCViewController,
        coordinator: Coordinator
    ) {
        // Do not stop VLC here.
        // SwiftUI can dismantle/rebuild during rotation.
        // Playback lifetime is owned by NCVideoVLCStablePlayer.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator { }
}

// MARK: - VLC Stable Player Owner

/// Stable owner for the UIKit VLC controller.
///
/// The controller and VLCMediaPlayer survive SwiftUI view rebuilds.
@MainActor
final class NCVideoVLCStablePlayer {
    static let shared = NCVideoVLCStablePlayer()

    let viewController = NCVideoVLCViewController()

    private init() { }

    /// Stops the shared VLC player explicitly.
    func stop() {
        viewController.stop()
    }
}

// MARK: - VLC View Controller

/// Minimal UIKit-only VLC video controller.
///
/// This controller intentionally does only:
/// - keep one stable drawable view
/// - keep one stable VLCMediaPlayer
/// - load and play the requested URL
///
/// No controls.
/// No overlays.
/// No rotation hacks.
/// No SwiftUI state.
@MainActor
final class NCVideoVLCViewController: UIViewController {

    // MARK: - Views

    private let drawableView = UIView()

    // MARK: - VLC

    private let mediaPlayer = VLCMediaPlayer()

    // MARK: - State

    private var metadata: tableMetadata?
    private var url: URL?
    private var userAgent: String?
    private var shouldAutoPlay = true

    private var loadedURL: URL?
    private var isViewVisible = false

    // MARK: - Lifecycle

    override func loadView() {
        let rootView = UIView()
        rootView.backgroundColor = .black
        rootView.isOpaque = true
        rootView.clipsToBounds = true

        drawableView.backgroundColor = .black
        drawableView.isOpaque = true
        drawableView.clipsToBounds = true
        drawableView.translatesAutoresizingMaskIntoConstraints = false

        rootView.addSubview(drawableView)

        NSLayoutConstraint.activate([
            drawableView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            drawableView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            drawableView.topAnchor.constraint(equalTo: rootView.topAnchor),
            drawableView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])

        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        configureAudioSession()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        isViewVisible = true
        startIfPossible()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        isViewVisible = false

        // Do not stop here.
        // Rotation can trigger transient disappearance.
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        attachDrawableIfNeeded()
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(
            to: size,
            with: coordinator
        )

        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.view.layoutIfNeeded()
        }, completion: { [weak self] _ in
            self?.attachDrawableIfNeeded()
        })
    }

    // MARK: - Public API

    /// Configures the VLC controller with the requested video.
    ///
    /// - Parameters:
    ///   - metadata: Video metadata used for logging.
    ///   - url: Local or remote playable URL.
    ///   - userAgent: Optional HTTP User-Agent for remote playback.
    ///   - shouldAutoPlay: Whether playback should start automatically.
    func configure(
        metadata: tableMetadata,
        url: URL,
        userAgent: String?,
        shouldAutoPlay: Bool
    ) {
        self.metadata = metadata
        self.userAgent = userAgent
        self.shouldAutoPlay = shouldAutoPlay

        if self.url != url {
            self.url = url
            loadedURL = nil

            mediaPlayer.stop()
            mediaPlayer.media = nil
        }

        startIfPossible()
    }

    /// Stops VLC playback and releases the current media.
    func stop() {
        mediaPlayer.stop()
        mediaPlayer.media = nil
        mediaPlayer.drawable = nil

        url = nil
        loadedURL = nil
        metadata = nil
    }

    // MARK: - Playback

    /// Starts playback when the view and URL are ready.
    private func startIfPossible() {
        guard isViewLoaded,
              isViewVisible,
              view.window != nil else {
            return
        }

        attachDrawableIfNeeded()
        loadMediaIfNeeded()

        guard shouldAutoPlay else {
            return
        }

        guard mediaPlayer.media != nil else {
            log(
                emoji: .error,
                message: "VIDEO VLC start skipped because media is nil"
            )
            return
        }

        if !mediaPlayer.isPlaying {
            mediaPlayer.play()

            log(
                emoji: .debug,
                message: "VIDEO VLC play requested"
            )
        }
    }

    /// Loads media only when the URL changes or media is missing.
    private func loadMediaIfNeeded() {
        guard let url else {
            return
        }

        guard loadedURL != url ||
              mediaPlayer.media == nil else {
            return
        }

        loadedURL = url

        let media = VLCMedia(url: url)

        if let userAgent,
           !userAgent.isEmpty,
           !url.isFileURL {
            media.addOption(":http-user-agent=\(userAgent)")
        }

        mediaPlayer.media = media

        log(
            emoji: .debug,
            message: "VIDEO VLC media loaded url \(url.absoluteString), isFileURL \(url.isFileURL)"
        )
    }

    /// Attaches the stable drawable view to VLC.
    private func attachDrawableIfNeeded() {
        guard drawableView.bounds.width > 0,
              drawableView.bounds.height > 0 else {
            return
        }

        if let currentDrawable = mediaPlayer.drawable as? UIView,
           currentDrawable === drawableView {
            return
        }

        mediaPlayer.drawable = drawableView

        log(
            emoji: .debug,
            message: "VIDEO VLC drawable attached bounds \(drawableView.bounds)"
        )
    }

    // MARK: - Helpers

    /// Configures the audio session for movie playback.
    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .moviePlayback,
                options: []
            )

            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            log(
                emoji: .error,
                message: "VIDEO VLC audio session error: \(error.localizedDescription)"
            )
        }
    }

    /// Writes a VLC debug log.
    ///
    /// - Parameters:
    ///   - emoji: Log emoji.
    ///   - message: Log message.
    private func log(
        emoji: NKLogTagEmoji,
        message: String
    ) {
        let ocId = metadata?.ocId ?? "-"

        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: emoji,
            message: "\(message), ocId \(ocId)",
            consoleOnly: true
        )
    }
}
