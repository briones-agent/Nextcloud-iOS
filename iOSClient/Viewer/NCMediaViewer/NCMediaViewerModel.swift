// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import RealmSwift
import NextcloudKit

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

    /// Image page state.
    ///
    /// The same image view remains mounted while the page moves from preview
    /// to full image. This avoids flickering caused by replacing SwiftUI view branches.
    case image(previewURL: URL?, localURL: URL?, progress: Double?)

    /// Generic downloading state for non-image media.
    case downloading(previewURL: URL?, progress: Double?)

    /// Non-image media is locally available.
    case ready(localURL: URL, previewURL: URL?)

    /// The page failed while resolving metadata, checking local content, or downloading.
    case failed(previewURL: URL?, message: String)
}

// MARK: - Page Model

/// Represents one page inside the media viewer.
///
/// The model does not create one page for every media item upfront.
/// Pages are created lazily when requested by the UIKit pager.
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

// MARK: - Media Viewer Model

/// Model for the media viewer.
///
/// This model is optimized for very large media lists.
/// It stores the full ordered `ocIds` array, but creates page models lazily only
/// when the pager asks for them.
///
/// Responsibilities:
/// - keep the current selected index
/// - expose page count
/// - create page models lazily
/// - resolve metadata lazily
/// - request preview URLs
/// - check local media availability
/// - start full media downloads through the loader
/// - prefetch previous and next pages
/// - update page states
///
/// It does not render UI and does not directly access Realm, FileManager,
/// or networking APIs. Those responsibilities belong to `NCMediaViewerLoading`.
@MainActor
final class NCMediaViewerModel: ObservableObject {

    // MARK: - Published State

    /// Currently selected absolute index inside the full `ocIds` array.
    @Published private(set) var selectedIndex: Int

    /// Incremented when a page changes state.
    ///
    /// The UIKit pager observes this value indirectly through SwiftUI updates
    /// and refreshes visible cells.
    @Published private(set) var revision: Int = 0

    // MARK: - Dependencies

    private let loader: NCMediaViewerLoading

    // MARK: - Source Data

    /// Full ordered media identifier list.
    private let ocIds: [String]

    // MARK: - Page Cache

    /// Page state cache keyed by `ocId`.
    ///
    /// Pages are created lazily when the pager asks for a specific index.
    private var cachedPagesByOcId: [String: NCMediaViewerPageModel] = [:]

    // MARK: - Running Tasks

    /// Running page loading tasks keyed by `ocId`.
    private var loadingTasksByOcId: [String: Task<Void, Never>] = [:]

    // MARK: - Public Read-Only Access

    /// Total number of media pages.
    var numberOfPages: Int {
        ocIds.count
    }

    /// Initial selected index.
    var initialSelectedIndex: Int {
        selectedIndex
    }

    // MARK: - Init

    /// Creates a media viewer model.
    ///
    /// - Parameters:
    ///   - initialModel: Initial viewer model containing current metadata and ordered ocIds.
    ///   - loader: Loader used to resolve metadata, local URLs, previews, and downloads.
    init(
        initialModel: NCMediaViewerInitialModel,
        loader: NCMediaViewerLoading
    ) {
        self.loader = loader
        self.ocIds = initialModel.normalizedOcIds
        self.selectedIndex = initialModel.initialSelectedIndex

        let currentPage = NCMediaViewerPageModel(
            index: initialModel.initialSelectedIndex,
            ocId: initialModel.currentMetadata.ocId,
            metadata: initialModel.currentMetadata,
            state: .idle
        )

        self.cachedPagesByOcId[initialModel.currentMetadata.ocId] = currentPage
    }

    /// Creates a media viewer model from the current metadata and ordered media identifiers.
    ///
    /// - Parameters:
    ///   - currentMetadata: Detached metadata of the initially opened media.
    ///   - ocIds: Ordered list of image/audio/video ocIds.
    ///   - loader: Loader used to resolve metadata, local URLs, previews, and downloads.
    convenience init(
        currentMetadata: tableMetadata,
        ocIds: [String],
        loader: NCMediaViewerLoading
    ) {
        let initialModel = NCMediaViewerInitialModel(
            currentMetadata: currentMetadata,
            ocIds: ocIds
        )

        self.init(
            initialModel: initialModel,
            loader: loader
        )
    }

