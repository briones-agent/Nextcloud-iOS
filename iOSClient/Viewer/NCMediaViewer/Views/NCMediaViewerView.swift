// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

// MARK: - Main Media Viewer View

/// Root SwiftUI media viewer.
///
/// This view is responsible only for:
/// - displaying horizontal pages
/// - binding the selected page
/// - requesting page loading from the view model
///
/// It does not resolve metadata, read Realm, check local files, or start downloads.
struct NCMediaViewerView: View {

    // MARK: - State

    @StateObject private var viewModel: NCMediaViewerViewModel

    // MARK: - Init

    /// Creates the media viewer view.
    ///
    /// - Parameter viewModel: View model that owns page state and loading logic.
    init(viewModel: NCMediaViewerViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            TabView(selection: $viewModel.selectedOcId) {
                ForEach(viewModel.pages) { page in
                    NCMediaViewerPageView(page: page)
                        .tag(page.ocId)
                        .task(id: page.ocId) {
                            await viewModel.loadPageIfNeeded(ocId: page.ocId)
                        }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
        }
        .statusBarHidden(true)
    }
}
