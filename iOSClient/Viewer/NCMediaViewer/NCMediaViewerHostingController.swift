// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit
import Combine

// MARK: - Media Viewer Hosting Controller

/// UIKit hosting controller used by the media viewer.
///
/// This controller embeds the SwiftUI media viewer and provides standard UIKit
/// navigation items for the title, close button, and context menu button.
@MainActor
final class NCMediaViewerHostingController: UIHostingController<NCMediaViewerView>, UIAdaptivePresentationControllerDelegate {
    private let model: NCMediaViewerModel
    private let onClose: () -> Void
    private weak var contextMenuController: NCMainTabBarController?

    private var detailHostingController: UIHostingController<NCImageViewerDetailView>?
    private var isShowingDetail = false

    private var cancellables = Set<AnyCancellable>()

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
    ///   - onClose: Closure called when the navigation bar close button is tapped.
    init(model: NCMediaViewerModel, contextMenuController: NCMainTabBarController?, onClose: @escaping () -> Void) {
        self.model = model
        self.contextMenuController = contextMenuController
        self.onClose = onClose

        super.init(rootView: NCMediaViewerView(model: model))

        view.backgroundColor = .ncViewerBackground(.system)
        edgesForExtendedLayout = [.all]
        extendedLayoutIncludesOpaqueBars = true
        additionalSafeAreaInsets = .zero

        configureNavigationItem()
        observeModel()
        updateTitle()
    }

    @MainActor
    @available(*, unavailable)
    dynamic required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Navigation

    /// Configures the navigation item used by the viewer.
    private func configureNavigationItem() {
        navigationItem.largeTitleDisplayMode = .never

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

    /// Observes model changes and refreshes the navigation title.
    private func observeModel() {
        model.$selectedIndex
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateTitle()
            }
            .store(in: &cancellables)

        model.$revision
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateTitle()
            }
            .store(in: &cancellables)

        model.$isChromeHidden
            .receive(on: RunLoop.main)
            .sink { [weak self] isHidden in
                self?.setChromeHidden(isHidden, animated: true)
            }
            .store(in: &cancellables)
    }

    /// Updates the navigation title using the currently selected page metadata.
    private func updateTitle() {
        guard let metadata = model.selectedMetadata else {
            navigationItem.title = nil
            return
        }

        navigationItem.title = !metadata.fileNameView.isEmpty
            ? metadata.fileNameView
            : metadata.fileName
    }

    /// Shows or hides the viewer chrome.
    ///
    /// - Parameters:
    ///   - hidden: Whether the chrome should be hidden.
    ///   - animated: Whether the transition should be animated.
    private func setChromeHidden(
        _ hidden: Bool,
        animated: Bool
    ) {
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
        }
    }

    @objc
    private func closeButtonTapped() {
        onClose()
    }

    @objc
    private func imageDetailButtonTapped() {
        openDetail(animated: true)
    }

    // MARK: -

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
    private func presentDetailView(metadata: tableMetadata, index: Int, exif: ExifData, animated: Bool) {
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

    /// Downloads the full-resolution media file for the detail panel action.
    ///
    /// - Parameter metadata: Current selected media metadata.
    private func downloadFullResolution(metadata: tableMetadata) {
        let index = model.selectedIndex
        Task {
            _ = try? await NCMediaViewerLoader().downloadMedia(for: metadata, index: index)
        }
    }
}
