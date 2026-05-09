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
    let isChromeHidden: Bool
    let onToggleChrome: () -> Void
    let canGoPrevious: Bool
    let canGoNext: Bool
    let onPreviousPage: () -> Void
    let onNextPage: () -> Void

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.ncViewerBackground(backgroundStyle)
                .ignoresSafeArea()

            switch page.state {
            case .idle,
                 .loadingMetadata,
                 .checkingLocalFile:
                Color.ncViewerBackground(backgroundStyle)
                    .ignoresSafeArea()

            case .metadataMissing:
                metadataMissingView

            case .image(let previewURL, let localURL, let livePhotoURL, _):
                imageStateView(
                    previewURL: previewURL,
                    localURL: localURL,
                    livePhotoURL: livePhotoURL
                )

            case .downloading(let previewURL, let progress):
                downloadingStateView(
                    previewURL: previewURL,
                    progress: progress
                )

            case .ready(let localURL, let previewURL):
                readyStateView(
                    localURL: localURL,
                    previewURL: previewURL
                )

            case .failed(let previewURL, let message):
                failedStateView(
                    previewURL: previewURL,
                    message: message
                )
            }
        }
        .background(Color.ncViewerBackground(backgroundStyle))
        .ignoresSafeArea()
    }

    // MARK: - Computed Properties

    private var backgroundStyle: NCViewerBackgroundStyle {
        if isChromeHidden {
            return .black
        }

        guard let metadata = page.metadata else {
            return .system
        }

        switch metadata.classFile {
        case NKTypeClassFile.audio.rawValue,
             NKTypeClassFile.video.rawValue:
            return .black

        default:
            return ncViewerBackgroundStyle(for: metadata)
        }
    }

    // MARK: - State Views

    private var loadingView: some View {
        ProgressView()
            .tint(progressTintColor)
    }

    private var metadataMissingView: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 44, weight: .regular))

            Text("Media not available")
                .font(.headline)
        }
        .foregroundStyle(primaryForegroundStyle)
        .multilineTextAlignment(.center)
        .padding()
    }

    @ViewBuilder
    private func imageStateView(
        previewURL: URL?,
        localURL: URL?,
        livePhotoURL: URL?
    ) -> some View {
        ZStack {
            imageContentView(
                previewURL: previewURL,
                localURL: localURL,
                livePhotoURL: livePhotoURL,
                backgroundStyle: backgroundStyle
            )

            if previewURL == nil && localURL == nil {
                loadingView
            }
        }
    }

    @ViewBuilder
    private func downloadingStateView(
        previewURL: URL?,
        progress: Double?
    ) -> some View {
        ZStack {
            if let previewURL {
                previewOnlyView(previewURL: previewURL)
            } else {
                Color.ncViewerBackground(backgroundStyle)
                    .ignoresSafeArea()
            }

            downloadingOverlay(progress: progress)
        }
    }

    @ViewBuilder
    private func readyStateView(
        localURL: URL,
        previewURL: URL?
    ) -> some View {
        if let metadata = page.metadata {
            switch mediaKind(for: metadata) {
            case .image:
                imageContentView(
                    previewURL: previewURL,
                    localURL: localURL,
                    livePhotoURL: nil,
                    backgroundStyle: backgroundStyle
                )

            case .video:
                NCVideoViewerPlaceholderView(
                    metadata: metadata,
                    localURL: localURL
                )
                .background(Color.ncViewerBackground(backgroundStyle))

            case .audio:
                NCAudioViewerContentView(
                    metadata: metadata,
                    localURL: localURL,
                    canGoPrevious: canGoPrevious,
                    canGoNext: canGoNext,
                    onPrevious: onPreviousPage,
                    onNext: onNextPage
                )
                .background(Color.black)
            }
        } else {
            metadataMissingView
        }
    }

    @ViewBuilder
    private func failedStateView(
        previewURL: URL?,
        message: String
    ) -> some View {
        ZStack {
            if let previewURL {
                previewOnlyView(previewURL: previewURL)
            } else {
                Color.ncViewerBackground(backgroundStyle)
                    .ignoresSafeArea()
            }

            failedOverlay(
                fileName: displayFileName(from: page.metadata),
                message: message
            )
        }
    }

    @ViewBuilder
    private func imageContentView(
        previewURL: URL?,
        localURL: URL?,
        livePhotoURL: URL?,
        backgroundStyle: NCViewerBackgroundStyle
    ) -> some View {
        if page.metadata?.isLivePhoto == true {
            NCLivePhotoViewerContentView(
                identifier: page.ocId,
                previewURL: previewURL,
                fullURL: localURL,
                videoURL: livePhotoURL,
                backgroundStyle: backgroundStyle,
                topOverlayInset: livePhotoTopOverlayInset
            )
            .background(Color.ncViewerBackground(backgroundStyle))
            .contentShape(Rectangle())
            .gesture(chromeToggleGesture())
        } else {
            NCImageViewerContentView(
                identifier: page.ocId,
                previewURL: previewURL,
                fullURL: localURL,
                backgroundStyle: backgroundStyle
            )
            .contentShape(Rectangle())
            .gesture(chromeToggleGesture())
        }
    }

    @ViewBuilder
    private func previewOnlyView(previewURL: URL) -> some View {
        NCImageViewerContentView(
            identifier: page.ocId,
            previewURL: previewURL,
            fullURL: nil,
            backgroundStyle: backgroundStyle
        )
        .contentShape(Rectangle())
        .gesture(chromeToggleGesture())
    }

    private func downloadingOverlay(progress: Double?) -> some View {
        VStack(spacing: 12) {
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 180)
            } else {
                ProgressView()
                    .tint(progressTintColor)
            }

            Text(downloadText(progress))
                .font(.footnote)
                .foregroundStyle(secondaryForegroundStyle)
        }
        .padding(16)
        .background(.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func failedOverlay(
        fileName: String?,
        message: String
    ) -> some View {
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

    /// Returns the tap gesture used to toggle the viewer chrome.
    ///
    /// Double tap is ignored here so image zoom can keep using it.
    private func chromeToggleGesture() -> some Gesture {
        TapGesture(count: 2)
            .exclusively(
                before: TapGesture(count: 1)
            )
            .onEnded { value in
                switch value {
                case .first:
                    break

                case .second:
                    onToggleChrome()
                }
            }
    }

    // MARK: - Appearance Helpers

    private var progressTintColor: Color {
        switch backgroundStyle {
        case .black:
            return .white

        case .system,
             .white,
             .custom:
            return .accentColor
        }
    }

    private var primaryForegroundStyle: Color {
        switch backgroundStyle {
        case .black:
            return .white.opacity(0.85)

        case .system,
             .white,
             .custom:
            return .primary
        }
    }

    private var secondaryForegroundStyle: Color {
        switch backgroundStyle {
        case .black:
            return .white.opacity(0.85)

        case .system,
             .white,
             .custom:
            return .secondary
        }
    }

    // MARK: - Helpers

    private var livePhotoTopOverlayInset: CGFloat {
        let windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }

        let window = windowScene?.windows.first { $0.isKeyWindow }
        let safeTop = window?.safeAreaInsets.top ?? 0

        return safeTop + 44 + 8
    }

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
            return .image
        }
    }
}
