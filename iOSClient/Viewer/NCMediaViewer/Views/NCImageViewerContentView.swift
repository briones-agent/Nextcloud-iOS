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

    // MARK: - Properties

    let fileURL: URL

    // MARK: - State

    @State private var image: UIImage?
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

                if let image {
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
                } else {
                    ProgressView()
                        .tint(.white)
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

    // MARK: - Private

    /// Loads the full image from disk.
    ///
    /// This first implementation is intentionally simple.
    /// Later it should be replaced by downsampled decoding to reduce memory usage.
    private func loadImage() async {
        guard image == nil else {
            return
        }

        image = UIImage(contentsOfFile: fileURL.path)
    }

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
        image = nil
        resetZoom()
    }
}
