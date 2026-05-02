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

    // MARK: - Properties

    @ObservedObject var model: NCMediaViewerModel

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0

        let collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: layout
        )

        collectionView.backgroundColor = .black
        collectionView.isPagingEnabled = true
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.alwaysBounceHorizontal = true
        collectionView.alwaysBounceVertical = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.prefetchDataSource = context.coordinator

        collectionView.register(
            NCMediaViewerPagingCell.self,
            forCellWithReuseIdentifier: NCMediaViewerPagingCell.reuseIdentifier
        )

        context.coordinator.collectionView = collectionView

        DispatchQueue.main.async {
            context.coordinator.scrollToInitialIndexIfNeeded(animated: false)
        }

        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.model = model

        if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            let itemSize = collectionView.bounds.size

            if layout.itemSize != itemSize {
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

// MARK: - Media Viewer Paging Coordinator

/// Coordinator for the UIKit paging collection view.
///
/// It acts as:
/// - collection view data source
/// - collection view delegate
/// - flow layout delegate
/// - prefetch data source
@MainActor
final class NCMediaViewerPagingCoordinator: NSObject,
                                            UICollectionViewDataSource,
                                            UICollectionViewDelegateFlowLayout,
                                            UICollectionViewDataSourcePrefetching {

    // MARK: - Properties

    var model: NCMediaViewerModel
    weak var collectionView: UICollectionView?

    private var didScrollToInitialIndex = false
    private var cancellable: AnyCancellable?

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

    func collectionView(
        _ collectionView: UICollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        model.numberOfPages
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
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

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        collectionView.bounds.size
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateSelectedIndexFromScrollView(scrollView)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        updateSelectedIndexFromScrollView(scrollView)
    }

    func scrollViewDidEndDragging(
        _ scrollView: UIScrollView,
        willDecelerate decelerate: Bool
    ) {
        if !decelerate {
            updateSelectedIndexFromScrollView(scrollView)
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

    // MARK: - UICollectionViewDataSourcePrefetching

    func collectionView(
        _ collectionView: UICollectionView,
        prefetchItemsAt indexPaths: [IndexPath]
    ) {
        for indexPath in indexPaths {
            Task {
                await model.loadPageIfNeeded(index: indexPath.item)
            }
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cancelPrefetchingForItemsAt indexPaths: [IndexPath]
    ) {
        for indexPath in indexPaths {
            model.cancelLoading(index: indexPath.item)
        }
    }
}

// MARK: - Media Viewer Paging Cell

/// Collection view cell hosting one SwiftUI media viewer page.
final class NCMediaViewerPagingCell: UICollectionViewCell {

    // MARK: - Static

    static let reuseIdentifier = "NCMediaViewerPagingCell"

    // MARK: - State

    private var hostingController: UIHostingController<AnyView>?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .black
        contentView.backgroundColor = .black
        contentView.clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)

        backgroundColor = .black
        contentView.backgroundColor = .black
        contentView.clipsToBounds = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()

        hostingController?.rootView = AnyView(
            Color.black
                .ignoresSafeArea()
        )
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
        let view = AnyView(
            NCMediaViewerPageView(page: page)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .ignoresSafeArea()
        )

        if let hostingController {
            hostingController.rootView = view
            hostingController.view.frame = contentView.bounds
        } else {
            let hostingController = UIHostingController(rootView: view)
            hostingController.view.backgroundColor = .black
            hostingController.view.frame = contentView.bounds

            contentView.addSubview(hostingController.view)
            self.hostingController = hostingController
        }
    }

    /// Configures the cell as an empty black page.
    func configureEmpty() {
        let view = AnyView(
            Color.black
                .ignoresSafeArea()
        )

        if let hostingController {
            hostingController.rootView = view
            hostingController.view.frame = contentView.bounds
        } else {
            let hostingController = UIHostingController(rootView: view)
            hostingController.view.backgroundColor = .black
            hostingController.view.frame = contentView.bounds

            contentView.addSubview(hostingController.view)
            self.hostingController = hostingController
        }
    }
}
