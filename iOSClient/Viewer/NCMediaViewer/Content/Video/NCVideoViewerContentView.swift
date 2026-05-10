// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import NextcloudKit

// MARK: - Video Viewer Content View

/// Displays a local video file using the best available playback engine.
///
/// The view delegates engine selection to `NCVideoPlaybackHub`.
/// AVFoundation is preferred because it supports native controls and Picture in Picture.
/// VLC is used as fallback when AVFoundation cannot prepare the video.
struct NCVideoViewerContentView: View {
    let metadata: tableMetadata
    let localURL: URL

    @StateObject private var hub = NCVideoPlaybackHub()

    init(
        metadata: tableMetadata,
        localURL: URL
    ) {
        self.metadata = metadata
        self.localURL = localURL
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

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
                NCVideoViewerContentView(
                    metadata: metadata,
                    localURL: url
                )
                .ignoresSafeArea()

            case .failed(let message):
                failedView(message)
            }
        }
        .background(Color.black)
        .task(id: localURL) {
            hub.load(url: localURL)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ncMediaViewerStopPlayback)) { _ in
            hub.stop()
        }
        .onDisappear {
            hub.pause()
        }
    }

    // MARK: - Views

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(.white)

            Text(displayFileName)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 24)
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

    // MARK: - Helpers

    private var displayFileName: String {
        if !metadata.fileNameView.isEmpty {
            return metadata.fileNameView
        }

        return metadata.fileName
    }
}
