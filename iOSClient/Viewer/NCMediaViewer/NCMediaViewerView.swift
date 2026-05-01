// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

// MARK: - Media Viewer View

/// Main SwiftUI media viewer.
///
/// This view owns the `NCMediaViewerModel` as a `StateObject`.
/// It renders only the currently visible page window exposed by the model.
///
/// The model keeps the full `ocIds` list internally, while this view renders
/// only `visiblePages` to avoid creating thousands of SwiftUI pages.
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
                        .ignoresSafeArea()
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
