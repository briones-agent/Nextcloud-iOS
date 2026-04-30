// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit

// MARK: - Image Viewer Content View

/// Displays a local full-size image with optional preview fallback.
///
/// The preview remains visible while the full image is decoded.
/// The full image replaces the preview only when it is ready.
struct NCImageViewerContentView: View {

    // MARK: - Load State

    private enum LoadState {
        case loading
        case preview(UIImage)
        case ready(UIImage)
        case failed(String)
    }

    // MARK: - Properties

    let fileURL: URL
    let previewURL: URL?

    // MARK: - State

    @State private var loadState: LoadState = .loading
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

                switch loadState {
                case .loading:
                    // ProgressView()
                    //    .tint(.white)
                    Color.black
                        .ignoresSafeArea()

                case .preview(let image):
                    imageView(image, proxy: proxy)

                case .ready(let image):
                    imageView(image, proxy: proxy)

                case .failed(let message):
                    failedView(message)
                }
            }
        }
        .task(id: fileURL) {
            await loadImages()
        }
        .onChange(of: fileURL) {
            resetImageState()
        }
    }

    // MARK: - Views

    private func imageView(_ image: UIImage, proxy: GeometryProxy) -> some View {
        Image(uiImage: image)
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
            .simultaneousGesture(dragGesture)
            .simultaneousGesture(doubleTapGesture)
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

    /// Loads the preview first, then replaces it with the full image when ready.
    private func loadImages() async {
        if let previewURL,
           let previewImage = await decodeImageIfPossible(url: previewURL) {
            loadState = .preview(previewImage)
        } else {
            loadState = .loading
        }

        guard let fullImage = await decodeImageIfPossible(url: fileURL) else {
            if case .preview = loadState {
                return
            }

            loadState = .failed("UIImage could not decode this file.")
            return
        }

        loadState = .ready(fullImage)
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

    private func resetImageState() {
        loadState = .loading
        resetZoom()
    }
}