    deinit {
        loadingTasksByOcId.values.forEach { $0.cancel() }
        loadingTasksByOcId.removeAll()
    }

    // MARK: - Public API

    /// Returns the page model for an absolute index.
    ///
    /// If the page is not cached yet, a lightweight idle page is created and cached.
    ///
    /// - Parameter index: Absolute index inside the full `ocIds` array.
    /// - Returns: Page model if the index exists.
    func pageModel(at index: Int) -> NCMediaViewerPageModel? {
        guard ocIds.indices.contains(index) else {
            return nil
        }

        let ocId = ocIds[index]

        if let cachedPage = cachedPagesByOcId[ocId] {
            return cachedPage
        }

        let page = NCMediaViewerPageModel(
            index: index,
            ocId: ocId,
            metadata: nil,
            state: .idle
        )

        cachedPagesByOcId[ocId] = page
        return page
    }

    /// Handles page display from the UIKit pager.
    ///
    /// - Parameter index: Absolute page index currently displayed.
    func displayPage(at index: Int) async {
        guard ocIds.indices.contains(index) else {
            return
        }

        selectedIndex = index

        await loadPageIfNeeded(index: index)
        prefetchNeighborPages(around: index)
    }

    /// Returns the page model for the currently selected index.
    func selectedPageModel() -> NCMediaViewerPageModel? {
        pageModel(at: selectedIndex)
    }

    /// Loads the initially selected page if needed.
    func loadSelectedPageIfNeeded() async {
        await loadPageIfNeeded(index: selectedIndex)
        prefetchNeighborPages(around: selectedIndex)
    }

    /// Loads a page if it is still idle.
    ///
    /// - Parameter index: Absolute page index inside the full `ocIds` array.
    func loadPageIfNeeded(index: Int) async {
        guard ocIds.indices.contains(index) else {
            return
        }

        let ocId = ocIds[index]

        guard pageState(for: ocId).isIdle else {
            return
        }

        guard loadingTasksByOcId[ocId] == nil else {
            return
        }

        let task = Task { [weak self] in
            guard let self else {
                return
            }

            await self.loadPage(index: index)
        }

        loadingTasksByOcId[ocId] = task
        await task.value
        loadingTasksByOcId[ocId] = nil
    }

    /// Reloads a failed or missing page.
    ///
    /// - Parameter index: Absolute page index inside the full `ocIds` array.
    func reloadPage(index: Int) async {
        guard ocIds.indices.contains(index) else {
            return
        }

        let ocId = ocIds[index]

        loadingTasksByOcId[ocId]?.cancel()
        loadingTasksByOcId[ocId] = nil

        updatePage(ocId: ocId) { page in
            page.state = .idle
        }

        await loadPageIfNeeded(index: index)
    }

    /// Cancels loading for a specific page.
    ///
    /// - Parameter index: Absolute page index inside the full `ocIds` array.
    func cancelLoading(index: Int) {
        guard ocIds.indices.contains(index) else {
            return
        }

        let ocId = ocIds[index]

        loadingTasksByOcId[ocId]?.cancel()
        loadingTasksByOcId[ocId] = nil
    }

    // MARK: - Selected Page Loading

