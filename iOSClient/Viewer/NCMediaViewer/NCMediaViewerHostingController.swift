// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit
import Combine
import NextcloudKit

// MARK: - Media Viewer Hosting Controller

/// Hosting controller used by the media viewer.
///
/// This controller embeds the SwiftUI media viewer inside UIKit so the viewer can
/// use a real navigation item for the title, close button, and menu button.
@MainActor
final class NCMediaViewerHostingController: UIHostingController<NCMediaViewerView> {
    private let model: NCMediaViewerModel
    private let onClose: () -> Void
    private let onMenu: () -> Void

    private var cancellables = Set<AnyCancellable>()

    /// Creates a media viewer hosting controller.
    ///
    /// - Parameters:
    ///   - model: Media viewer model.
    ///   - onClose: Closure called when the close button is tapped.
    ///   - onMenu: Closure called when the menu button is tapped.
    init(
        model: NCMediaViewerModel,
        onClose: @escaping () -> Void,
        onMenu: @escaping () -> Void
    ) {
        self.model = model
        self.onClose = onClose
        self.onMenu = onMenu

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

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            style: .plain,
            target: self,
            action: #selector(menuButtonTapped)
        )
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
    }

    /// Updates the navigation title using the currently selected page metadata.
    private func updateTitle() {
        guard let page = model.selectedPageModel(),
              let metadata = page.metadata else {
            navigationItem.title = nil
            return
        }

        navigationItem.title = !metadata.fileNameView.isEmpty
            ? metadata.fileNameView
            : metadata.fileName
    }

    @objc
    private func closeButtonTapped() {
        onClose()
    }

    @objc
    private func menuButtonTapped() {
        onMenu()
    }
}
