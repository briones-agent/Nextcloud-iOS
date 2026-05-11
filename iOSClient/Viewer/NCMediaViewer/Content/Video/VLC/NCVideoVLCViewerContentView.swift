// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import SwiftUI
import UIKit
import MobileVLCKit
import NextcloudKit

// MARK: - VLC Video Viewer Content View

/// Minimal SwiftUI placeholder for VLC playback.
///
/// This view intentionally contains only:
/// - a UIKit drawable view
/// - one VLCMediaPlayer
/// - one URL
struct NCVideoVLCViewerContentView: View {
    let metadata: tableMetadata
    let url: URL
    let userAgent: String?
    let shouldAutoPlay: Bool

    @StateObject private var playerModel = NCVideoVLCPlaceholderModel()

    init(
        metadata: tableMetadata,
        url: URL,
        userAgent: String? = nil,
        shouldAutoPlay: Bool = true
    ) {
        self.metadata = metadata
        self.url = url
        self.userAgent = userAgent
        self.shouldAutoPlay = shouldAutoPlay
    }

    var body: some View {
        NCVideoVLCDrawableView(
            mediaPlayer: playerModel.mediaPlayer,
            onDrawableReady: {
                playerModel.load(
                    metadata: metadata,
                    url: url,
                    userAgent: userAgent,
                    shouldAutoPlay: shouldAutoPlay
                )
            }
        )
        .background(Color.black)
        .ignoresSafeArea()
        .onDisappear {
            playerModel.stop()
        }
    }
}

// MARK: - VLC Drawable View

/// UIKit drawable surface used directly by MobileVLCKit.
private struct NCVideoVLCDrawableView: UIViewRepresentable {
    let mediaPlayer: VLCMediaPlayer
    let onDrawableReady: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        view.isOpaque = true
        view.clipsToBounds = true

        mediaPlayer.drawable = view

        DispatchQueue.main.async {
            onDrawableReady()
        }

        return view
    }

    func updateUIView(
        _ view: UIView,
        context: Context
    ) {
        if mediaPlayer.drawable == nil {
            mediaPlayer.drawable = view
        }

        DispatchQueue.main.async {
            onDrawableReady()
        }
    }

    static func dismantleUIView(
        _ view: UIView,
        coordinator: Coordinator
    ) {
        // The model owns stop().
        // Do not touch VLC from the drawable teardown.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator { }
}

// MARK: - VLC Placeholder Model

/// Minimal VLC owner used only to test whether VLC can play inside SwiftUI.
@MainActor
private final class NCVideoVLCPlaceholderModel: ObservableObject {
    let mediaPlayer = VLCMediaPlayer()

    private var currentURL: URL?
    private var didStartPlayback = false

    /// Loads and optionally starts playback.
    ///
    /// - Parameters:
    ///   - metadata: Video metadata used for logging.
    ///   - url: Local or remote video URL.
    ///   - userAgent: Optional HTTP User-Agent for remote playback.
    ///   - shouldAutoPlay: Whether playback should start automatically.
    func load(
        metadata: tableMetadata,
        url: URL,
        userAgent: String?,
        shouldAutoPlay: Bool
    ) {
        guard currentURL != url || mediaPlayer.media == nil else {
            if shouldAutoPlay,
               !mediaPlayer.isPlaying,
               !didStartPlayback {
                play(metadata: metadata)
            }

            return
        }

        configureAudioSession()

        currentURL = url
        didStartPlayback = false

        let media = VLCMedia(url: url)

        if let userAgent,
           !userAgent.isEmpty,
           !url.isFileURL {
            media.addOption(":http-user-agent=\(userAgent)")
        }

        mediaPlayer.media = media

        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: .debug,
            message: "VIDEO VLC placeholder media set ocId \(metadata.ocId), url \(url.absoluteString), isFileURL \(url.isFileURL)",
            consoleOnly: true
        )

        guard shouldAutoPlay else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            Task { @MainActor in
                self?.play(metadata: metadata)
            }
        }
    }

    /// Starts VLC playback.
    ///
    /// - Parameter metadata: Video metadata used for logging.
    private func play(metadata: tableMetadata) {
        guard mediaPlayer.media != nil else {
            nkLog(
                tag: NCGlobal.shared.logTagViewer,
                emoji: .error,
                message: "VIDEO VLC placeholder play skipped because media is nil ocId \(metadata.ocId)",
                consoleOnly: true
            )
            return
        }

        mediaPlayer.play()
        didStartPlayback = true

        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: .debug,
            message: "VIDEO VLC placeholder play requested ocId \(metadata.ocId), isPlaying \(mediaPlayer.isPlaying)",
            consoleOnly: true
        )
    }

    /// Stops VLC playback and releases media resources.
    func stop() {
        mediaPlayer.stop()
        mediaPlayer.media = nil
        mediaPlayer.drawable = nil

        currentURL = nil
        didStartPlayback = false
    }

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
            nkLog(
                tag: NCGlobal.shared.logTagViewer,
                emoji: .error,
                message: "VIDEO VLC placeholder audio session error: \(error.localizedDescription)",
                consoleOnly: true
            )
        }
    }
}
