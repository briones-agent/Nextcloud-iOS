// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit
import Combine
import NextcloudKit

// MARK: - Media Viewer Hosting Controller

/// UIKit hosting controller used by the media viewer.
///
/// This controller embeds the SwiftUI media viewer and provides standard UIKit
/// navigation items for the title, close button, context menu button, and detail button.
@MainActor
final class NCMediaViewerHostingController: UIHostingController<NCMediaViewerView>, UIAdaptivePresentationControllerDelegate {
    private let model: NCMediaViewerModel
    private let onClose: () -> Void
    private let onCloseToTransitionSource: ((_ viewerTransitionSource: NCViewerTransitionSource) -> Void)?
    private weak var contextMenuController: NCMainTabBarController?

    private var detailHostingController: UIHostingController<NCImageViewerDetailView>?
    private var isShowingDetail = false
    private var cancellables = Set<AnyCancellable>()
    private var transferDelegate: NCMediaViewerTransferDelegate?
    private weak var currentNavigationBar: UINavigationBar?
    private let floatingTitleView = NCViewerFloatingTitleView()
    private var floatingTitleConstraints: [NSLayoutConstraint] = []

    private lazy var floatingTitleDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private lazy var moreNavigationItem = UIBarButtonItem(
        image: NCImageCache.shared.getImageButtonMore(),
        primaryAction: nil,
        menu: UIMenu(title: "", children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self,
                      let metadata = self.model.selectedMetadata else {
                    completion([])
                    return
                }

                if let menu = NCContextMenuViewer(
                    metadata: metadata,
                    controller: self.contextMenuController,
                    webView: false,
                    sender: self
                ).viewMenu() {
                    completion(menu.children)
                } else {
                    completion([])
                }
            }
        ])
    )

    private lazy var imageDetailNavigationItem = UIBarButtonItem(
        image: NCUtility().loadImage(
            named: "info.circle",
            colors: [NCBrandColor.shared.iconImageColor]
        ),
        style: .plain,
        target: self,
        action: #selector(imageDetailButtonTapped)
    )

    /// Creates a media viewer hosting controller.
    ///
    /// - Parameters:
    ///   - model: Media viewer model used to render and page through media items.
    ///   - contextMenuController: Main tab bar controller used to build viewer context menus.
    ///   - onClose: Closure called when the viewer should close normally.
    ///   - onCloseToTransitionSource: Closure called when the viewer should close toward a specific transition destination.
    init(
        model: NCMediaViewerModel,
        contextMenuController: NCMainTabBarController?,
        onClose: @escaping () -> Void,
        onCloseToTransitionSource: ((_ viewerTransitionSource: NCViewerTransitionSource) -> Void)? = nil
    ) {
        self.model = model
        self.contextMenuController = contextMenuController
        self.onClose = onClose
        self.onCloseToTransitionSource = onCloseToTransitionSource

        super.init(
            rootView: NCMediaViewerView(
                model: model,
                contextMenuController: contextMenuController,
                navigationBar: nil
            )
        )

        self.transferDelegate = NCMediaViewerTransferDelegate { [weak self] deletedOcId in
            guard let self else {
                return
            }

            self.model.markPageAsDeleted(ocId: deletedOcId)
        }

        view.backgroundColor = .ncViewerBackground(.system)
        edgesForExtendedLayout = [.all]
        extendedLayoutIncludesOpaqueBars = true
        additionalSafeAreaInsets = .zero

        configureNavigationItem()
        observeModel()
    }

    @MainActor
    @available(*, unavailable)
    dynamic required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        updateTitleLabel(metadata: model.selectedMetadata)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        guard let transferDelegate else {
            return
        }

        Task {
            await NCNetworking.shared.transferDispatcher.addDelegate(transferDelegate)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        guard let transferDelegate else {
            return
        }

        Task {
            await NCNetworking.shared.transferDispatcher.removeDelegate(transferDelegate)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        updateRootViewNavigationBarIfNeeded()
        configureFloatingTitleViewIfNeeded()
    }

    private func updateRootViewNavigationBarIfNeeded() {
        let navigationBar = navigationController?.navigationBar

        guard currentNavigationBar !== navigationBar else {
            return
        }

        currentNavigationBar = navigationBar

        rootView = NCMediaViewerView(
            model: model,
            contextMenuController: contextMenuController,
            navigationBar: navigationBar
        )
    }

    // MARK: - Closing

    /// Closes the viewer normally.
    func close() {
        onClose()
    }

    /// Closes the viewer toward a specific transition destination.
    ///
    /// - Parameter viewerTransitionSource: Current destination frame used by the closing animation.
    func close(to viewerTransitionSource: NCViewerTransitionSource) {
        if let onCloseToTransitionSource {
            onCloseToTransitionSource(viewerTransitionSource)
        } else {
            onClose()
        }
    }

    // MARK: - Navigation

    /// Configures the navigation item used by the viewer.
    private func configureNavigationItem() {
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.title = nil
        navigationItem.titleView = nil

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "chevron.left"),
            style: .plain,
            target: self,
            action: #selector(closeButtonTapped)
        )

        navigationItem.rightBarButtonItems = [
            moreNavigationItem,
            imageDetailNavigationItem
        ]
    }

    /// Observes model changes and refreshes navigation UI.
    private func observeModel() {
        model.$selectedIndex
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateTitleLabel(metadata: self.model.selectedMetadata)
            }
            .store(in: &cancellables)

        model.$revision
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateTitleLabel(metadata: self.model.selectedMetadata)
            }
            .store(in: &cancellables)

        model.$isChromeHidden
            .receive(on: RunLoop.main)
            .sink { [weak self] isHidden in
                self?.setChromeHidden(isHidden, animated: true)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .ncMediaVLCViewerClose)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else {
                    return
                }

                NotificationCenter.default.post(
                    name: .ncMediaViewerStopPlayback,
                    object: nil
                )

                self.close()
            }
            .store(in: &cancellables)
    }

    /// Configures the floating title view inside the navigation bar chrome.
    private func configureFloatingTitleViewIfNeeded() {
        guard let navigationBar = navigationController?.navigationBar,
              floatingTitleView.superview !== navigationBar else {
            return
        }

        floatingTitleConstraints.forEach { $0.isActive = false }
        floatingTitleConstraints.removeAll()
        floatingTitleView.removeFromSuperview()
        navigationBar.addSubview(floatingTitleView)

        floatingTitleConstraints = [
            floatingTitleView.centerXAnchor.constraint(equalTo: navigationBar.centerXAnchor),
            floatingTitleView.centerYAnchor.constraint(equalTo: navigationBar.centerYAnchor),
            floatingTitleView.widthAnchor.constraint(lessThanOrEqualTo: navigationBar.widthAnchor, multiplier: 0.42)
        ]
        NSLayoutConstraint.activate(floatingTitleConstraints)
    }

    /// Updates the floating title view using the provided media metadata.
    ///
    /// - Parameter metadata: Media metadata used to build the visible title content.
    private func updateTitleLabel(metadata: tableMetadata?) {
        guard let metadata else {
            floatingTitleView.update(primaryText: nil, secondaryText: nil)
            return
        }

        let primaryTitle = metadata.fileNameView.isEmpty
            ? metadata.fileName
            : metadata.fileNameView

        floatingTitleView.update(
            primaryText: primaryTitle,
            secondaryText: floatingTitleSecondaryText(for: metadata)
        )
    }

    /// Builds the secondary floating title text for the provided metadata.
    ///
    /// - Parameter metadata: Media metadata used to derive the secondary title line.
    /// - Returns: Secondary title text shown below the main title.
    private func floatingTitleSecondaryText(for metadata: tableMetadata) -> String? {
        floatingTitleDateFormatter.string(from: metadata.date as Date)
    }

    /// Shows or hides the viewer chrome.
    ///
    /// - Parameters:
    ///   - hidden: Whether the chrome should be hidden.
    ///   - animated: Whether the transition should be animated.
    private func setChromeHidden(_ hidden: Bool, animated: Bool) {
        navigationController?.setNavigationBarHidden(
            hidden,
            animated: animated
        )

        UIView.animate(
            withDuration: animated ? 0.2 : 0,
            delay: 0,
            options: [.curveEaseInOut]
        ) {
            self.view.backgroundColor = hidden
                ? .black
                : .ncViewerBackground(.system)
            self.floatingTitleView.alpha = hidden ? 0 : 1
        }
    }

    @objc
    private func closeButtonTapped() {
        close()
    }

    @objc
    private func imageDetailButtonTapped() {
        guard !isSelectedPageDeleted else {
            return
        }

        openDetail(animated: true)
    }

    // MARK: - Detail

    private var isSelectedPageDeleted: Bool {
        guard let page = model.selectedPageModel() else {
            return false
        }

        if case .deleted = page.state {
            return true
        }

        return false
    }

    /// Opens or closes the media detail panel for the currently selected media item.
    ///
    /// - Parameter animated: Whether the presentation should be animated.
    private func openDetail(animated: Bool = true) {
        guard !isShowingDetail else {
            closeDetail(animated: animated)
            return
        }

        guard let metadata = model.selectedMetadata else {
            return
        }

        let index = model.selectedIndex
        isShowingDetail = true

        NCUtility().getExif(metadata: metadata) { [weak self] exif in
            Task { @MainActor in
                guard let self else {
                    return
                }

                self.presentDetailView(
                    metadata: metadata,
                    index: index,
                    exif: exif,
                    animated: animated
                )
            }
        }
    }

    /// Presents the SwiftUI media detail panel.
    ///
    /// - Parameters:
    ///   - metadata: Current selected media metadata.
    ///   - index: Page index associated with the metadata.
    ///   - exif: EXIF information resolved for the selected media.
    ///   - animated: Whether presentation should be animated.
    private func presentDetailView(
        metadata: tableMetadata,
        index: Int,
        exif: ExifData,
        animated: Bool
    ) {
        let detailView = NCImageViewerDetailView(
            metadata: metadata,
            exif: exif,
            onDownloadFullResolution: { [weak self] in
                self?.downloadFullResolution(metadata: metadata)
            }
        )

        let hostingController = UIHostingController(rootView: detailView)
        hostingController.view.backgroundColor = .ncViewerBackground(.system)
        hostingController.modalPresentationStyle = .pageSheet

        if let sheet = hostingController.sheetPresentationController {
            sheet.detents = [
                .medium(),
                .large()
            ]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
            sheet.preferredCornerRadius = 20
        }

        detailHostingController = hostingController
        hostingController.presentationController?.delegate = self

        present(hostingController, animated: animated)
    }

    /// Closes the media detail panel.
    ///
    /// - Parameter animated: Whether dismissal should be animated.
    private func closeDetail(animated: Bool = true) {
        guard let detailHostingController else {
            isShowingDetail = false
            return
        }

        detailHostingController.dismiss(animated: animated) { [weak self] in
            self?.detailHostingController = nil
            self?.isShowingDetail = false
        }
    }

    /// Resets the detail state when the sheet is dismissed interactively.
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        detailHostingController = nil
        isShowingDetail = false
    }

    /// Marks the currently selected media item as deleted in the viewer.
    ///
    /// This is used immediately after the user confirms a delete action, before the
    /// asynchronous transfer delegate reports the delete completion.
    @MainActor
    func markCurrentItemAsDeleted() {
        guard let metadata = model.selectedMetadata else {
            return
        }

        model.markPageAsDeleted(ocId: metadata.ocId)
    }

    /// Marks a specific media item as deleted in the viewer.
    ///
    /// - Parameter ocId: Deleted file identifier.
    @MainActor
    func markItemAsDeleted(ocId: String) {
        model.markPageAsDeleted(ocId: ocId)
    }

    /// Downloads the full-resolution media file for the detail panel action.
    ///
    /// - Parameter metadata: Current selected media metadata.
    private func downloadFullResolution(metadata: tableMetadata) {
        let index = model.selectedIndex

        Task {
            _ = try? await NCMediaViewerLoader().downloadMedia(
                for: metadata,
                index: index
            )
        }
    }
}

