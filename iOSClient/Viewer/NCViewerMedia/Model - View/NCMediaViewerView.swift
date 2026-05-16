// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

// MARK: - Media Viewer View

/// Main SwiftUI media viewer.
///
/// This view owns the `NCMediaViewerModel` as a `StateObject`.
/// Paging is handled by `NCMediaViewerPagingView`, which is backed by
/// `UICollectionView` to support large virtualized media lists.
///
/// Navigation buttons and title are provided by `NCMediaViewerHostingController`.
struct NCMediaViewerView: View {
    @StateObject private var model: NCMediaViewerModel
    let contextMenuController: NCMainTabBarController?
    let navigationBar: UINavigationBar?

    /// Creates the media viewer view.
    ///
    /// - Parameters:
    ///   - model: Media viewer model containing page state and loading logic.
    ///   - contextMenuController: Optional controller used to present context menu actions.
    ///   - navigationBar: Optional navigation bar reference used by video controls for top action positioning.
    init(
        model: NCMediaViewerModel,
        contextMenuController: NCMainTabBarController? = nil,
        navigationBar: UINavigationBar? = nil
    ) {
        _model = StateObject(wrappedValue: model)
        self.contextMenuController = contextMenuController
        self.navigationBar = navigationBar
    }

    var body: some View {
        ZStack {
            Color.ncViewerBackground(.system)
                .ignoresSafeArea()

            NCMediaViewerPagingView(
                model: model,
                contextMenuController: contextMenuController,
                navigationBar: navigationBar
            )
            .ignoresSafeArea()
        }
        .background(Color.ncViewerBackground(.system))
        .ignoresSafeArea()
        .statusBarHidden(true)
        .task {
            await model.loadSelectedPageIfNeeded()
        }
    }
}

// MARK: - Media Viewer Preview

#if DEBUG
import NextcloudKit

#Preview("Media Viewer - Light") {
    NCMediaViewerView.previewView()
        .preferredColorScheme(.light)
}

#Preview("Media Viewer - Dark") {
    NCMediaViewerView.previewView()
        .preferredColorScheme(.dark)
}

private extension NCMediaViewerView {
    static func previewView() -> some View {
        let metadata = tableMetadata()
        metadata.ocId = "preview-ocid"
        metadata.fileName = "preview.jpg"
        metadata.fileNameView = "preview.jpg"
        metadata.classFile = NKTypeClassFile.image.rawValue

        let model = NCMediaViewerModel(
            currentMetadata: metadata.detachedCopy(),
            ocIds: [
                metadata.ocId
            ],
            session: NCSession().getSession(account: ""),
            mediaSearch: false,
            loader: NCMediaViewerLoader()
        )

        return NCMediaViewerView(model: model)
    }
}
#endif
