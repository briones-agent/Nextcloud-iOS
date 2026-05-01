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

    // MARK: - State

    @State private var currentImage: UIImage?
    @State private var loadedPreviewURL: URL?
    @State private var loadedFullURL: URL?
    @State private var failedMessage: String?

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    // MARK: - Constants

    private let minimumScale: CGFloat = 1
    private let maximumScale: CGFloat = 5
    private let doubleTapScale: CGFloat = 2.5

    // MARK: - Body

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                    .ignoresSafeArea()

                if let currentImage {
                    imageView(currentImage, proxy: proxy)
                } else if let failedMessage {
                    failedView(failedMessage)
                } else {
                    Color.black
                        .ignoresSafeArea()
                }
            }
        }
        .task(id: previewURL) {
            await loadPreviewIfNeeded()
        }
        .task(id: fullURL) {
            await loadFullIfNeeded()
        }
    }

    // MARK: - Views

    @ViewBuilder
    private func imageView(_ image: UIImage, proxy: GeometryProxy) -> some View {
        let baseView = Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .frame(
                width: proxy.size.width,
                height: proxy.size.height
            )
            .contentShape(Rectangle())
            .gesture(magnifyGesture)
            .simultaneousGesture(doubleTapGesture)

        if scale > minimumScale {
            baseView
                .simultaneousGesture(dragGesture)
        } else {
            baseView
        }
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 44, weight: .regular))

            Text("Image load failed")
                .font(.headline)

            Text(message)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(24)
    }

    // MARK: - Gestures

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let newScale = lastScale * value.magnification
                scale = clampedScale(newScale)
            }
            .onEnded { _ in
                scale = clampedScale(scale)
                lastScale = scale

                if scale == minimumScale {
                    resetOffset()
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > minimumScale else {
                    return
                }

                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                guard scale > minimumScale else {
                    resetOffset()
                    return
                }

                lastOffset = offset
            }
    }

    private var doubleTapGesture: some Gesture {
        TapGesture(count: 2)
            .onEnded {
                if scale > minimumScale {
                    resetZoom()
                } else {
                    scale = doubleTapScale
                    lastScale = doubleTapScale
                }
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

    // MARK: - Private

    private func clampedScale(_ value: CGFloat) -> CGFloat {
        min(max(value, minimumScale), maximumScale)
    }

    private func resetOffset() {
        offset = .zero
        lastOffset = .zero
    }

    private func resetZoom() {
        scale = minimumScale
        lastScale = minimumScale
        resetOffset()
    }
}