// MARK: - Media Viewer Transfer Delegate

/// Bridges transfer events into the MainActor-isolated media viewer controller.
///
/// `NCTransferDelegate` is not MainActor-isolated, so `NCMediaViewerHostingController`
/// must not conform to it directly in Swift 6.
final class NCMediaViewerTransferDelegate: NSObject, NCTransferDelegate {
    private let onDeletedOcId: @MainActor (_ ocId: String) -> Void
    let sceneIdentifier: String = ""

    init(onDeletedOcId: @escaping @MainActor (_ ocId: String) -> Void) {
        self.onDeletedOcId = onDeletedOcId
    }

    func transferReloadData(serverUrl: String?) { }

    func transferReloadDataSource(serverUrl: String?, requestData: Bool, status: Int?) { }

    func transferProgressDidUpdate(progress: Float, totalBytes: Int64, totalBytesExpected: Int64, fileName: String, serverUrl: String) { }

    func transferChange(
        status: String,
        account: String,
        fileName: String,
        serverUrl: String,
        selector: String?,
        ocId: String,
        destination: String?,
        error: NKError
    ) {
        guard status == NCGlobal.shared.networkingStatusDelete,
              error == .success else {
            return
        }

        Task { @MainActor in
            onDeletedOcId(ocId)
        }
    }
}
