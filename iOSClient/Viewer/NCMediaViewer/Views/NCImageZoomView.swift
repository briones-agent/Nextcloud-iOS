// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit

// MARK: - Image Zoom View

/// UIKit-backed image zoom view.
///
/// This view uses `UIScrollView` because it provides native, smooth pinch-to-zoom
/// and pan behavior, which is more reliable than SwiftUI `MagnifyGesture` when
/// hosted inside a paging `TabView`.
struct NCImageZoomView: UIViewRepresentable {

    let image: UIImage

    private let minimumZoomScale: CGFloat = 1
    private let maximumZoomScale: CGFloat = 5
    private let doubleTapZoomScale: CGFloat = 2.5

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> NCZoomScrollView {
        let scrollView = NCZoomScrollView()

        scrollView.delegate = context.coordinator
        scrollView.backgroundColor = .black
        scrollView.minimumZoomScale = minimumZoomScale
        scrollView.maximumZoomScale = maximumZoomScale
        scrollView.zoomScale = minimumZoomScale
        scrollView.bouncesZoom = true
        scrollView.bounces = true
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.clipsToBounds = true

        let imageView = UIImageView(frame: .zero)
        imageView.image = image
        imageView.backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.clipsToBounds = true

        scrollView.addSubview(imageView)

        context.coordinator.scrollView = scrollView
        context.coordinator.imageView = imageView
        context.coordinator.currentImage = image
        context.coordinator.minimumZoomScale = minimumZoomScale
        context.coordinator.maximumZoomScale = maximumZoomScale
        context.coordinator.doubleTapZoomScale = doubleTapZoomScale

        scrollView.onLayoutSubviews = { [weak coordinator = context.coordinator] in
            coordinator?.layoutImageViewKeepingZoomIfPossible()
        }

        let doubleTapGesture = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTapGesture.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTapGesture)

