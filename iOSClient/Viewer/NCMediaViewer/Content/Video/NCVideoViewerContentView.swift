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
    let isSelected: Bool

    @StateObject private var hub = NCVideoPlaybackHub()

    @State private var errorMessage: String?

    private let resolver = NCVideoURLResolver()

    init(
        metadata: tableMetadata,
        localURL: URL?,
        previewURL: URL? = nil,
        userAgent: String? = nil,
        isSelected: Bool = true
    ) {
        self.metadata = metadata
        self.localURL = localURL
        self.previewURL = previewURL
        self.userAgent = userAgent
        self.isSelected = isSelected
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
                        shouldAutoPlay: isSelected
                    )
                    .padding(.bottom, videoPlayerBottomPadding)
                    .ignoresSafeArea(edges: [.top, .leading, .trailing])

                case .vlc(let url):
                    NCVideoVLCViewerContentView(
                        metadata: metadata,
                        url: url,
                        userAgent: userAgent,
                        shouldAutoPlay: isSelected
                    )
                    .ignoresSafeArea()

                case .failed(let message):
                    failedView(message)
                }
            }
        }
        .background(Color.black)
        .task(id: taskIdentifier) {
            let expectedTaskIdentifier = taskIdentifier

            hub.stop()
            errorMessage = nil

            guard isSelected else {
                return
            }

            await resolveAndLoadVideo(
                expectedTaskIdentifier: expectedTaskIdentifier
            )
        }
        .onChange(of: isSelected) { _, selected in
            if !selected {
                hub.stop()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ncMediaViewerStopPlayback)) { _ in
            hub.stop()
        }
        .onDisappear {
            hub.stop()
        }
    }

    // MARK: - Views

    /// Extra bottom padding used only for the native AVPlayer controller.
    ///
    /// This keeps the native playback scrubber away from the bottom edge / home indicator
    /// without changing image, Live Photo, audio, or VLC layout.
    private var videoPlayerBottomPadding: CGFloat {
        let windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }

        let window = windowScene?.windows.first { $0.isKeyWindow }
        let safeBottom = window?.safeAreaInsets.bottom ?? 0

        return max(safeBottom, 16)
    }

    @ViewBuilder
    private var loadingView: some View {
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
        "\(metadata.ocId)|\(metadata.etag)|\(metadata.url)|\(localURL?.absoluteString ?? "")|\(previewURL?.absoluteString ?? "")|\(isSelected)"
    }

    /// Resolves the playable video URL and loads it into the playback hub.
    ///
    /// - Parameter expectedTaskIdentifier: Task identity captured before starting async resolution.
    @MainActor
    private func resolveAndLoadVideo(
        expectedTaskIdentifier: String
    ) async {
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

        guard expectedTaskIdentifier == taskIdentifier else {
            nkLog(
                tag: NCGlobal.shared.logTagViewer,
                emoji: .debug,
                message: "VIDEO resolve ignored stale task ocId \(metadata.ocId)",
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

        guard expectedTaskIdentifier == taskIdentifier else {
            nkLog(
                tag: NCGlobal.shared.logTagViewer,
                emoji: .debug,
                message: "VIDEO load ignored stale task ocId \(metadata.ocId), url \(url.absoluteString)",
                consoleOnly: true
            )
            return
        }

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
