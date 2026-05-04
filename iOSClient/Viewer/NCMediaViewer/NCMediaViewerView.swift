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
///
/// The viewer is displayed fullscreen and draws its own transparent overlay bar
/// above the media content.
struct NCMediaViewerView: View {

    // MARK: - State

    @StateObject private var model: NCMediaViewerModel
    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Actions

    private let onClose: () -> Void
    private let onMenu: () -> Void

    private var title: String {
        guard let page = model.selectedPageModel(),
              let metadata = page.metadata else {
            return ""
        }
        if !metadata.fileNameView.isEmpty {
            return metadata.fileNameView
        }

        return metadata.fileName
    }

    private var overlayButtonForegroundColor: Color {
        colorScheme == .dark ? .white : .black
    }

    // MARK: - Init

    /// Creates the media viewer view.
    ///
    /// - Parameters:
    ///   - model: Media viewer model containing page state and loading logic.
    ///   - onClose: Closure called when the back button is tapped.
    ///   - onMenu: Closure called when the menu button is tapped.
    init(
        model: NCMediaViewerModel,
        onClose: @escaping () -> Void = {},
        onMenu: @escaping () -> Void = {}
    ) {
        _model = StateObject(wrappedValue: model)
        self.onClose = onClose
        self.onMenu = onMenu
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            Color.ncViewerBackground(.system)
                .ignoresSafeArea()

            NCMediaViewerPagingView(model: model)
                .ignoresSafeArea()

            topOverlayBar
        }
        .background(Color.ncViewerBackground(.system))
        .ignoresSafeArea()
        .statusBarHidden(true)
        .task {
            await model.loadSelectedPageIfNeeded()
        }
    }

    // MARK: - Top Overlay Bar

    private var topOverlayBar: some View {
        HStack {
            Button {
                onClose()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(overlayButtonForegroundColor)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
                    .viewerGlassButton()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(NSLocalizedString("_back_", comment: "")))

            Text(title)
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundStyle(overlayButtonForegroundColor)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button {
                onMenu()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(overlayButtonForegroundColor)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
                    .viewerGlassButton()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(NSLocalizedString("_more_", comment: "")))
        }
        .padding(.horizontal, 12)
        .padding(.top, safeAreaTopInset + 4)
        .frame(maxWidth: .infinity)
        .background(topOverlayGradient, alignment: .top)
        .ignoresSafeArea(edges: .top)
    }

    private var topOverlayGradient: some View {
        LinearGradient(
            colors: [
                .black.opacity(0.34),
                .black.opacity(0.12),
                .clear
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: safeAreaTopInset + 72)
        .allowsHitTesting(false)
    }

    private var safeAreaTopInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .safeAreaInsets.top ?? 0
    }
}

// MARK: - Viewer Glass Button Modifier

private struct NCViewerGlassButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .padding(4)
                .glassEffect(.regular.interactive(), in: .circle)
        } else {
            content
                .padding(4)
                .background(.black.opacity(0.32))
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1)
        }
    }
}

private extension View {
    func viewerGlassButton() -> some View {
        modifier(NCViewerGlassButtonModifier())
    }
}

// MARK: - Media Viewer Presenter

/// Presents the media viewer as a fullscreen overlay above the current window.
///
/// This avoids navigation push/present transitions and allows clean
/// thumbnail-to-fullscreen opening and closing animations.
@MainActor
final class NCMediaViewerPresenter {
    // MARK: - Singleton

    static let shared = NCMediaViewerPresenter()

    // MARK: - State

    private var hostingController: UIHostingController<NCMediaViewerView>?
    private weak var hostingView: UIView?
    private var currentViewerTransitionSource: NCViewerTransitionSource?

    // MARK: - Constants

    private let openingAnimationDuration: TimeInterval = 0.28
    private let closingAnimationDuration: TimeInterval = 0.24

    // MARK: - Init

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

        let viewer = NCMediaViewerView(
            model: model,
            onClose: { [weak self] in
                self?.dismiss(animated: true)
            },
            onMenu: onMenu
        )

        let hostingController = UIHostingController(rootView: viewer)
        hostingController.view.backgroundColor = .ncViewerBackground(.system)
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
    /// - Parameter animated: Whether dismissal should be animated.
    func dismiss(animated: Bool = true) {
        guard let hostingView else {
            cleanup()
            return
        }

        guard animated else {
            hostingView.removeFromSuperview()
            cleanup()
            return
        }

        if let viewerTransitionSource = currentViewerTransitionSource,
           let window = hostingView.window {
            animateClosing(
                viewerTransitionSource: viewerTransitionSource,
                in: window,
                viewerView: hostingView
            )
            return
        }

        UIView.animate(
            withDuration: closingAnimationDuration,
            delay: 0,
            options: [.curveEaseInOut]
        ) {
            hostingView.alpha = 0
        } completion: { [weak self] _ in
            hostingView.removeFromSuperview()
            self?.cleanup()
        }
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

        // Keep the real viewer hidden during the whole zoom-in transition.
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

        // Hide the real viewer immediately.
        // This prevents the fullscreen viewer image from being visible behind
        // the temporary animated image during the zoom-out transition.
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
        hostingController = nil
        hostingView = nil
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
import SwiftUI
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

        return NCMediaViewerView(
            model: model,
            onClose: {},
            onMenu: {}
        )
    }
}
#endif
