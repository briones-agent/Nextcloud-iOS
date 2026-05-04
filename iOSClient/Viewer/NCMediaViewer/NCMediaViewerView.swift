// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit
import Combine

// MARK: - Media Viewer View

/// Main SwiftUI media viewer.
///
/// This view owns the `NCMediaViewerModel` as a `StateObject`.
/// Paging is handled by `NCMediaViewerPagingView`, which is backed by
/// `UICollectionView` to support large virtualized media lists.
///
/// Navigation buttons and title are provided by `NCMediaViewerHostingController`.

struct NCMediaViewerView: View {
    @StateObject private var model: NCMediaViewerModel

    init(model: NCMediaViewerModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        ZStack {
            Color.ncViewerBackground(.system)
                .ignoresSafeArea()

            NCMediaViewerPagingView(model: model)
                .ignoresSafeArea()
        }
        .background(Color.ncViewerBackground(.system))
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
/// This avoids navigation push/present transitions and allows clean
/// thumbnail-to-fullscreen opening and closing animations.
@MainActor
final class NCMediaViewerPresenter {
    static let shared = NCMediaViewerPresenter()

    private var navigationController: UINavigationController?
    private weak var viewerContainerView: UIView?
    private var currentViewerTransitionSource: NCViewerTransitionSource?

    private let openingAnimationDuration: TimeInterval = 0.28
    private let closingAnimationDuration: TimeInterval = 0.24

    private init() { }

    // MARK: - Presentation

    /// Shows the media viewer above the current window.
    ///
    /// - Parameters:
    ///   - model: Media viewer model.
    ///   - viewerTransitionSource: Optional thumbnail source used for the opening and closing animations.
    ///   - sourceView: Optional view used to resolve the current window.
    ///   - onMenu: Closure called when the menu button is tapped.
    func show(
        model: NCMediaViewerModel,
        viewerTransitionSource: NCViewerTransitionSource?,
        from sourceView: UIView? = nil,
        onMenu: @escaping () -> Void = {}
    ) {
        guard let window = sourceView?.window ?? activeWindow() else {
            return
        }

        dismiss(animated: false)

        currentViewerTransitionSource = viewerTransitionSource

        let hostingController = NCMediaViewerHostingController(
            model: model,
            onClose: { [weak self] in
                self?.dismiss(animated: true)
            },
            onMenu: onMenu
        )

        let navigationController = UINavigationController(
            rootViewController: hostingController
        )

        configureNavigationController(navigationController)

        navigationController.view.backgroundColor = .ncViewerBackground(.system)
        navigationController.view.frame = window.bounds
        navigationController.view.autoresizingMask = [
            .flexibleWidth,
            .flexibleHeight
        ]

        self.navigationController = navigationController
        self.viewerContainerView = navigationController.view

        if let viewerTransitionSource {
            navigationController.view.alpha = 0
            window.addSubview(navigationController.view)

            animateOpening(
                viewerTransitionSource: viewerTransitionSource,
                in: window,
                viewerView: navigationController.view
            )
        } else {
            navigationController.view.alpha = 1
            window.addSubview(navigationController.view)
        }
    }

    /// Dismisses the current media viewer overlay.
    ///
    /// - Parameter animated: Whether dismissal should be animated.
    func dismiss(animated: Bool = true) {
        guard let viewerContainerView else {
            cleanup()
            return
        }

        guard animated else {
            viewerContainerView.removeFromSuperview()
            cleanup()
            return
        }

        if let viewerTransitionSource = currentViewerTransitionSource,
           let window = viewerContainerView.window {
            animateClosing(
                viewerTransitionSource: viewerTransitionSource,
                in: window,
                viewerView: viewerContainerView
            )
            return
        }

        UIView.animate(
            withDuration: closingAnimationDuration,
            delay: 0,
            options: [.curveEaseInOut]
        ) {
            viewerContainerView.alpha = 0
        } completion: { [weak self] _ in
            viewerContainerView.removeFromSuperview()
            self?.cleanup()
        }
    }

    // MARK: - Navigation Appearance

    /// Configures the dedicated navigation controller used by the viewer.
    ///
    /// - Parameter navigationController: Viewer navigation controller.
    private func configureNavigationController(_ navigationController: UINavigationController) {
        navigationController.setNavigationBarHidden(false, animated: false)
        navigationController.navigationBar.isTranslucent = true
        navigationController.navigationBar.tintColor = .label
        navigationController.navigationBar.prefersLargeTitles = false

        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundColor = .clear
        appearance.shadowColor = .clear
        appearance.titleTextAttributes = [
            .foregroundColor: UIColor.label,
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold)
        ]

        navigationController.navigationBar.standardAppearance = appearance
        navigationController.navigationBar.scrollEdgeAppearance = appearance
        navigationController.navigationBar.compactAppearance = appearance
        navigationController.navigationBar.compactScrollEdgeAppearance = appearance
    }

    // MARK: - Opening Animation

    /// Animates the source thumbnail into the fullscreen viewer.
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
        dimView.backgroundColor = .ncViewerBackground(.system)
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

        viewerView.alpha = 0

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

    // MARK: - Closing Animation

    /// Animates the fullscreen viewer back into the original thumbnail frame.
    ///
    /// - Parameters:
    ///   - viewerTransitionSource: Source thumbnail data used by the opening transition.
    ///   - window: Current app window.
    ///   - viewerView: Real viewer view to dismiss.
    private func animateClosing(
        viewerTransitionSource: NCViewerTransitionSource,
        in window: UIWindow,
        viewerView: UIView
    ) {
        let startFrame = aspectFitFrame(
            imageSize: viewerTransitionSource.image.size,
            containerSize: window.bounds.size
        )

        let imageView = UIImageView(image: viewerTransitionSource.image)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.frame = startFrame
        imageView.layer.cornerRadius = 0

        window.addSubview(imageView)

        viewerView.alpha = 0

        UIView.animate(
            withDuration: closingAnimationDuration,
            delay: 0,
            options: [.curveEaseInOut]
        ) {
            imageView.frame = viewerTransitionSource.sourceFrame
            imageView.layer.cornerRadius = viewerTransitionSource.cornerRadius
        } completion: { [weak self] _ in
            imageView.removeFromSuperview()
            viewerView.removeFromSuperview()
            self?.cleanup()
        }
    }

    // MARK: - Cleanup

    /// Clears the current overlay state.
    private func cleanup() {
        navigationController = nil
        viewerContainerView = nil
        currentViewerTransitionSource = nil
    }

    // MARK: - Helpers

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
}

// MARK: - Media Viewer Preview

#if DEBUG
import NextcloudKit

#Preview("Media Viewer - Light") {
    NCMediaViewerView.previewView()
        .preferredColorScheme(.light)
}

#Preview("Media Viewer - Dark") {
    NCMediaViewerView.previewView()
        .preferredColorScheme(.dark)
}

private extension NCMediaViewerView {
    static func previewView() -> some View {
        let metadata = tableMetadata()
        metadata.ocId = "preview-ocid"
        metadata.fileName = "preview.jpg"
        metadata.fileNameView = "preview.jpg"
        metadata.classFile = NKTypeClassFile.image.rawValue

        let model = NCMediaViewerModel(
            currentMetadata: metadata.detachedCopy(),
            ocIds: [
                metadata.ocId
            ],
            loader: NCMediaViewerLoader()
        )

        return NCMediaViewerView(model: model)
    }
}
#endif
