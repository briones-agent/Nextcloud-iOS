// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import NextcloudKit

// MARK: - Video Viewer Content View

/// Displays a video using the best available playback URL and playback engine.
///
/// The playable URL is resolved from:
/// - explicit metadata URL
/// - local provider storage
/// - Nextcloud direct download URL
///
/// AVFoundation is preferred. VLC is used as fallback when AVFoundation cannot
/// prepare the resolved video URL.
struct NCVideoViewerContentView: View {
    let metadata: tableMetadata
    let localURL: URL?
    let previewURL: URL?
    let userAgent: String?

    @StateObject private var hub = NCVideoPlaybackHub()

    @State private var resolvedURL: URL?
    @State private var errorMessage: String?
    @State private var showsLoadingOverlay = false

    private let resolver = NCVideoURLResolver()

    init(
        metadata: tableMetadata,
        localURL: URL?,
        previewURL: URL? = nil,
        userAgent: String? = nil
    ) {
        self.metadata = metadata
        self.localURL = localURL
        self.previewURL = previewURL
        self.userAgent = userAgent
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if let errorMessage {
                failedView(errorMessage)
            } else {
                switch hub.engine {
                case .loading:
                    loadingView

                case .avFoundation(let player):
                    NCVideoAVPlayerContentView(
                        player: player,
                        allowsPictureInPicture: true,
                        shouldAutoPlay: true
                    )
                    .ignoresSafeArea()

                case .vlc(let url):
                    NCVideoVLCViewerContentView(
                        metadata: metadata,
                        url: url,
                        shouldAutoPlay: true
                    )
                    .ignoresSafeArea()

                case .failed(let message):
                    failedView(message)
                }
            }
        }
        .background(Color.black)
        .task(id: taskIdentifier) {
            await resolveAndLoadVideo()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ncMediaViewerStopPlayback)) { _ in
            hub.stop()
        }
    }

    // MARK: - Views

    @ViewBuilder
    private var loadingView: some View {
        ZStack {
            if let previewURL {
                NCImageViewerContentView(
                    identifier: metadata.ocId,
                    previewURL: previewURL,
                    fullURL: nil,
                    backgroundStyle: .black
                )
            } else {
                Color.black
                    .ignoresSafeArea()
            }

            VStack(spacing: 14) {
                ProgressView()
                    .tint(.white)

                Text(displayFileName)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 24)
            }
            .padding(16)
            .background(.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash")
                .font(.system(size: 44, weight: .regular))

            Text("Video not available")
                .font(.headline)

            Text(message)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .foregroundStyle(.white)
        .padding(24)
    }

    // MARK: - Loading

    private var taskIdentifier: String {
        "\(metadata.ocId)|\(metadata.etag)|\(metadata.url)|\(localURL?.absoluteString ?? "")"
    }

    /// Resolves the playable video URL and loads it into the playback hub.
    @MainActor
    private func resolveAndLoadVideo() async {
        errorMessage = nil

        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: .debug,
            message: "VIDEO resolve start ocId \(metadata.ocId), fileName \(metadata.fileNameView), fileId \(metadata.fileId)",
            consoleOnly: true
        )

        let result = await resolver.getVideoURL(metadata: metadata)

        guard !Task.isCancelled else {
            nkLog(
                tag: NCGlobal.shared.logTagViewer,
                emoji: .debug,
                message: "VIDEO resolve cancelled ocId \(metadata.ocId)",
                consoleOnly: true
            )
            return
        }

        guard result.error == .success,
              let url = result.url else {
            nkLog(
                tag: NCGlobal.shared.logTagViewer,
                emoji: .error,
                message: "VIDEO resolve failed ocId \(metadata.ocId), error \(result.error.errorDescription)",
                consoleOnly: true
            )

            errorMessage = result.error.errorDescription
            return
        }

        resolvedURL = url

        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: .debug,
            message: "VIDEO resolve done url \(url.absoluteString), isFileURL \(url.isFileURL)",
            consoleOnly: true
        )

        hub.load(
            url: url,
            httpHeaders: httpHeaders(for: url)
        )
    }

    /// Returns HTTP headers for remote video playback.
    ///
    /// Local file URLs do not need HTTP headers.
    ///
    /// - Parameter url: Resolved video URL.
    /// - Returns: HTTP headers for AVFoundation remote playback.
    private func httpHeaders(for url: URL) -> [String: String] {
        guard !url.isFileURL else {
            return [:]
        }

        guard let userAgent,
              !userAgent.isEmpty else {
            return [:]
        }

        return [
            "User-Agent": userAgent
        ]
    }

    // MARK: - Helpers

    private var displayFileName: String {
        if !metadata.fileNameView.isEmpty {
            return metadata.fileNameView
        }

        return metadata.fileName
    }
}
