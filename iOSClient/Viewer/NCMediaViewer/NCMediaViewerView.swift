// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit

// MARK: - Media Viewer View

/// Main SwiftUI media viewer.
///
/// This view owns the `NCMediaViewerModel` as a `StateObject`.
/// Paging is handled by `NCMediaViewerPagingView`, which is backed by
/// `UICollectionView` to support large virtualized media lists.
struct NCMediaViewerView: View {

    // MARK: - State

    @StateObject private var model: NCMediaViewerModel

    // MARK: - Init

    /// Creates the media viewer view.
    ///
    /// - Parameter model: Media viewer model containing page state and loading logic.
    init(model: NCMediaViewerModel) {
        _model = StateObject(wrappedValue: model)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            NCMediaViewerPagingView(model: model)
                .ignoresSafeArea()
        }
        .background(Color.black)
        .ignoresSafeArea()
        .statusBarHidden(true)
        .task {
            await model.loadSelectedPageIfNeeded()
        }
    }
}

// MARK: - Media Viewer Presenter

/// Presents the media viewer as a fullscreen overlay above the current window.
///
/// This avoids navigation push/present transitions and allows a clean
/// thumbnail-to-fullscreen opening animation.
@MainActor
final class NCMediaViewerPresenter {

    // MARK: - Singleton

    static let shared = NCMediaViewerPresenter()

    // MARK: - State

    private var hostingController: UIHostingController<NCMediaViewerView>?
    private weak var hostingView: UIView?

    // MARK: - Constants

    private let openingAnimationDuration: TimeInterval = 0.28
    private let closingAnimationDuration: TimeInterval = 0.20

    // MARK: - Init

    private init() { }

    // MARK: - Presentation

    /// Shows the media viewer above the current window.
    ///
    /// - Parameters:
    ///   - model: Media viewer model.
    ///   - viewerTransitionSource: Optional thumbnail source used for the opening animation.
    ///   - sourceView: View used to resolve the current window.
    func show(
        model: NCMediaViewerModel,
        viewerTransitionSource: NCViewerTransitionSource?,
        from sourceView: UIView? = nil
    ) {
        guard let window = sourceView?.window ?? activeWindow() else {
            return
        }

        dismiss(animated: false)

        let viewer = NCMediaViewerView(model: model)
        let hostingController = UIHostingController(rootView: viewer)

        hostingController.view.backgroundColor = .black
        hostingController.view.frame = window.bounds
        hostingController.view.autoresizingMask = [
            .flexibleWidth,
            .flexibleHeight
        ]

        self.hostingController = hostingController
        self.hostingView = hostingController.view

        if let viewerTransitionSource {
            hostingController.view.alpha = 0
            window.addSubview(hostingController.view)

            animateOpening(
                viewerTransitionSource: viewerTransitionSource,
                in: window,
                viewerView: hostingController.view
            )
        } else {
            hostingController.view.alpha = 1
            window.addSubview(hostingController.view)
        }
    }

    /// Dismisses the current media viewer overlay.
    ///
    /// - Parameter animated: Whether dismissal should fade out.
    func dismiss(animated: Bool = true) {
        guard let hostingView else {
            hostingController = nil
            return
        }

        let cleanup = { [weak self] in
            hostingView.removeFromSuperview()
            self?.hostingController = nil
            self?.hostingView = nil
        }

        guard animated else {
            cleanup()
            return
        }

        UIView.animate(
            withDuration: closingAnimationDuration,
            delay: 0,
            options: [.curveEaseInOut]
        ) {
            hostingView.alpha = 0
        } completion: { _ in
            cleanup()
        }
    }

    // MARK: - Opening Animation

    /// Animates the thumbnail image into the fullscreen viewer.
    ///
    /// - Parameters:
    ///   - viewerTransitionSource: Source thumbnail data.
    ///   - window: Current app window.
    ///   - viewerView: Real viewer view to reveal at the end.
    private func animateOpening(
        viewerTransitionSource: NCViewerTransitionSource,
        in window: UIWindow,
        viewerView: UIView
    ) {
        let dimView = UIView(frame: window.bounds)
        dimView.backgroundColor = .black
        dimView.alpha = 0
        dimView.autoresizingMask = [
            .flexibleWidth,
            .flexibleHeight
        ]

        let imageView = UIImageView(image: viewerTransitionSource.image)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.frame = viewerTransitionSource.sourceFrame
        imageView.layer.cornerRadius = viewerTransitionSource.cornerRadius

        window.addSubview(dimView)
        window.addSubview(imageView)

        let destinationFrame = aspectFitFrame(
            imageSize: viewerTransitionSource.image.size,
            containerSize: window.bounds.size
        )

        UIView.animate(
            withDuration: openingAnimationDuration,
            delay: 0,
            options: [.curveEaseInOut]
        ) {
            dimView.alpha = 1
            imageView.frame = destinationFrame
            imageView.layer.cornerRadius = 0
        } completion: { _ in
            viewerView.alpha = 1
            imageView.removeFromSuperview()
            dimView.removeFromSuperview()
        }
    }

    // MARK: - Helpers

    /// Computes the aspect-fit frame for an image inside the fullscreen container.
    ///
    /// - Parameters:
    ///   - imageSize: Source image size.
    ///   - containerSize: Window size.
    /// - Returns: Aspect-fit destination frame.
    private func aspectFitFrame(
        imageSize: CGSize,
        containerSize: CGSize
    ) -> CGRect {
        guard imageSize.width > 0,
              imageSize.height > 0,
              containerSize.width > 0,
              containerSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }

        let widthRatio = containerSize.width / imageSize.width
        let heightRatio = containerSize.height / imageSize.height
        let ratio = min(widthRatio, heightRatio)

        let fittedSize = CGSize(
            width: imageSize.width * ratio,
            height: imageSize.height * ratio
        )

        return CGRect(
            x: (containerSize.width - fittedSize.width) * 0.5,
            y: (containerSize.height - fittedSize.height) * 0.5,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    /// Returns the current foreground key window.

    ///

    /// - Returns: Active foreground window if available.

    private func activeWindow() -> UIWindow? {

        UIApplication.shared.connectedScenes

            .compactMap { $0 as? UIWindowScene }

            .filter { $0.activationState == .foregroundActive }

            .flatMap(\.windows)

            .first { $0.isKeyWindow }

    }
}
