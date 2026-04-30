// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

// MARK: - Main Media Viewer View

/// Root SwiftUI media viewer.
///
/// This view displays only the small visible page window exposed by the ViewModel.
/// It does not render all `ocId` values when the media list is large.
struct NCMediaViewerView: View {

    // MARK: - State

    @StateObject private var model: NCMediaViewerModel

    // MARK: - Init

    /// Creates the media viewer view.
    ///
    /// - Parameter viewModel: View model that owns page state and loading logic.
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
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
        }
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