        return scrollView
    }

    func updateUIView(_ scrollView: NCZoomScrollView, context: Context) {
        guard let imageView = context.coordinator.imageView else {
            return
        }

        context.coordinator.minimumZoomScale = minimumZoomScale
        context.coordinator.maximumZoomScale = maximumZoomScale
        context.coordinator.doubleTapZoomScale = doubleTapZoomScale

        scrollView.minimumZoomScale = minimumZoomScale
        scrollView.maximumZoomScale = maximumZoomScale

        let imageChanged = context.coordinator.currentImage !== image

        if imageChanged {
            context.coordinator.currentImage = image
            context.coordinator.resetBoundsTracking()

            scrollView.setZoomScale(minimumZoomScale, animated: false)
            scrollView.contentOffset = .zero
            scrollView.contentInset = .zero

            imageView.image = image
        }

        if imageChanged {
            context.coordinator.layoutImageViewResettingZoom()
        } else {
            context.coordinator.layoutImageViewKeepingZoomIfPossible()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Scroll View

    final class NCZoomScrollView: UIScrollView {

        var onLayoutSubviews: (() -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            onLayoutSubviews?()
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIScrollViewDelegate {

        // MARK: - State

        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?
        var currentImage: UIImage?

        var minimumZoomScale: CGFloat = 1
        var maximumZoomScale: CGFloat = 5
        var doubleTapZoomScale: CGFloat = 2.5

        private var lastBoundsSize: CGSize = .zero

        // MARK: - UIScrollViewDelegate

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerImageView()
        }

        // MARK: - Layout

        /// Resets cached bounds tracking so the next layout pass refits the image.
        func resetBoundsTracking() {
            lastBoundsSize = .zero
        }

        /// Lays out the image view and resets zoom to the fitted image.
        func layoutImageViewResettingZoom() {
            guard let scrollView,
                  let imageView,
                  let image = imageView.image else {
                return
            }

            let boundsSize = scrollView.bounds.size

            guard boundsSize.width > 0,
                  boundsSize.height > 0,
                  image.size.width > 0,
                  image.size.height > 0 else {
                return
            }

            let fittedSize = fittedImageSize(
                imageSize: image.size,
                containerSize: boundsSize
            )

            scrollView.setZoomScale(minimumZoomScale, animated: false)
            scrollView.contentInset = .zero
            scrollView.contentOffset = .zero

            imageView.frame = CGRect(
                origin: .zero,
                size: fittedSize
            )

            scrollView.contentSize = fittedSize
            lastBoundsSize = boundsSize

            centerImageView()
        }

        /// Lays out the image view when the container size changes.
        ///
        /// If the image is not zoomed, the image is refitted to the new container.
        /// If the image is zoomed, the zoom value is preserved as much as possible.
        func layoutImageViewKeepingZoomIfPossible() {
            guard let scrollView,
                  let imageView,
                  let image = imageView.image else {
                return
            }

            let boundsSize = scrollView.bounds.size

            guard boundsSize.width > 0,
                  boundsSize.height > 0,
                  image.size.width > 0,
                  image.size.height > 0 else {
                return
            }

            guard boundsSize != lastBoundsSize else {
                centerImageView()
                return
            }

            let wasZoomed = scrollView.zoomScale > minimumZoomScale + 0.01
            let currentZoomScale = scrollView.zoomScale

            let fittedSize = fittedImageSize(
                imageSize: image.size,
                containerSize: boundsSize
            )

            imageView.frame = CGRect(
                origin: .zero,
                size: fittedSize
            )

            scrollView.contentSize = fittedSize

            if wasZoomed {
                let clampedZoomScale = min(
                    max(currentZoomScale, minimumZoomScale),
                    maximumZoomScale
                )

                scrollView.setZoomScale(clampedZoomScale, animated: false)
            } else {
                scrollView.setZoomScale(minimumZoomScale, animated: false)
                scrollView.contentOffset = .zero
            }

            lastBoundsSize = boundsSize
            centerImageView()
        }

        /// Centers the image view inside the scroll view when the image is smaller than the viewport.
        private func centerImageView() {
            guard let scrollView,
                  let imageView else {
                return
            }

            let boundsSize = scrollView.bounds.size
            let frameSize = imageView.frame.size

            let horizontalInset = max((boundsSize.width - frameSize.width) * 0.5, 0)
            let verticalInset = max((boundsSize.height - frameSize.height) * 0.5, 0)

            scrollView.contentInset = UIEdgeInsets(
                top: verticalInset,
                left: horizontalInset,
                bottom: verticalInset,
                right: horizontalInset
            )
        }

        /// Returns the aspect-fit size of an image inside a container.
        ///
        /// - Parameters:
        ///   - imageSize: Original image size.
        ///   - containerSize: Available container size.
        /// - Returns: Aspect-fitted image size.
        private func fittedImageSize(
            imageSize: CGSize,
            containerSize: CGSize
        ) -> CGSize {
            let widthRatio = containerSize.width / imageSize.width
            let heightRatio = containerSize.height / imageSize.height
            let ratio = min(widthRatio, heightRatio)

            return CGSize(
                width: imageSize.width * ratio,
                height: imageSize.height * ratio
            )
        }

        // MARK: - Gestures

        /// Handles double tap zoom and reset.
        ///
        /// - Parameter gesture: Double tap recognizer.
        @objc
        func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView,
                  let imageView else {
                return
            }

            if scrollView.zoomScale > minimumZoomScale + 0.01 {
                scrollView.setZoomScale(minimumZoomScale, animated: true)
                return
            }

            let point = gesture.location(in: imageView)
            let targetScale = min(doubleTapZoomScale, maximumZoomScale)

            let zoomRect = zoomRect(
                for: scrollView,
                scale: targetScale,
                center: point
            )

            scrollView.zoom(to: zoomRect, animated: true)
        }

        /// Builds the zoom rect used by double tap.
        ///
        /// - Parameters:
        ///   - scrollView: Source scroll view.
        ///   - scale: Target zoom scale.
        ///   - center: Center point in image view coordinates.
        /// - Returns: Zoom rectangle.
        private func zoomRect(
            for scrollView: UIScrollView,
            scale: CGFloat,
            center: CGPoint
        ) -> CGRect {
            let size = CGSize(
                width: scrollView.bounds.width / scale,
                height: scrollView.bounds.height / scale
            )

            return CGRect(
                x: center.x - size.width * 0.5,
                y: center.y - size.height * 0.5,
                width: size.width,
                height: size.height
            )
        }
    }
}
