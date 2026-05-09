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
/// Animated GIF files are decoded as animated `UIImage` instances.
/// SVG files are rasterized into `UIImage` instances before rendering.
/// All decoded images are rendered through the same zoom pipeline.
struct NCImageViewerContentView: View {
    let identifier: String
    let previewURL: URL?
    let fullURL: URL?
    let backgroundStyle: NCViewerBackgroundStyle

    @State private var currentImage: UIImage?
    @State private var loadedPreviewURL: URL?
    @State private var loadedFullURL: URL?
    @State private var loadedIdentifier: String?
    @State private var failedMessage: String?

    private var taskIdentifier: String {
        "\(identifier)|\(previewURL?.absoluteString ?? "")|\(fullURL?.absoluteString ?? "")"
    }

    init(identifier: String, previewURL: URL?, fullURL: URL?, backgroundStyle: NCViewerBackgroundStyle = .system) {
        self.identifier = identifier
        self.previewURL = previewURL
        self.fullURL = fullURL
        self.backgroundStyle = backgroundStyle
    }

    var body: some View {
        ZStack {
            Color.ncViewerBackground(backgroundStyle)
                .ignoresSafeArea()

            if let currentImage {
                NCImageZoomView(image: currentImage,
                                backgroundStyle: backgroundStyle,
                                allowsImageAnalysis: allowsImageAnalysis)
                    .ignoresSafeArea()
            } else if let failedMessage {
                failedView(failedMessage)
            } else {
                Color.ncViewerBackground(backgroundStyle)
                    .ignoresSafeArea()
            }
        }
        .background(Color.ncViewerBackground(backgroundStyle))
        .task(id: taskIdentifier) {
            await loadBestAvailableImage()
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

    /// Loads the best available image for the current URLs.
    private func loadBestAvailableImage() async {
        if loadedIdentifier != identifier {
            currentImage = nil
            loadedPreviewURL = nil
            loadedFullURL = nil
            failedMessage = nil
            loadedIdentifier = identifier
        }

        failedMessage = nil

        if let previewURL,
           currentImage == nil,
           loadedPreviewURL != previewURL {
            if let previewImage = await decodeImageIfPossible(url: previewURL) {
                guard !Task.isCancelled else {
                    return
                }

                loadedPreviewURL = previewURL
                failedMessage = nil
                currentImage = previewImage
            }
        }

        guard let fullURL else {
            return
        }

        guard loadedFullURL != fullURL else {
            return
        }

        let fullImage: UIImage?

        if isGIF(fullURL) {
            fullImage = await decodeGIFImageIfPossible(url: fullURL)
        } else if isSVG(fullURL) {
            fullImage = await decodeSVGImageIfPossible(url: fullURL)
        } else {
            fullImage = await decodeImageIfPossible(url: fullURL)
        }

        guard !Task.isCancelled else {
            return
        }

        if let fullImage {
            loadedFullURL = fullURL
            failedMessage = nil
            currentImage = fullImage
            return
        }

        if currentImage == nil {
            failedMessage = imageDecodeFailedMessage(for: fullURL)
        }
    }

    /// Decodes a local standard image file.
    ///
    /// - Parameter url: Local file URL.
    /// - Returns: Decoded image if possible.
    private func decodeImageIfPossible(url: URL) async -> UIImage? {
        guard isValidLocalFile(url: url) else {
            return nil
        }

        let path = url.path

        return await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                UIImage(contentsOfFile: path)
            }
        }.value
    }

    /// Decodes a local GIF file as an animated `UIImage`.
    ///
    /// - Parameter url: Local GIF file URL.
    /// - Returns: Animated image if the GIF can be decoded.
    private func decodeGIFImageIfPossible(url: URL) async -> UIImage? {
        guard isValidLocalFile(url: url) else {
            return nil
        }

        return await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                UIImage.animatedImage(withAnimatedGIFURL: url)
            }
        }.value
    }

    /// Decodes a local SVG file by rasterizing it into a `UIImage`.
    ///
    /// `NCSVGRenderer` is WKWebView-backed, so this method must run on the main actor.
    ///
    /// - Parameter url: Local SVG file URL.
    /// - Returns: Rasterized SVG image if possible.
    @MainActor
    private func decodeSVGImageIfPossible(url: URL) async -> UIImage? {
        guard isValidLocalFile(url: url) else {
            return nil
        }

        guard let svgData = try? Data(contentsOf: url) else {
            return nil
        }

        return try? await NCSVGRenderer().renderSVGToUIImage(
            svgData: svgData,
            size: CGSize(width: 1024, height: 1024)
        )
    }

    /// Returns whether the URL points to a GIF file.
    ///
    /// - Parameter url: Optional file URL.
    /// - Returns: True when the path extension is `gif`.
    private func isGIF(_ url: URL?) -> Bool {
        url?.pathExtension.lowercased() == "gif"
    }

    /// Returns whether the URL points to an SVG file.
    ///
    /// - Parameter url: Optional file URL.
    /// - Returns: True when the path extension is `svg`.
    private func isSVG(_ url: URL?) -> Bool {
        url?.pathExtension.lowercased() == "svg"
    }

    /// Returns the proper decode failure message for a local image URL.
    ///
    /// - Parameter url: Local file URL.
    /// - Returns: User-facing decode failure message.
    private func imageDecodeFailedMessage(for url: URL) -> String {
        if isGIF(url) {
            return "GIF file could not be decoded."
        }

        if isSVG(url) {
            return "SVG file could not be rendered."
        }

        return "UIImage could not decode this file."
    }

    /// Checks whether a local file exists and has a non-zero size.
    ///
    /// - Parameter url: Local file URL.
    /// - Returns: True when the file exists and is not empty.
    private func isValidLocalFile(url: URL) -> Bool {
        let path = url.path

        guard FileManager.default.fileExists(atPath: path) else {
            return false
        }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = attributes[.size] as? Int64,
              fileSize > 0 else {
            return false
        }

        return true
    }

    /// Returns whether VisionKit image analysis should be enabled for the current image.
    ///
    /// Image analysis is enabled only for normal static images.
    /// GIF and SVG are excluded because they are rendered through special decoding paths.
    private var allowsImageAnalysis: Bool {
        let url = fullURL ?? previewURL

        guard let url else {
            return false
        }

        if isGIF(url) {
            return false
        }

        /*
        if isSVG(url) {
            return false
        }
        */

        return true
    }
}
