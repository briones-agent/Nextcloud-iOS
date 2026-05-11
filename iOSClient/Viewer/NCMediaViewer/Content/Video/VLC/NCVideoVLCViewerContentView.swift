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
/// This view only mounts the stable UIKit VLC controller.
/// It must never start playback by itself.
struct NCVideoVLCViewerContentView: UIViewControllerRepresentable {
    let metadata: tableMetadata
    let url: URL
    let userAgent: String?
    let shouldAutoPlay: Bool

    func makeUIViewController(context: Context) -> NCVideoVLCViewController {
        NCVideoVLCStablePlayer.shared.viewController
    }

    func updateUIViewController(
        _ viewController: NCVideoVLCViewController,
        context: Context
    ) {
        // Intentionally empty.
        // SwiftUI can call this during swipe, prefetch, rotation, and layout rebuilds.
        // Playback is controlled only by NCVideoViewerContentView.
    }

    static func dismantleUIViewController(
        _ viewController: NCVideoVLCViewController,
        coordinator: Coordinator
    ) {
        // Do not stop here.
        // SwiftUI can dismantle/rebuild this bridge during rotation or layout changes.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator { }
}

// MARK: - VLC Stable Player Owner

/// Stable owner for the UIKit VLC controller.
///
/// This object keeps one UIKit controller and one VLCMediaPlayer alive across
/// SwiftUI rebuilds.
@MainActor
final class NCVideoVLCStablePlayer {
    static let shared = NCVideoVLCStablePlayer()

    let viewController = NCVideoVLCViewController()

    private init() { }

    /// Configures the shared VLC controller and starts playback when requested.
    ///
    /// - Parameters:
    ///   - metadata: Video metadata used for logging.
    ///   - url: Local or remote playable URL.
    ///   - userAgent: Optional HTTP User-Agent for remote playback.
    ///   - shouldAutoPlay: Whether playback should start.
    func configure(
        metadata: tableMetadata,
        url: URL,
        userAgent: String?,
        shouldAutoPlay: Bool
    ) {
        viewController.configure(
            metadata: metadata,
            url: url,
            userAgent: userAgent,
            shouldAutoPlay: shouldAutoPlay
        )
    }

    /// Pauses the shared VLC player without releasing media.
    ///
    /// Use this when the page loses selection.
    func pause() {
        viewController.pause()
    }

    /// Stops the shared VLC player and releases media.
    ///
    /// Use this only when the whole media viewer closes.
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
    private var shouldAutoPlay = false

    private var loadedURL: URL?
    private var isViewVisible = false
    private var needsDrawableRefresh = false

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

    /// Configures and starts VLC only when explicitly requested by the selected page.
    ///
    /// - Parameters:
    ///   - metadata: Video metadata used for logging.
    ///   - url: Local or remote playable URL.
    ///   - userAgent: Optional HTTP User-Agent for remote playback.
    ///   - shouldAutoPlay: Whether playback should start.
    func configure(
        metadata: tableMetadata,
        url: URL,
        userAgent: String?,
        shouldAutoPlay: Bool
    ) {
        self.metadata = metadata
        self.userAgent = userAgent
        self.shouldAutoPlay = shouldAutoPlay

        guard shouldAutoPlay else {
            return
        }

        if self.url != url {
            self.url = url
            loadedURL = nil

            mediaPlayer.stop()
            mediaPlayer.media = nil
            mediaPlayer.drawable = nil
            needsDrawableRefresh = true
        }

        startIfPossible()
    }

    /// Pauses VLC playback without releasing media.
    func pause() {
        shouldAutoPlay = false
        mediaPlayer.pause()

        log(
            emoji: .debug,
            message: "VIDEO VLC pause requested"
        )
    }

    /// Stops VLC playback and releases media.
    func stop() {
        log(
            emoji: .debug,
            message: "VIDEO VLC stop requested"
        )

        shouldAutoPlay = false

        mediaPlayer.stop()
        mediaPlayer.media = nil
        mediaPlayer.drawable = nil

        url = nil
        loadedURL = nil
        metadata = nil
        needsDrawableRefresh = false
    }

    // MARK: - Playback

    private func startIfPossible() {
        guard shouldAutoPlay else {
            return
        }

        guard isViewLoaded,
              isViewVisible,
              view.window != nil else {
            return
        }

        attachDrawableIfNeeded()
        loadMediaIfNeeded()
        refreshDrawableAfterMediaChangeIfNeeded()

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

        needsDrawableRefresh = true

        log(
            emoji: .debug,
            message: "VIDEO VLC media loaded url \(url.absoluteString), isFileURL \(url.isFileURL)"
        )
    }

    private func refreshDrawableAfterMediaChangeIfNeeded() {
        guard needsDrawableRefresh else {
            return
        }

        guard drawableView.bounds.width > 0,
              drawableView.bounds.height > 0 else {
            return
        }

        mediaPlayer.drawable = nil
        mediaPlayer.drawable = drawableView
        needsDrawableRefresh = false

        log(
            emoji: .debug,
            message: "VIDEO VLC drawable refreshed after media change bounds \(drawableView.bounds)"
        )
    }

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
