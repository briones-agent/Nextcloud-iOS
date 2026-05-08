// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit
import Combine

// MARK: - Media Viewer Paging View

/// UIKit-backed horizontal paging view for the media viewer.
///
/// This replaces SwiftUI `TabView(.page)` because `TabView` is not suitable for
/// very large virtualized media lists and can flicker when its page array changes.
///
/// The paging view uses a `UICollectionView` with reusable cells.
/// Each cell hosts a SwiftUI `NCMediaViewerPageView`.
struct NCMediaViewerPagingView: UIViewRepresentable {
    @ObservedObject var model: NCMediaViewerModel

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> NCMediaViewerCollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0

        let collectionView = NCMediaViewerCollectionView(
            frame: .zero,
            collectionViewLayout: layout
        )

        collectionView.backgroundColor = .ncViewerBackground(.system)
        collectionView.isPagingEnabled = true
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.alwaysBounceHorizontal = true
        collectionView.alwaysBounceVertical = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator

        collectionView.register(
            NCMediaViewerPagingCell.self,
            forCellWithReuseIdentifier: NCMediaViewerPagingCell.reuseIdentifier
        )

        context.coordinator.collectionView = collectionView

        collectionView.onLayoutSubviews = { [weak coordinator = context.coordinator] in
            coordinator?.updateLayoutAfterBoundsChangeIfNeeded()
        }

        DispatchQueue.main.async {
            context.coordinator.scrollToInitialIndexIfNeeded(animated: false)
        }

        return collectionView
    }

    func updateUIView(_ collectionView: NCMediaViewerCollectionView, context: Context) {
        context.coordinator.model = model
        collectionView.backgroundColor = .ncViewerBackground(.system)

        if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            let itemSize = collectionView.bounds.size

            if itemSize.width > 0,
               itemSize.height > 0,
               layout.itemSize != itemSize {
                layout.itemSize = itemSize
                layout.invalidateLayout()

                DispatchQueue.main.async {
                    context.coordinator.scrollToCurrentIndex(animated: false)
                }
            }
        }

        context.coordinator.refreshVisibleCells()
    }

    func makeCoordinator() -> NCMediaViewerPagingCoordinator {
        NCMediaViewerPagingCoordinator(model: model)
    }
}

// MARK: - Media Viewer Collection View

/// Collection view subclass used to detect bounds changes reliably.
///
/// This is needed because rotation, iPad split view resizing, and floating window
/// resizing can change the collection view bounds without SwiftUI immediately
/// rebuilding the representable.
final class NCMediaViewerCollectionView: UICollectionView {
    var onLayoutSubviews: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayoutSubviews?()
    }
}

// MARK: - Media Viewer Paging Coordinator

/// Coordinator for the UIKit paging collection view.
///
/// It acts as:
/// - collection view data source
/// - collection view delegate flow layout
@MainActor
final class NCMediaViewerPagingCoordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    var model: NCMediaViewerModel
    weak var collectionView: UICollectionView?

    private var didScrollToInitialIndex = false
    private var lastCollectionViewBoundsSize: CGSize = .zero
    private var cancellable: AnyCancellable?
    private var lastVisibleIndex: Int?

    // MARK: - Init

    init(model: NCMediaViewerModel) {
        self.model = model
        super.init()

        self.cancellable = model.$revision
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshVisibleCells()
            }
    }

    // MARK: - Layout

    /// Updates the paging layout after bounds changes.
    ///
    /// This keeps the selected page centered after rotation, split view resizing,
    /// or iPad floating window resizing.
    func updateLayoutAfterBoundsChangeIfNeeded() {
        guard let collectionView else {
            return
        }

        let boundsSize = collectionView.bounds.size

        guard boundsSize.width > 0,
              boundsSize.height > 0 else {
            return
        }

        guard boundsSize != lastCollectionViewBoundsSize else {
            return
        }

        lastCollectionViewBoundsSize = boundsSize

        if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            layout.itemSize = boundsSize
            layout.invalidateLayout()
        }

        collectionView.performBatchUpdates(nil) { [weak self] _ in
            self?.scrollToCurrentIndex(animated: false)
        }
    }

    // MARK: - Initial Scroll

    /// Scrolls to the initial selected page once.
    ///
    /// - Parameter animated: Whether the scroll should be animated.
    func scrollToInitialIndexIfNeeded(animated: Bool) {
        guard !didScrollToInitialIndex else {
            return
        }

        guard model.numberOfPages > 0 else {
            return
        }

        guard let collectionView else {
            return
        }

        collectionView.layoutIfNeeded()

        let index = model.initialSelectedIndex

        guard index >= 0,
              index < model.numberOfPages else {
            return
        }

        let indexPath = IndexPath(item: index, section: 0)

        collectionView.scrollToItem(
            at: indexPath,
            at: .centeredHorizontally,
            animated: animated
        )

        didScrollToInitialIndex = true
    }

    /// Scrolls to the current selected index.
    ///
    /// This is used after layout size changes, for example after rotation or
    /// iPad window resizing.
    ///
    /// - Parameter animated: Whether the scroll should be animated.
    func scrollToCurrentIndex(animated: Bool) {
        guard model.numberOfPages > 0 else {
            return
        }

        guard let collectionView else {
            return
        }

        collectionView.layoutIfNeeded()

        let index = model.selectedIndex

        guard index >= 0,
              index < model.numberOfPages else {
            return
        }

        let indexPath = IndexPath(item: index, section: 0)

        collectionView.scrollToItem(
            at: indexPath,
            at: .centeredHorizontally,
            animated: animated
        )
    }

    // MARK: - Visible Cell Refresh

    /// Refreshes currently visible cells using the latest page models.
    func refreshVisibleCells() {
        guard let collectionView else {
            return
        }

        for cell in collectionView.visibleCells {
            guard let cell = cell as? NCMediaViewerPagingCell,
                  let indexPath = collectionView.indexPath(for: cell),
                  let page = model.pageModel(at: indexPath.item) else {
                continue
            }

            cell.configure(page: page)
        }
    }

    // MARK: - UICollectionViewDataSource

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        model.numberOfPages
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: NCMediaViewerPagingCell.reuseIdentifier,
            for: indexPath
        )

        guard let pagingCell = cell as? NCMediaViewerPagingCell else {
            return cell
        }

        if let page = model.pageModel(at: indexPath.item) {
            pagingCell.configure(page: page)
        } else {
            pagingCell.configureEmpty()
        }

        return pagingCell
    }

    // MARK: - UICollectionViewDelegateFlowLayout

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        collectionView.bounds.size
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateSelectedIndexFromScrollView(scrollView)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        updateSelectedIndexFromScrollView(scrollView)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            updateSelectedIndexFromScrollView(scrollView)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let width = scrollView.bounds.width

        guard width > 0 else {
            return
        }

        let rawIndex = scrollView.contentOffset.x / width
        let index = Int(round(rawIndex))

        guard index >= 0,
              index < model.numberOfPages else {
            return
        }

        guard lastVisibleIndex != index else {
            return
        }

        lastVisibleIndex = index
        model.setSelectedIndex(index)

        Task {
            await model.prefetchVisiblePageIfNeeded(index: index)
        }
    }

    /// Updates the selected page index after paging has settled.
    ///
    /// - Parameter scrollView: Source scroll view.
    private func updateSelectedIndexFromScrollView(_ scrollView: UIScrollView) {
        let width = scrollView.bounds.width

        guard width > 0 else {
            return
        }

        let rawIndex = scrollView.contentOffset.x / width
        let index = Int(round(rawIndex))

        guard index >= 0,
              index < model.numberOfPages else {
            return
        }

        Task {
            await model.displayPage(at: index)
        }
    }
}

