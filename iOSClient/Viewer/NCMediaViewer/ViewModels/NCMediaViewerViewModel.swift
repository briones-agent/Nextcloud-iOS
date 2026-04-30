// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

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
/// - check local media availability
/// - request preview URLs
/// - start full media downloads through the loader
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

    /// Metadata of the initially opened media.
    private let currentMetadata: tableMetadata

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
        self.currentMetadata = initialModel.currentMetadata
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

    /// Handles selection changes from the view.
    ///
    /// - Parameter index: New selected absolute index.
    func selectIndex(_ index: Int) async {
        guard ocIds.indices.contains(index) else {
            return
        }

        guard selectedIndex != index else {
            await loadPageIfNeeded(index: index)
            return
        }

        selectedIndex = index
        rebuildVisiblePages()
        cancelTasksOutsideVisibleWindow()
        await loadPageIfNeeded(index: index)
    }

    /// Loads the currently selected page if needed.
    func loadSelectedPageIfNeeded() async {
        await loadPageIfNeeded(index: selectedIndex)
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

    /// Loads metadata and media content for a page.
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
        setState(.checkingLocalFile, for: ocId)

        // Load the preview first so the page can display something immediately
        // while the full media file is checked or downloaded.
        let previewURL = await loader.previewURL(for: metadata)

        guard !Task.isCancelled else {
            return
        }

        // Show the preview state before checking/downloading the full media.
        // If `previewURL` is nil, the UI will keep showing the loading/black state.
        setState(.remoteOnly(previewURL: previewURL), for: ocId)

        // Check whether the full media file is already available locally.
        if let localURL = await loader.localMediaURL(for: metadata) {
            guard !Task.isCancelled else {
                return
            }

            setState(.ready(localURL: localURL), for: ocId)
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

            setState(.ready(localURL: downloadedURL), for: ocId)
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

    /// Cancels loading tasks for pages outside the current visible window.
    private func cancelTasksOutsideVisibleWindow() {
        let visibleOcIds = Set(visiblePages.map(\.ocId))

        for (ocId, task) in loadingTasksByOcId where !visibleOcIds.contains(ocId) {
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
