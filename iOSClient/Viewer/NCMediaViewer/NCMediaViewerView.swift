// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit

// MARK: - Media Viewer View

/// Main SwiftUI media viewer.
///
/// This view owns the `NCMediaViewerModel` as a `StateObject`.
/// It renders only the currently visible page window exposed by the model.
///
/// `TabView(.page)` uses an internal UIKit pager. The background helper attempts
/// to disable vertical bouncing on the internal scroll views to avoid a small
/// vertical jump when the first touch is slightly diagonal.
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

            TabView(selection: $model.selectedIndex) {
                ForEach(model.visiblePages) { page in
                    NCMediaViewerPageView(page: page)
                        .tag(page.index)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                        .ignoresSafeArea()
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(Color.black)
            .background(DisableVerticalBounceInPagingTabView())
            .ignoresSafeArea()
        }
        .background(Color.black)
        .ignoresSafeArea()
        .statusBarHidden(true)
        .task {
            await model.loadSelectedPageIfNeeded()
        }
        .onChange(of: model.selectedIndex) { _, newIndex in
            Task {
                await model.handleSelectedIndexChanged(newIndex)
            }
        }
    }
}

// MARK: - Disable Vertical Bounce In Paging TabView

/// UIKit helper used to inspect the internal views created by SwiftUI `TabView(.page)`.
///
/// The goal is to disable vertical bouncing without disabling horizontal paging.
/// This is intentionally limited to scroll views found under this specific view tree.
private struct DisableVerticalBounceInPagingTabView: UIViewRepresentable {

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false

        DispatchQueue.main.async {
            configureScrollViews(from: view)
        }

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            configureScrollViews(from: uiView)
        }
    }

    private func configureScrollViews(from view: UIView) {
        guard let rootView = view.superview else {
            return
        }

        let scrollViews = rootView.findSubviews(of: UIScrollView.self)

        for scrollView in scrollViews {
            scrollView.alwaysBounceVertical = false
            scrollView.showsVerticalScrollIndicator = false
            scrollView.contentInsetAdjustmentBehavior = .never
            scrollView.isDirectionalLockEnabled = true
        }

        let collectionViews = rootView.findSubviews(of: UICollectionView.self)

        for collectionView in collectionViews {
            collectionView.alwaysBounceVertical = false
            collectionView.showsVerticalScrollIndicator = false
            collectionView.contentInsetAdjustmentBehavior = .never
            collectionView.isDirectionalLockEnabled = true
        }
    }
}

// MARK: - UIView Search Helper

private extension UIView {

    /// Recursively finds all subviews matching the requested type.
    ///
    /// - Parameter type: UIView subclass type to search for.
    /// - Returns: Matching subviews found recursively.
    func findSubviews<T: UIView>(of type: T.Type) -> [T] {
        var result: [T] = []

        for subview in subviews {
            if let matchingSubview = subview as? T {
                result.append(matchingSubview)
            }

            result.append(contentsOf: subview.findSubviews(of: type))
        }

        return result
    }
}
