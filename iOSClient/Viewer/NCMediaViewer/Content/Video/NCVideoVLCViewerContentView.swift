// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit
import MobileVLCKit
import NextcloudKit

// MARK: - VLC Video Viewer Content View

/// Displays a video using MobileVLCKit.
///
/// This view is used as fallback when AVFoundation cannot prepare the video.
/// The URL can be either a local file URL or a remote direct-download URL.
struct NCVideoVLCViewerContentView: UIViewRepresentable {
    let metadata: tableMetadata
    let url: URL
    let userAgent: String?
    let shouldAutoPlay: Bool

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

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black

        context.coordinator.attach(
            to: view,
            metadata: metadata,
            url: url,
            userAgent: userAgent,
            shouldAutoPlay: shouldAutoPlay
        )

        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.update(
            metadata: metadata,
            url: url,
            userAgent: userAgent,
            shouldAutoPlay: shouldAutoPlay
        )
    }

    static func dismantleUIView(
        _ view: UIView,
        coordinator: Coordinator
    ) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Coordinator

    final class Coordinator {
        private let mediaPlayer = VLCMediaPlayer()
        private var currentURL: URL?

        /// Attaches VLC to the render view and loads the requested media.
        ///
        /// - Parameters:
        ///   - view: UIView used as VLC drawable target.
        ///   - metadata: Video metadata used for logging.
        ///   - url: Local or remote video URL.
        ///   - userAgent: Optional HTTP User-Agent used for remote playback.
        ///   - shouldAutoPlay: Whether playback should start immediately.
        func attach(
            to view: UIView,
            metadata: tableMetadata,
            url: URL,
            userAgent: String?,
            shouldAutoPlay: Bool
        ) {
            mediaPlayer.drawable = view

            load(
                metadata: metadata,
                url: url,
                userAgent: userAgent,
                shouldAutoPlay: shouldAutoPlay
            )
        }

        /// Updates VLC media only when the URL changes.
        ///
        /// - Parameters:
        ///   - metadata: Video metadata used for logging.
        ///   - url: Local or remote video URL.
        ///   - userAgent: Optional HTTP User-Agent used for remote playback.
        ///   - shouldAutoPlay: Whether playback should start immediately.
        func update(
            metadata: tableMetadata,
            url: URL,
            userAgent: String?,
            shouldAutoPlay: Bool
        ) {
            guard currentURL != url else {
                return
            }

            load(
                metadata: metadata,
                url: url,
                userAgent: userAgent,
                shouldAutoPlay: shouldAutoPlay
            )
        }

        /// Stops playback and releases VLC resources.
        func stop() {
            mediaPlayer.stop()
            mediaPlayer.media = nil
            mediaPlayer.drawable = nil
            currentURL = nil
        }

        /// Loads a VLC media object from a local or remote URL.
        ///
        /// - Parameters:
        ///   - metadata: Video metadata used for logging.
        ///   - url: Local or remote video URL.
        ///   - userAgent: Optional HTTP User-Agent used for remote playback.
        ///   - shouldAutoPlay: Whether playback should start immediately.
        private func load(
            metadata: tableMetadata,
            url: URL,
            userAgent: String?,
            shouldAutoPlay: Bool
        ) {
            currentURL = url

            mediaPlayer.stop()

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
                message: "VIDEO VLC load \(metadata.ocId), url \(url.absoluteString), userAgent \(userAgent != nil)",
                consoleOnly: true
            )

            if shouldAutoPlay {
                mediaPlayer.play()
            }
        }
    }
}
