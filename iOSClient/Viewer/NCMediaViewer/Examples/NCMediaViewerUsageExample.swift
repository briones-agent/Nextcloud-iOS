// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

// MARK: - Media Viewer Usage Example

/// Example helper for opening the media viewer from UIKit.
///
/// This file is optional and can be removed after integration.
enum NCMediaViewerUsageExample {

    /// Creates a hosting controller for the media viewer.
    ///
    /// - Parameters:
    ///   - currentMetadata: Current detached metadata.
    ///   - ocIds: Ordered list of image/video ocIds.
    ///   - loader: Media viewer loader.
    /// - Returns: A hosting controller ready to be presented.
    @MainActor
    static func makeHostingController(
        currentMetadata: tableMetadata,
        ocIds: [String],
        loader: NCMediaViewerLoading = NCNextcloudMediaViewerLoader()
    ) -> UIHostingController<NCMediaViewerView> {
        let initialModel = NCMediaViewerInitialModel(
            currentMetadata: currentMetadata,
            ocIds: ocIds
        )

        let viewModel = NCMediaViewerViewModel(
            initialModel: initialModel,
            loader: loader
        )

        return UIHostingController(
            rootView: NCMediaViewerView(viewModel: viewModel)
        )
    }
}
