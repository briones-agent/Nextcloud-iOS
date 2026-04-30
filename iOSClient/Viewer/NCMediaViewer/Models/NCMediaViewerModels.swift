// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import RealmSwift

// MARK: - Page State

/// Represents the loading state of a media viewer page.
///
/// The page metadata is stored in `NCMediaViewerPageModel.metadata`.
/// This state only describes the current loading/rendering phase.
enum NCMediaViewerPageState {

    /// The page exists but no loading operation has started yet.
    case idle

    /// The page is resolving its `tableMetadata` from `ocId`.
    case loadingMetadata

    /// The metadata could not be found anymore.
    case metadataMissing

    /// Metadata exists and the viewer is checking if the full media file is already local.
    case checkingLocalFile

    /// Metadata exists, but the full media file is not local yet.
    ///
    /// `previewURL` can point to a local thumbnail/preview file if available.
    case remoteOnly(previewURL: URL?)

    /// The full media file is being downloaded.
    ///
    /// `progress` is optional because the first implementation may not expose progress yet.
    case downloading(previewURL: URL?, progress: Double?)

    /// The full media file is locally available and ready to be rendered.
    ///
    /// `previewURL` is preserved so the image renderer can keep showing the preview
    /// while the full-size image is decoded, avoiding flickering.
    case ready(localURL: URL, previewURL: URL?)

    /// The page failed while resolving metadata, checking local content, or downloading.
    case failed(previewURL: URL?, message: String)
}

// MARK: - Page Model

/// Represents one page inside the media viewer.
///
/// The viewer must not create one page for every `ocId` when the source list is large.
/// The ViewModel creates only a small visible window around the selected index.
struct NCMediaViewerPageModel: Identifiable {

    /// Stable identifier used by SwiftUI.
    let id: String

    /// Absolute index inside the full `ocIds` array.
    let index: Int

    /// Nextcloud file identifier.
    let ocId: String

    /// Detached metadata if already available.
    var metadata: tableMetadata?

    /// Current loading state of the page.
    var state: NCMediaViewerPageState

    /// Creates a page model.
    ///
    /// - Parameters:
    ///   - index: Absolute index inside the full `ocIds` array.
    ///   - ocId: Nextcloud file identifier.
    ///   - metadata: Detached metadata if already available.
    ///   - state: Initial page state.
    init(
        index: Int,
        ocId: String,
        metadata: tableMetadata? = nil,
        state: NCMediaViewerPageState = .idle
    ) {
        self.id = ocId
        self.index = index
        self.ocId = ocId
        self.metadata = metadata
        self.state = state
    }
}

// MARK: - Initial Model

/// Initial model used to open the media viewer.
///
/// The viewer receives:
/// - the current `tableMetadata`
/// - the ordered list of media `ocId` values
///
/// The current metadata must be detached before being passed here.
struct NCMediaViewerInitialModel {

    /// Metadata of the initially opened media.
    let currentMetadata: tableMetadata

    /// Ordered list of all media identifiers.
    let ocIds: [String]

    /// Creates the initial model for the media viewer.
    ///
    /// - Parameters:
    ///   - currentMetadata: Detached metadata of the initially opened media.
    ///   - ocIds: Ordered list of image/audio/video ocIds.
    init(
        currentMetadata: tableMetadata,
        ocIds: [String]
    ) {
        self.currentMetadata = currentMetadata
        self.ocIds = ocIds
    }

    /// Returns the ordered list of page identifiers.
    ///
    /// The current `ocId` is inserted only if missing.
    var normalizedOcIds: [String] {
        if ocIds.contains(currentMetadata.ocId) {
            return ocIds
        } else {
            return [currentMetadata.ocId] + ocIds
        }
    }

    /// Returns the initial selected index.
    ///
    /// If the current `ocId` is not found, the model starts from index zero.
    var initialSelectedIndex: Int {
        normalizedOcIds.firstIndex(of: currentMetadata.ocId) ?? 0
    }
}
