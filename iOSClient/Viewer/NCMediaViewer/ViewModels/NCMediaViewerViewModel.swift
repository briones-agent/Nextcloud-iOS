// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import NextcloudKit

// MARK: - Media Viewer View Model

/// View model for the SwiftUI media viewer.
///
/// This ViewModel is optimized for very large media lists.
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
final class NCMediaViewerViewModel: ObservableObject {

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

    /// Creates a media viewer view model.
    ///
    /// - Parameters:
    ///   - initialModel: Initial viewer model containing current metadata and ordered ocIds.
    ///   - loader: Loader used to resolve metadata, local URLs, previews, and downloads.
    ///   - windowRadius: Number of pages kept before and after the selected page.
    init(
        initialModel: NCMediaViewerInitialModel,
        loader: NCMediaViewerLoading,
        windowRadius: Int = 1
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
        rebuildVisiblePages()
        cancelTasksOutsideVisibleWindow()

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

        rebuildVisiblePages()
        cancelTasksOutsideVisibleWindow()

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
    /// The page always requests preview first, then checks or downloads the full media.
    ///
    /// - Parameter index: Absolute page index inside the full `ocIds` array.
    private func loadPage(index: Int) async {
        guard ocIds.indices.contains(index) else {
            return
        }

        let ocId = ocIds[index]

        setState(.loadingMetadata, for: ocId)

        let existingMetadata = cachedPagesByOcId[ocId]?.metadata
        let metadata: tableMetadata?

        if let existingMetadata {
            metadata = existingMetadata
        } else {
            metadata = await loader.metadata(for: ocId)
        }

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

        setState(.remoteOnly(previewURL: previewURL), for: ocId)

        if let localURL = await loader.localMediaURL(for: metadata) {
            guard !Task.isCancelled else {
                return
            }

            setState(
                .ready(
                    localURL: localURL,
                    previewURL: previewURL
                ),
                for: ocId
            )
            return
        }

        guard !Task.isCancelled else {
            return
        }

        do {
            setState(.downloading(previewURL: previewURL, progress: nil), for: ocId)

            let downloadedURL = try await loader.downloadMedia(for: metadata)

            guard !Task.isCancelled else {
                return
            }

            setState(
                .ready(
                    localURL: downloadedURL,
                    previewURL: previewURL
                ),
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
    /// For images, this can download the full file.
    /// For video/audio, this resolves metadata, preview and local availability only,
    /// avoiding automatic large downloads while swiping horizontally.
    ///
    /// - Parameter index: Absolute page index inside the full `ocIds` array.
    private func loadPageForPrefetch(index: Int) async {
        guard ocIds.indices.contains(index) else {
            return
        }

        let ocId = ocIds[index]

        setState(.loadingMetadata, for: ocId)

        let existingMetadata = cachedPagesByOcId[ocId]?.metadata
        let metadata: tableMetadata?

        if let existingMetadata {
            metadata = existingMetadata
        } else {
            metadata = await loader.metadata(for: ocId)
        }

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

        setState(.remoteOnly(previewURL: previewURL), for: ocId)

        if let localURL = await loader.localMediaURL(for: metadata) {
            guard !Task.isCancelled else {
                return
            }

            setState(
                .ready(
                    localURL: localURL,
                    previewURL: previewURL
                ),
                for: ocId
            )
            return
        }

        guard !Task.isCancelled else {
            return
        }

        guard isImage(metadata) else {
            return
        }

        do {
            setState(.downloading(previewURL: previewURL, progress: nil), for: ocId)

            let downloadedURL = try await loader.downloadMedia(for: metadata)

            guard !Task.isCancelled else {
                return
            }

            setState(
                .ready(
                    localURL: downloadedURL,
                    previewURL: previewURL
                ),
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

    /// Mutates a cached page and refreshes the visible window if needed.
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
        rebuildVisiblePages()
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
             .remoteOnly,
             .downloading,
             .ready,
             .failed:
            return false
        }
    }
}
