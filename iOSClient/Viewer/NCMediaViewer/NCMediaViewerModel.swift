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
/// The viewer must not create one page for every `ocId` when the source list is large.
/// The model creates only a small visible window around the selected index.
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

/// Model for the SwiftUI media viewer.
///
/// This model is optimized for very large media lists.
/// It stores the full ordered `ocIds` array, but exposes only a small visible page
/// window around the selected index.
///
/// Responsibilities:
/// - keep the current selected index
/// - expose the visible page window
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

    /// Pages currently rendered by SwiftUI.
    ///
    /// This array must stay small, usually 3 or 5 items.
    @Published private(set) var visiblePages: [NCMediaViewerPageModel]

    /// Currently selected absolute index inside the full `ocIds` array.
    @Published var selectedIndex: Int

    // MARK: - Dependencies

    private let loader: NCMediaViewerLoading

    // MARK: - Source Data

    /// Full ordered media identifier list.
    private let ocIds: [String]

    /// Number of pages kept before and after the selected page.
    private let windowRadius: Int

    // MARK: - Page Cache

    /// Small state cache keyed by `ocId`.
    ///
    /// This allows the viewer to preserve state when a page temporarily leaves
    /// the visible window and later comes back.
    private var cachedPagesByOcId: [String: NCMediaViewerPageModel] = [:]

    // MARK: - Running Tasks

    /// Running page loading tasks keyed by `ocId`.
    private var loadingTasksByOcId: [String: Task<Void, Never>] = [:]

    // MARK: - Init

    /// Creates a media viewer model.
    ///
    /// - Parameters:
    ///   - initialModel: Initial viewer model containing current metadata and ordered ocIds.
    ///   - loader: Loader used to resolve metadata, local URLs, previews, and downloads.
    ///   - windowRadius: Number of pages kept before and after the selected page.
    init(
        initialModel: NCMediaViewerInitialModel,
        loader: NCMediaViewerLoading,
        windowRadius: Int = 2
    ) {
        self.loader = loader
        self.ocIds = initialModel.normalizedOcIds
        self.selectedIndex = initialModel.initialSelectedIndex
        self.windowRadius = max(1, windowRadius)
        self.visiblePages = []

        let currentPage = NCMediaViewerPageModel(
            index: initialModel.initialSelectedIndex,
            ocId: initialModel.currentMetadata.ocId,
            metadata: initialModel.currentMetadata,
            state: .idle
        )

        self.cachedPagesByOcId[initialModel.currentMetadata.ocId] = currentPage

        self.visiblePages = Self.makeVisiblePages(
            selectedIndex: initialModel.initialSelectedIndex,
            ocIds: initialModel.normalizedOcIds,
            windowRadius: max(1, windowRadius),
            cachedPagesByOcId: self.cachedPagesByOcId
        )
    }

    /// Creates a media viewer model from the current metadata and ordered media identifiers.
    ///
    /// - Parameters:
    ///   - currentMetadata: Detached metadata of the initially opened media.
    ///   - ocIds: Ordered list of image/audio/video ocIds.
    ///   - loader: Loader used to resolve metadata, local URLs, previews, and downloads.
    ///   - windowRadius: Number of pages kept before and after the selected page.
    convenience init(
        currentMetadata: tableMetadata,
        ocIds: [String],
        loader: NCMediaViewerLoading,
        windowRadius: Int = 2
    ) {
        let initialModel = NCMediaViewerInitialModel(
            currentMetadata: currentMetadata,
            ocIds: ocIds
        )

        self.init(
            initialModel: initialModel,
            loader: loader,
            windowRadius: windowRadius
        )
    }

    deinit {
        loadingTasksByOcId.values.forEach { $0.cancel() }
        loadingTasksByOcId.removeAll()
    }

    // MARK: - Public API

    /// Handles selection changes from code.
    ///
    /// Use this when selection has not already been applied by SwiftUI.
    ///
    /// - Parameter index: New selected absolute index.
    func selectIndex(_ index: Int) async {
        guard ocIds.indices.contains(index) else {
            return
        }

        guard selectedIndex != index else {
            await loadPageIfNeeded(index: index)
            prefetchNeighborPages(around: index)
            return
        }

        selectedIndex = index

        await loadPageIfNeeded(index: index)
        prefetchNeighborPages(around: index)
    }

    /// Handles a selection change already applied by the SwiftUI TabView binding.
    ///
    /// This method must not force a new selection because `selectedIndex` has
    /// already been updated by the `TabView`.
    ///
    /// - Parameter index: New selected absolute index.
    func handleSelectedIndexChanged(_ index: Int) async {
        guard ocIds.indices.contains(index) else {
            return
        }

        await loadPageIfNeeded(index: index)
        prefetchNeighborPages(around: index)
    }

    /// Loads the currently selected page if needed.
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

    // MARK: - Private Loading

    /// Loads metadata and media content for the selected page.
    ///
    /// Image pages keep a stable `.image` state so the same image view can move
    /// from preview to full image without being replaced by another SwiftUI branch.
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

            return
        }

        guard !Task.isCancelled else {
            return
        }

        do {
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
                setState(.downloading(previewURL: previewURL, progress: nil), for: ocId)
            }

            let downloadedURL = try await loader.downloadMedia(for: metadata)

            guard !Task.isCancelled else {
                return
            }

            if isImage(metadata) {
                setState(
                    .image(
                        previewURL: previewURL,
                        localURL: downloadedURL,
                        progress: nil
                    ),
                    for: ocId
                )
            } else {
                setState(
                    .ready(
                        localURL: downloadedURL,
                        previewURL: previewURL
                    ),
                    for: ocId
                )
            }
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

    /// Prefetches neighbor pages around the selected index.
    ///
    /// This reduces visible loading while swiping horizontally.
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
    /// - it should not show empty image states
    /// - it should update the visible page only when preview or full media is available
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

            return
        }

        guard !Task.isCancelled else {
            return
        }

        if isImage(metadata) {
            // Publish preview only if it actually exists.
            // This avoids showing an empty loading/black transition during prefetch.
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
                // Do not show a failed state for silent prefetch.
                // The page will try again when it becomes selected.
                updatePage(ocId: ocId) { page in
                    page.state = .idle
                }
            }

            return
        }

        // For video/audio, do not download the full file during prefetch.
        // If a preview exists, keep the page in a lightweight downloadable state.
        if previewURL != nil {
            setState(
                .downloading(
                    previewURL: previewURL,
                    progress: nil
                ),
                for: ocId
            )
        }
    }

    // MARK: - Window Management

    /// Rebuilds the visible page window around the selected index.
    private func rebuildVisiblePages() {
        visiblePages = Self.makeVisiblePages(
            selectedIndex: selectedIndex,
            ocIds: ocIds,
            windowRadius: windowRadius,
            cachedPagesByOcId: cachedPagesByOcId
        )
    }

    /// Rebuilds the visible page window only when the selected index reaches the edge.
    ///
    /// This avoids rebuilding the TabView page array on every single swipe.
    ///
    /// - Parameter index: Selected absolute index.
    private func rebuildVisiblePagesIfNeeded(for index: Int) {
        guard !visiblePages.isEmpty else {
            rebuildVisiblePages()
            return
        }

        guard let firstIndex = visiblePages.first?.index,
              let lastIndex = visiblePages.last?.index else {
            rebuildVisiblePages()
            return
        }

        guard index <= firstIndex || index >= lastIndex else {
            return
        }

        rebuildVisiblePages()
    }

    /// Builds the visible page window.
    ///
    /// - Parameters:
    ///   - selectedIndex: Current selected absolute index.
    ///   - ocIds: Full ordered media identifier list.
    ///   - windowRadius: Number of pages before and after the selected page.
    ///   - cachedPagesByOcId: Previously cached page models.
    /// - Returns: Visible page models.
    private static func makeVisiblePages(
        selectedIndex: Int,
        ocIds: [String],
        windowRadius: Int,
        cachedPagesByOcId: [String: NCMediaViewerPageModel]
    ) -> [NCMediaViewerPageModel] {
        guard !ocIds.isEmpty else {
            return []
        }

        guard ocIds.indices.contains(selectedIndex) else {
            return []
        }

        let lowerBound = max(0, selectedIndex - windowRadius)
        let upperBound = min(ocIds.count - 1, selectedIndex + windowRadius)

        return (lowerBound...upperBound).map { index in
            let ocId = ocIds[index]

            if let cachedPage = cachedPagesByOcId[ocId] {
                return cachedPage
            }

            return NCMediaViewerPageModel(
                index: index,
                ocId: ocId,
                metadata: nil,
                state: .idle
            )
        }
    }

    /// Cancels loading tasks for pages outside the current visible/prefetch window.
    private func cancelTasksOutsideVisibleWindow() {
        var allowedOcIds = Set(visiblePages.map(\.ocId))

        let neighborIndexes = [
            selectedIndex - 1,
            selectedIndex + 1
        ]

        for index in neighborIndexes where ocIds.indices.contains(index) {
            allowedOcIds.insert(ocIds[index])
        }

        for (ocId, task) in loadingTasksByOcId where !allowedOcIds.contains(ocId) {
            task.cancel()
            loadingTasksByOcId[ocId] = nil
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

    /// Mutates a cached page and refreshes the visible page if needed.
    ///
    /// This method updates only the affected visible page instead of rebuilding
    /// the whole visible window.
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

        guard let visibleIndex = visiblePages.firstIndex(where: { $0.ocId == ocId }) else {
            return
        }

        visiblePages[visibleIndex] = page
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