    /// Loads metadata and media content for the selected page.
    ///
    /// Image pages use `.image(previewURL:localURL:progress:)` for both preview
    /// and full media availability.
    ///
    /// - Parameter index: Absolute page index inside the full `ocIds` array.
    private func loadPage(index: Int) async {
        guard ocIds.indices.contains(index) else {
            return
        }

        let ocId = ocIds[index]

        setState(.loadingMetadata, for: ocId)

        let metadata = await resolvedMetadata(for: ocId)

        guard !Task.isCancelled else {
            return
        }

        guard let metadata else {
            setState(.metadataMissing, for: ocId)
            return
        }

        setMetadata(metadata, for: ocId)

        let previewURL = await loader.previewURL(for: metadata)

        guard !Task.isCancelled else {
            return
        }

        if isImage(metadata) {
            setState(
                .image(
                    previewURL: previewURL,
                    localURL: nil,
                    progress: nil
                ),
                for: ocId
            )
        } else {
            setState(.checkingLocalFile, for: ocId)
        }

        if let localURL = await loader.localMediaURL(for: metadata) {
            guard !Task.isCancelled else {
                return
            }

            setReadyState(
                metadata: metadata,
                previewURL: previewURL,
                localURL: localURL,
                for: ocId
            )
            return
        }

        guard !Task.isCancelled else {
            return
        }

        do {
            if !isImage(metadata) {
                setState(.downloading(previewURL: previewURL, progress: nil), for: ocId)
            }

            let downloadedURL = try await loader.downloadMedia(for: metadata)

            guard !Task.isCancelled else {
                return
            }

            setReadyState(
                metadata: metadata,
                previewURL: previewURL,
                localURL: downloadedURL,
                for: ocId
            )
        } catch is CancellationError {
            return
        } catch {
            setState(
                .failed(
                    previewURL: previewURL,
                    message: error.localizedDescription
                ),
                for: ocId
            )
        }
    }

    // MARK: - Prefetch

    /// Prefetches neighbor pages around the selected index.
    ///
    /// Images are allowed to download the full file.
    /// Video and audio avoid automatic full download during prefetch.
    ///
    /// - Parameter index: Current selected absolute index.
    private func prefetchNeighborPages(around index: Int) {
        let neighborIndexes = [
            index - 1,
            index + 1
        ]

        for neighborIndex in neighborIndexes where ocIds.indices.contains(neighborIndex) {
            Task { [weak self] in
                guard let self else {
                    return
                }

                await self.prefetchPageIfNeeded(index: neighborIndex)
            }
        }
    }

    /// Prefetches one page if it is still idle.
    ///
    /// - Parameter index: Absolute page index inside the full `ocIds` array.
    private func prefetchPageIfNeeded(index: Int) async {
        guard ocIds.indices.contains(index) else {
            return
        }

        let ocId = ocIds[index]

        guard pageState(for: ocId).isIdle else {
            return
        }

        guard loadingTasksByOcId[ocId] == nil else {
            return
        }

        let task = Task { [weak self] in
            guard let self else {
                return
            }

            await self.loadPageForPrefetch(index: index)
        }

        loadingTasksByOcId[ocId] = task
        await task.value
        loadingTasksByOcId[ocId] = nil
    }

    /// Loads a page for neighbor prefetch.
    ///
    /// Prefetch must be silent as much as possible:
    /// - it should not publish intermediate loading states
    /// - it should update page state only when preview or full media is available
    ///
    /// For images, this can download the full file.
    /// For video/audio, this resolves metadata, preview and local availability only.
    ///
    /// - Parameter index: Absolute page index inside the full `ocIds` array.
    private func loadPageForPrefetch(index: Int) async {
        guard ocIds.indices.contains(index) else {
            return
        }

        let ocId = ocIds[index]

        let metadata = await resolvedMetadata(for: ocId)

        guard !Task.isCancelled else {
            return
        }

        guard let metadata else {
            setState(.metadataMissing, for: ocId)
            return
        }

        setMetadata(metadata, for: ocId)

        let previewURL = await loader.previewURL(for: metadata)

        guard !Task.isCancelled else {
            return
        }

        if let localURL = await loader.localMediaURL(for: metadata) {
            guard !Task.isCancelled else {
                return
            }

            setReadyState(
                metadata: metadata,
                previewURL: previewURL,
                localURL: localURL,
                for: ocId
            )
            return
        }

        guard !Task.isCancelled else {
            return
        }

        guard isImage(metadata) else {
            if previewURL != nil {
                setState(
                    .downloading(
                        previewURL: previewURL,
                        progress: nil
                    ),
                    for: ocId
                )
            }

            return
        }

        if previewURL != nil {
            setState(
                .image(
                    previewURL: previewURL,
                    localURL: nil,
                    progress: nil
                ),
                for: ocId
            )
        }

        do {
            let downloadedURL = try await loader.downloadMedia(for: metadata)

            guard !Task.isCancelled else {
                return
            }

            setState(
                .image(
                    previewURL: previewURL,
                    localURL: downloadedURL,
                    progress: nil
                ),
                for: ocId
            )
        } catch is CancellationError {
            return
        } catch {
            updatePage(ocId: ocId) { page in
                page.state = .idle
            }
        }
    }

