// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import NextcloudKit

// MARK: - Media Viewer Page View

/// Renders a single media viewer page.
///
/// This view is pure rendering logic.
/// It does not load metadata, check local files, read Realm, or start downloads.
struct NCMediaViewerPageView: View {

    // MARK: - Rendered Kind

    private enum NCMediaViewerRenderedKind {
        case image
        case video
        case audio
    }

    // MARK: - Properties

    let page: NCMediaViewerPageModel

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            switch page.state {
            case .idle:
                loadingView("Idle")

            case .loadingMetadata:
                loadingView("Loading metadata")

            case .checkingLocalFile:
                loadingView("Checking local file")

            case .metadataMissing:
                metadataMissingView

            case .remoteOnly(let previewURL):
                previewOnlyView(previewURL: previewURL)

            case .downloading(let previewURL, let progress):
                downloadingView(previewURL: previewURL, progress: progress)

            case .ready(let localURL, let previewURL):
                if let metadata = page.metadata {
                    readyView(
                        metadata: metadata,
                        localURL: localURL,
                        previewURL: previewURL
                    )
                } else {
                    metadataMissingView
                }

            case .failed(let previewURL, let message):
                ZStack {
                    previewView(previewURL: previewURL)
                    failedOverlay(
                        fileName: displayFileName(from: page.metadata),
                        message: message
                    )
                }
            }
        }
    }

    // MARK: - State Views

    private func loadingView(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.white)

            Text(text)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))

            if let fileName = displayFileName(from: page.metadata) {
                Text(fileName)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 24)
            }
        }
    }

    private var metadataMissingView: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 44, weight: .regular))

            Text("Media not available")
                .font(.headline)

            Text(page.ocId)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 24)
        }
        .foregroundStyle(.white.opacity(0.85))
        .multilineTextAlignment(.center)
        .padding()
    }

    @ViewBuilder
    private func previewOnlyView(previewURL: URL?) -> some View {
        if let previewURL {
            previewBackgroundView(previewURL: previewURL)
            preparingBadge
        } else {
            loadingView("Preparing media")
        }
    }

    @ViewBuilder
    private func downloadingView(previewURL: URL?, progress: Double?) -> some View {
        ZStack {
            if let previewURL {
                previewBackgroundView(previewURL: previewURL)
                downloadBadge(progress: progress)
            } else {
                Color.black
                    .ignoresSafeArea()

                downloadingOverlay(progress: progress)
            }
        }
    }

    private var preparingBadge: some View {
        VStack {
            Spacer()

            Text("Preparing…")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.35))
                .clipShape(Capsule())
                .padding(.bottom, 24)
        }
    }

    private func downloadingOverlay(progress: Double?) -> some View {
        VStack(spacing: 12) {
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 180)
            } else {
                ProgressView()
                    .tint(.white)
            }

            Text(downloadText(progress))
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(16)
        .background(.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func downloadBadge(progress: Double?) -> some View {
        VStack {
            Spacer()

            Text(downloadText(progress))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.35))
                .clipShape(Capsule())
                .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private func readyView(
        metadata: tableMetadata,
        localURL: URL,
        previewURL: URL?
    ) -> some View {
        switch mediaKind(for: metadata) {
        case .image:
            NCImageViewerContentView(
                fileURL: localURL,
                previewURL: previewURL
            )

        case .video:
            NCVideoViewerPlaceholderView(
                metadata: metadata,
                localURL: localURL
            )

        case .audio:
            NCAudioViewerPlaceholderView(
                metadata: metadata,
                localURL: localURL
            )
        }
    }

    @ViewBuilder
    private func previewView(previewURL: URL?) -> some View {
        if let previewURL {
            NCPreviewImageView(fileURL: previewURL)
        } else {
            Color.black
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func previewBackgroundView(previewURL: URL) -> some View {
        NCPreviewImageView(fileURL: previewURL)
            .blur(radius: 18)
            .opacity(0.45)
            .ignoresSafeArea()
            .overlay(Color.black.opacity(0.35))
    }

    private func failedOverlay(fileName: String?, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 44, weight: .regular))

            Text("Download failed")
                .font(.headline)

            if let fileName, !fileName.isEmpty {
                Text(fileName)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .padding(16)
        .background(.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding()
    }

    // MARK: - Helpers

    private func downloadText(_ progress: Double?) -> String {
        guard let progress else {
            return "Downloading…"
        }

        let percentage = Int((progress * 100).rounded())
        return "\(percentage)%"
    }

    private func displayFileName(from metadata: tableMetadata?) -> String? {
        guard let metadata else {
            return nil
        }

        if !metadata.fileNameView.isEmpty {
            return metadata.fileNameView
        }

        return metadata.fileName
    }

    private func mediaKind(for metadata: tableMetadata) -> NCMediaViewerRenderedKind {
        switch metadata.classFile {
        case NKTypeClassFile.image.rawValue:
            return .image

        case NKTypeClassFile.video.rawValue:
            return .video

        case NKTypeClassFile.audio.rawValue:
            return .audio

        default:
            return .video
        }
    }
}
