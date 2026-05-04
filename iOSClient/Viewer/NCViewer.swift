// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2020 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
import NextcloudKit
import QuickLook
import SwiftUI

class NCViewer: NSObject {
    let utilityFileSystem = NCUtilityFileSystem()
    let utility = NCUtility()
    let database = NCManageDatabase.shared
    private var viewerQuickLook: NCViewerQuickLook?

    @MainActor
    func getViewerController(metadata: tableMetadata, ocIds: [String]? = nil, image: UIImage? = nil, delegate: UIViewController? = nil, viewerTransitionSource: NCViewerTransitionSource?) async -> UIViewController? {
        let session = NCSession.shared.getSession(account: metadata.account)
        // Set Last Opening Date
        await self.database.setLocalFileLastOpeningDateAsync(metadata: metadata)

        // URL
        if metadata.classFile == NKTypeClassFile.url.rawValue,
           !NCUtilityFileSystem().isDirectoryE2EE(serverUrl: metadata.serverUrl, urlBase: session.urlBase, userId: session.userId, account: session.account) {
            // nextcloudtalk://open-conversation?server={serverURL}&user={userId}&withRoomToken={roomToken}
            if metadata.name == NCGlobal.shared.talkName {
                let pathComponents = metadata.url.components(separatedBy: "/")
                if pathComponents.contains("call") {
                    let talkComponents = pathComponents.last?.components(separatedBy: "#")
                    if let roomToken = talkComponents?.first {
                        let urlString = "nextcloudtalk://open-conversation?server=\(session.urlBase)&user=\(session.userId)&withRoomToken=\(roomToken)"
                        if let url = URL(string: urlString), UIApplication.shared.canOpenURL(url) {
                            await UIApplication.shared.open(url)
                        }
                    }
                }
            } else if let url = URL(string: metadata.url) {
                await UIApplication.shared.open(url)
            }
            return nil
        }

        // IMAGE AUDIO VIDEO
        else if metadata.isImage || metadata.isAudioOrVideo {
            let mediaOcIds = ocIds ?? [metadata.ocId]
            let model = NCMediaViewerModel(currentMetadata: metadata, ocIds: mediaOcIds, loader: NCMediaViewerLoader())

            NCMediaViewerPresenter.shared.show(model: model, viewerTransitionSource: viewerTransitionSource, from: delegate?.view)
        }

        // DOCUMENTS
        else if metadata.classFile == NKTypeClassFile.document.rawValue,
                !NCUtilityFileSystem().isDirectoryE2EE(serverUrl: metadata.serverUrl, urlBase: session.urlBase, userId: session.userId, account: session.account) {

            // PDF
            if metadata.isPDF {
                let vc = UIStoryboard(name: "NCViewerPDF", bundle: nil).instantiateInitialViewController() as? NCViewerPDF

                vc?.metadata = metadata
                vc?.imageIcon = image
                vc?.navigationItem.setBidiSafeTitle(metadata.fileNameView)

                return vc
            }

            // DirectEditing
            if metadata.isAvailableDirectEditingEditorView {
                let editors = utility.editorsDirectEditing(account: metadata.account, contentType: metadata.contentType).map { $0.lowercased() }
                guard let editorAdapter = NCDirectEditorAdapter.resolve(from: editors) else {
                    self.QLPreview(metadata: metadata, delegate: delegate)
                    return nil
                }
                let editor = editorAdapter.apiKey
                let editorViewController = editorAdapter.viewControllerEditor
                let options = NKRequestOptions(customUserAgent: editorAdapter.userAgent(utility))
                if metadata.url.isEmpty {
                    let fileNamePath = utilityFileSystem.getRelativeFilePath(metadata.fileName, serverUrl: metadata.serverUrl, session: session)

                    NCActivityIndicator.shared.start(backgroundView: delegate?.view)
                    let results = await NextcloudKit.shared.textOpenFileAsync(fileNamePath: fileNamePath, editor: editor, account: metadata.account, options: options) { task in
                        Task {
                            let identifier = await NCNetworking.shared.networkingTasks.createIdentifier(account: metadata.account,
                                                                                                        path: fileNamePath,
                                                                                                        name: "textOpenFile")
                            await NCNetworking.shared.networkingTasks.track(identifier: identifier, task: task)
                        }
                    }
                    NCActivityIndicator.shared.stop()

                    guard results.error == .success, let url = results.url else {
                        let windowScene = SceneManager.shared.getWindowScene(controller: delegate?.tabBarController as? NCMainTabBarController)
                        await showErrorBanner(windowScene: windowScene, text: results.error.errorDescription, errorCode: results.error.errorCode)
                        return nil
                    }

                    let vc = UIStoryboard(name: "NCViewerDirectEditing", bundle: nil).instantiateInitialViewController() as? NCViewerDirectEditing

                    vc?.metadata = metadata
                    vc?.editor = editorViewController
                    vc?.link = url
                    vc?.imageIcon = image
                    vc?.navigationItem.setBidiSafeTitle(metadata.fileNameView)

                    return vc
                } else {
                    let vc = UIStoryboard(name: "NCViewerDirectEditing", bundle: nil).instantiateInitialViewController() as? NCViewerDirectEditing

                    vc?.metadata = metadata
                    vc?.editor = editorViewController
                    vc?.link = metadata.url
                    vc?.imageIcon = image
                    vc?.navigationItem.setBidiSafeTitle(metadata.fileNameView)

                    return vc
                }
            }

            // RichDocument: Collabora
            if metadata.isAvailableRichDocumentEditorView {
                if metadata.url.isEmpty {
                    NCActivityIndicator.shared.start(backgroundView: delegate?.view)
                    let results = await NextcloudKit.shared.createUrlRichdocumentsAsync(fileID: metadata.fileId, account: metadata.account) { task in
                        Task {
                            let identifier = await NCNetworking.shared.networkingTasks.createIdentifier(account: metadata.account,
                                                                                                        path: metadata.fileId,
                                                                                                        name: "createUrlRichdocuments")
                            await NCNetworking.shared.networkingTasks.track(identifier: identifier, task: task)
                        }
                    }
                    NCActivityIndicator.shared.stop()

                    guard results.error == .success, let url = results.url else {
                        let windowScene = SceneManager.shared.getWindowScene(controller: delegate?.tabBarController as? NCMainTabBarController)
                        await showErrorBanner(windowScene: windowScene, text: results.error.errorDescription, errorCode: results.error.errorCode)
                        return nil
                    }

                    let vc = UIStoryboard(name: "NCViewerRichdocument", bundle: nil).instantiateInitialViewController() as? NCViewerRichDocument

                    vc?.metadata = metadata
                    vc?.link = url
                    vc?.imageIcon = image
                    vc?.navigationItem.setBidiSafeTitle(metadata.fileNameView)

                    return vc

                } else {
                    let vc = UIStoryboard(name: "NCViewerRichdocument", bundle: nil).instantiateInitialViewController() as? NCViewerRichDocument

                    vc?.metadata = metadata
                    vc?.link = metadata.url
                    vc?.imageIcon = image
                    vc?.navigationItem.setBidiSafeTitle(metadata.fileNameView)

                    return vc
                }
            }
        }

        // iOS QL-Preview
        self.QLPreview(metadata: metadata, delegate: delegate)

        return nil
    }