    // MARK: - Page Updates

    /// Resolves detached metadata for an `ocId`.
    ///
    /// - Parameter ocId: Nextcloud file identifier.
    /// - Returns: Existing cached metadata or metadata loaded from the loader.
    private func resolvedMetadata(for ocId: String) async -> tableMetadata? {
        if let existingMetadata = cachedPagesByOcId[ocId]?.metadata {
            return existingMetadata
        }

        return await loader.metadata(for: ocId)
    }

    /// Returns the current state for an `ocId`.
    ///
    /// - Parameter ocId: Nextcloud file identifier.
    /// - Returns: Page state.
    private func pageState(for ocId: String) -> NCMediaViewerPageState {
        cachedPagesByOcId[ocId]?.state ?? .idle
    }

    /// Updates the metadata for a page.
    ///
    /// - Parameters:
    ///   - metadata: Detached metadata.
    ///   - ocId: Page file identifier.
    private func setMetadata(_ metadata: tableMetadata, for ocId: String) {
        updatePage(ocId: ocId) { page in
            page.metadata = metadata
        }
    }

    /// Updates the state for a page.
    ///
    /// - Parameters:
    ///   - state: New page state.
    ///   - ocId: Page file identifier.
    private func setState(_ state: NCMediaViewerPageState, for ocId: String) {
        updatePage(ocId: ocId) { page in
            page.state = state
        }
    }

    /// Sets the correct ready state for image and non-image media.
    ///
    /// - Parameters:
    ///   - metadata: Detached metadata.
    ///   - previewURL: Optional local preview URL.
    ///   - localURL: Local full media URL.
    ///   - ocId: Page file identifier.
    private func setReadyState(
        metadata: tableMetadata,
        previewURL: URL?,
        localURL: URL,
        for ocId: String
    ) {
        if isImage(metadata) {
            setState(
                .image(
                    previewURL: previewURL,
                    localURL: localURL,
                    progress: nil
                ),
                for: ocId
            )
        } else {
            setState(
                .ready(
                    localURL: localURL,
                    previewURL: previewURL
                ),
                for: ocId
            )
        }
    }

    /// Mutates a cached page and publishes a model revision.
    ///
    /// - Parameters:
    ///   - ocId: Page file identifier.
    ///   - mutation: Mutation applied to the page model.
    private func updatePage(
        ocId: String,
        mutation: (inout NCMediaViewerPageModel) -> Void
    ) {
        guard let index = ocIds.firstIndex(of: ocId) else {
            return
        }

        var page = cachedPagesByOcId[ocId] ?? NCMediaViewerPageModel(
            index: index,
            ocId: ocId,
            metadata: nil,
            state: .idle
        )

        mutation(&page)

        cachedPagesByOcId[ocId] = page
        revision &+= 1
    }

    /// Returns whether the metadata represents an image.
    ///
    /// - Parameter metadata: Detached metadata.
    /// - Returns: True when the media is an image.
    private func isImage(_ metadata: tableMetadata) -> Bool {
        metadata.classFile == NKTypeClassFile.image.rawValue
    }
}

// MARK: - NCMediaViewerPageState Helpers

private extension NCMediaViewerPageState {

    /// Returns true when the page has not started loading yet.
    var isIdle: Bool {
        switch self {
        case .idle:
            return true

        case .loadingMetadata,
             .metadataMissing,
             .checkingLocalFile,
             .image,
             .downloading,
             .ready,
             .failed:
            return false
        }
    }
}
