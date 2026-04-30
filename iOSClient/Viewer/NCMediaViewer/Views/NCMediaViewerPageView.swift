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

    // MARK: - Properties

    let page: NCMediaViewerPageModel

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            switch page.state {
            case .idle,
                 .loadingMetadata,
                 .checkingLocalFile:
                loadingView

            case .metadataMissing:
                metadataMissingView

            case .remoteOnly(let previewURL):
                ZStack {
                    previewView(previewURL: previewURL)
                    remoteOnlyOverlay
                }

            case .downloading(let previewURL, let progress):
                ZStack {
                    previewView(previewURL: previewURL)
                    downloadingOverlay(progress: progress)
                }

            case .ready(let localURL):
                if let metadata = page.metadata {
                    readyView(metadata: metadata, localURL: localURL)
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

    private var loadingView: some View {
        ProgressView()
            .tint(.white)
    }

    private var metadataMissingView: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 44, weight: .regular))

            Text("Media not available")
                .font(.headline)
        }
        .foregroundStyle(.white.opacity(0.85))
        .multilineTextAlignment(.center)
        .padding()
    }

    private var remoteOnlyOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.white)

            Text("Preparing media…")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(16)
        .background(.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 16))
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

    @ViewBuilder
    private func readyView(metadata: tableMetadata, localURL: URL) -> some View {
        if isImage(metadata) {
            NCImageViewerContentView(fileURL: localURL)
        } else {
            NCVideoViewerPlaceholderView(
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
            }

            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
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

    private func isImage(_ metadata: tableMetadata) -> Bool {
        metadata.classFile == NKTypeClassFile.image.rawValue
    }
}
