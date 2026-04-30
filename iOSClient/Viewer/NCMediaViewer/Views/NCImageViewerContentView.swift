// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit

// MARK: - Image Viewer Content View

/// Displays a local full-size image with zoom and pan support.
///
/// Supported gestures:
/// - pinch to zoom
/// - drag while zoomed
/// - double tap to toggle zoom
struct NCImageViewerContentView: View {

    // MARK: - Load State

    private enum LoadState {
        case loading
        case ready(UIImage)
        case failed(String)
    }

    // MARK: - Properties

    let fileURL: URL

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
                    loadingView

                case .ready(let image):
                    imageView(image, proxy: proxy)

                case .failed(let message):
                    failedView(message)
                }
            }
        }
        .task(id: fileURL) {
            await loadImage()
        }
        .onChange(of: fileURL) {
            resetImageState()
        }
    }

    // MARK: - Views

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.white)

            Text("Loading image")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))

            Text(fileURL.path)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

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

            Text(fileURL.path)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(3)
                .truncationMode(.middle)
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

    /// Loads the full image from disk.
    ///
    /// This version performs basic validation and reports visible errors instead
    /// of leaving the view stuck on a spinner.
    private func loadImage() async {
        loadState = .loading

        let path = fileURL.path

        guard FileManager.default.fileExists(atPath: path) else {
            loadState = .failed("The local image file does not exist.")
            print("NCImageViewerContentView file missing:", path)
            return
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let fileSize = attributes[.size] as? Int64 ?? 0

            guard fileSize > 0 else {
                loadState = .failed("The local image file is empty.")
                print("NCImageViewerContentView empty file:", path)
                return
            }

            let image = await Task.detached(priority: .userInitiated) {
                autoreleasepool {
                    UIImage(contentsOfFile: path)
                }
            }.value

            guard let image else {
                loadState = .failed("UIImage could not decode this file.")
                print("NCImageViewerContentView decode failed:", path, "size:", fileSize)
                return
            }

            print("NCImageViewerContentView loaded:", path, "size:", fileSize)
            loadState = .ready(image)
        } catch {
            loadState = .failed(error.localizedDescription)
            print("NCImageViewerContentView error:", error.localizedDescription, path)
        }
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
