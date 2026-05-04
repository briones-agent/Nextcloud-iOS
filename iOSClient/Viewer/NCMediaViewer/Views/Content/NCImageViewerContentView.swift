// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit

// MARK: - Image Viewer Content View

/// Displays an image page using an optional preview and an optional full-size image.
///
/// The preview is decoded first when available.
/// The full image replaces the preview only after it has been decoded.
/// The SwiftUI view remains mounted while moving from preview to full image.
struct NCImageViewerContentView: View {

    // MARK: - Properties

    let previewURL: URL?
    let fullURL: URL?
    let backgroundStyle: NCViewerBackgroundStyle

    // MARK: - State

    @State private var currentImage: UIImage?
    @State private var loadedPreviewURL: URL?
    @State private var loadedFullURL: URL?
    @State private var failedMessage: String?

    // MARK: - Init

    /// Creates an image viewer content view.
    ///
    /// - Parameters:
    ///   - previewURL: Optional preview image URL.
    ///   - fullURL: Optional full-size image URL.
    ///   - backgroundStyle: Background style used behind the image.
    init(
        previewURL: URL?,
        fullURL: URL?,
        backgroundStyle: NCViewerBackgroundStyle = .system
    ) {
        self.previewURL = previewURL
        self.fullURL = fullURL
        self.backgroundStyle = backgroundStyle
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.ncViewerBackground(backgroundStyle)
                .ignoresSafeArea()

            if let currentImage {
                NCImageZoomView(
                    image: currentImage,
                    backgroundStyle: backgroundStyle
                )
                .ignoresSafeArea()
            } else if let failedMessage {
                failedView(failedMessage)
            } else {
                Color.ncViewerBackground(backgroundStyle)
                    .ignoresSafeArea()
            }
        }
        .background(Color.ncViewerBackground(backgroundStyle))
        .task(id: previewURL) {
            await loadPreviewIfNeeded()
        }
        .task(id: fullURL) {
            await loadFullIfNeeded()
        }
    }

    // MARK: - Views

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 44, weight: .regular))

            Text("Image load failed")
                .font(.headline)

            Text(message)
                .font(.caption)
                .foregroundStyle(secondaryForegroundStyle)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(primaryForegroundStyle)
        .padding(24)
    }

    // MARK: - Appearance

    private var primaryForegroundStyle: Color {
        switch backgroundStyle {
        case .black:
            return .white

        case .system,
             .white,
             .custom:
            return .primary
        }
    }

    private var secondaryForegroundStyle: Color {
        switch backgroundStyle {
        case .black:
            return .white.opacity(0.65)

        case .system,
             .white,
             .custom:
            return .secondary
        }
    }

    // MARK: - Loading

    /// Loads the preview image only when no image is currently displayed.
    ///
    /// This prevents the preview from replacing a full image that has already been decoded.
    private func loadPreviewIfNeeded() async {
        guard currentImage == nil else {
            return
        }

        guard let previewURL else {
            return
        }

        guard loadedPreviewURL != previewURL else {
            return
        }

        guard let image = await decodeImageIfPossible(url: previewURL) else {
            return
        }

        loadedPreviewURL = previewURL
        failedMessage = nil
        currentImage = image
    }

    /// Loads the full image and replaces the currently displayed bitmap only after decoding.
    ///
    /// This keeps the preview visible until the full image is completely ready.
    private func loadFullIfNeeded() async {
        guard let fullURL else {
            return
        }

        guard loadedFullURL != fullURL else {
            return
        }

        guard let image = await decodeImageIfPossible(url: fullURL) else {
            if currentImage == nil {
                failedMessage = "UIImage could not decode this file."
            }
            return
        }

        loadedFullURL = fullURL
        failedMessage = nil

        // Replace the visible bitmap only after decoding to avoid preview-to-full flickering.
        currentImage = image
    }

    /// Decodes a local image file.
    ///
    /// - Parameter url: Local file URL.
    /// - Returns: Decoded image if possible.
    private func decodeImageIfPossible(url: URL) async -> UIImage? {
        let path = url.path

        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = attributes[.size] as? Int64,
              fileSize > 0 else {
            return nil
        }

        return await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                UIImage(contentsOfFile: path)
            }
        }.value
    }
}