    func QLPreview(metadata: tableMetadata, delegate: UIViewController? = nil) {
        let item = URL(fileURLWithPath: utilityFileSystem.getDirectoryProviderStorageOcId(metadata.ocId,
                                                                                          fileName: metadata.fileNameView,
                                                                                          userId: metadata.userId,
                                                                                          urlBase: metadata.urlBase))
        if QLPreviewController.canPreview(item as QLPreviewItem) {
            let fileNamePath = NSTemporaryDirectory() + metadata.fileNameView
            utilityFileSystem.copyFile(atPath: utilityFileSystem.getDirectoryProviderStorageOcId(metadata.ocId,
                                                                                                 fileName: metadata.fileNameView,
                                                                                                 userId: metadata.userId,
                                                                                                 urlBase: metadata.urlBase), toPath: fileNamePath)
            let viewerQuickLook = NCViewerQuickLook(with: URL(fileURLWithPath: fileNamePath), isEditingEnabled: false, metadata: metadata)
            delegate?.present(viewerQuickLook, animated: true)
        } else {
            // Document Interaction Controller
            if let controller = delegate?.tabBarController as? NCMainTabBarController {
                Task {
                    await NCCreate().createActivityViewController(selectedMetadata: [metadata], controller: controller, sender: nil)
                }
            }
        }
    }
}

// MARK: - Media Viewer Presenter

/// Presents the media viewer as a fullscreen overlay above the current window.
///
/// The presenter installs a dedicated `UINavigationController` directly on the
/// active window instead of pushing into the app navigation stack. This keeps the
/// viewer independent from the current screen while still allowing the viewer to
/// use a real navigation bar for title, close, and menu actions.
///
/// When a transition source is provided, the presenter animates the visible
/// thumbnail into the fullscreen viewer and animates it back on dismissal.
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
    ///   - model: Media viewer model used to render and page through media items.
    ///   - viewerTransitionSource: Optional thumbnail source used for opening and closing animations.
    ///   - sourceView: Optional view used to resolve the current window. When nil, the active foreground key window is used.
    ///   - onMenu: Closure called when the navigation bar menu button is tapped.
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
    /// The navigation bar is transparent and overlays the SwiftUI content, allowing
    /// media pages to remain fullscreen while still using standard UIKit navigation
    /// items.
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
    /// The real viewer is kept hidden until the temporary transition image reaches
    /// its destination frame. This prevents seeing both the viewer image and the
    /// transition image at the same time.
    ///
    /// - Parameters:
    ///   - viewerTransitionSource: Source thumbnail data.
    ///   - window: Window that contains the overlay transition views.
    ///   - viewerView: Real viewer container view to reveal at the end.
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
    /// The real viewer is hidden immediately and replaced by a temporary transition
    /// image, avoiding double-image artifacts during the zoom-out animation.
    ///
    /// - Parameters:
    ///   - viewerTransitionSource: Source thumbnail data used by the opening transition.
    ///   - window: Window that contains the overlay transition views.
    ///   - viewerView: Real viewer container view to dismiss.
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

    /// Clears retained presenter state after the viewer has been removed.
    private func cleanup() {
        navigationController = nil
        viewerContainerView = nil
        currentViewerTransitionSource = nil
    }

    // MARK: - Helpers

    /// Returns the current active foreground key window.
    ///
    /// - Returns: Active foreground key window if available.
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