// MARK: - Media Viewer Paging Cell

/// Collection view cell hosting one SwiftUI media viewer page.
final class NCMediaViewerPagingCell: UICollectionViewCell {
    static let reuseIdentifier = "NCMediaViewerPagingCell"

    private var currentOcId: String?
    private var hostingController: UIHostingController<AnyView>?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .ncViewerBackground(.system)
        contentView.backgroundColor = .ncViewerBackground(.system)
        contentView.clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)

        backgroundColor = .ncViewerBackground(.system)
        contentView.backgroundColor = .ncViewerBackground(.system)
        contentView.clipsToBounds = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()

        currentOcId = nil

        hostingController?.view.removeFromSuperview()
        hostingController = nil

        backgroundColor = .ncViewerBackground(.system)
        contentView.backgroundColor = .ncViewerBackground(.system)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        hostingController?.view.frame = contentView.bounds
    }

    // MARK: - Configuration

    /// Configures the cell with a media viewer page.
    ///
    /// - Parameter page: Page model to render.
    func configure(page: NCMediaViewerPageModel) {
        backgroundColor = .ncViewerBackground(.system)
        contentView.backgroundColor = .ncViewerBackground(.system)

        let view = AnyView(
            NCMediaViewerPageView(page: page)
                .id(page.ocId)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.ncViewerBackground(.system))
                .ignoresSafeArea()
        )

        if currentOcId != page.ocId {
            hostingController?.view.removeFromSuperview()
            hostingController = nil
            currentOcId = page.ocId
        }

        if let hostingController {
            hostingController.rootView = view
            hostingController.view.backgroundColor = .ncViewerBackground(.system)
            hostingController.view.frame = contentView.bounds
        } else {
            let hostingController = UIHostingController(rootView: view)
            hostingController.view.backgroundColor = .ncViewerBackground(.system)
            hostingController.view.frame = contentView.bounds
            hostingController.view.autoresizingMask = [
                .flexibleWidth,
                .flexibleHeight
            ]

            contentView.addSubview(hostingController.view)
            self.hostingController = hostingController
        }
    }

    /// Configures the cell as an empty page.
    func configureEmpty() {
        backgroundColor = .ncViewerBackground(.system)
        contentView.backgroundColor = .ncViewerBackground(.system)

        currentOcId = nil

        hostingController?.view.removeFromSuperview()
        hostingController = nil

        let view = AnyView(
            Color.ncViewerBackground(.system)
                .ignoresSafeArea()
        )

        let hostingController = UIHostingController(rootView: view)
        hostingController.view.backgroundColor = .ncViewerBackground(.system)
        hostingController.view.frame = contentView.bounds
        hostingController.view.autoresizingMask = [
            .flexibleWidth,
            .flexibleHeight
        ]

        contentView.addSubview(hostingController.view)
        self.hostingController = hostingController
    }
}
