// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Media Viewer View Model

/// View model for the SwiftUI media viewer.
///
/// Responsibilities:
/// - owns the page list
/// - owns the selected page identifier
/// - resolves metadata lazily
/// - checks local file availability
/// - starts downloads through the loader
/// - updates page states
///
/// It does not render UI and does not directly access Realm, FileManager,
/// or networking APIs. Those responsibilities belong to `NCMediaViewerLoading`.
@MainActor
final class NCMediaViewerViewModel: ObservableObject {

    // MARK: - Published State

    /// Ordered page models rendered by the viewer.
    @Published private(set) var pages: [NCMediaViewerPageModel]

    /// Currently selected page `ocId`.
    @Published var selectedOcId: String

    // MARK: - Dependencies

    private let loader: NCMediaViewerLoading

    // MARK: - Running Tasks

    private var loadingTasksByOcId: [String: Task<Void, Never>] = [:]

    // MARK: - Init

    /// Creates a media viewer view model.
    ///
    /// - Parameters:
    ///   - initialModel: Initial viewer model containing current metadata and ordered ocIds.
    ///   - loader: Loader used to resolve metadata, local URLs, previews, and downloads.
    init(
        initialModel: NCMediaViewerInitialModel,
        loader: NCMediaViewerLoading
    ) {
        self.pages = initialModel.initialPages
        self.selectedOcId = initialModel.currentMetadata.ocId
        self.loader = loader
    }

    deinit {
        loadingTasksByOcId.values.forEach { $0.cancel() }
        loadingTasksByOcId.removeAll()
    }

    // MARK: - Public API

    /// Loads a page if it is still idle.
    ///
    /// - Parameter ocId: Page file identifier.
    /// Loads a page if it is still idle.
    ///
    /// - Parameter ocId: Page file identifier.
    func loadPageIfNeeded(ocId: String) async {
        guard let index = indexOfPage(ocId: ocId) else {
            return
        }

        guard pages[index].state.isIdle else {
            return
        }

        guard loadingTasksByOcId[ocId] == nil else {
            return
        }

        let task = Task { [weak self] in
            guard let self else {
                return
            }

            await self.loadPage(ocId: ocId)
        }

        loadingTasksByOcId[ocId] = task
        await task.value
        loadingTasksByOcId[ocId] = nil
    }

    /// Reloads a failed or missing page.
    ///
    /// - Parameter ocId: Page file identifier.
    func reloadPage(ocId: String) async {
        guard let index = indexOfPage(ocId: ocId) else {
            return
        }

        loadingTasksByOcId[ocId]?.cancel()
        loadingTasksByOcId[ocId] = nil

        pages[index].state = .idle
        await loadPageIfNeeded(ocId: ocId)
    }

    /// Cancels loading for a specific page.
    ///
    /// - Parameter ocId: Page file identifier.
    func cancelLoading(ocId: String) {
        loadingTasksByOcId[ocId]?.cancel()
        loadingTasksByOcId[ocId] = nil
    }

    // MARK: - Private Loading

    /// Loads metadata and media content for a page.
    ///
    /// - Parameter ocId: Page file identifier.
    private func loadPage(ocId: String) async {
        guard let index = indexOfPage(ocId: ocId) else {
            return
        }

        setState(.loadingMetadata, for: ocId)

        let metadata: tableMetadata?

        if let existingMetadata = pages[index].metadata {
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

        let previewURL = await loader.previewURL(for: metadata)

        guard !Task.isCancelled else {
            return
        }

        setState(.remoteOnly(previewURL: previewURL), for: ocId)

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

    // MARK: - State Mutation

    /// Updates the metadata for a page.
    ///
    /// - Parameters:
    ///   - metadata: Detached metadata.
    ///   - ocId: Page file identifier.
    private func setMetadata(_ metadata: tableMetadata, for ocId: String) {
        guard let index = indexOfPage(ocId: ocId) else {
            return
        }

        pages[index].metadata = metadata
    }

    /// Updates the state for a page.
    ///
    /// - Parameters:
    ///   - state: New page state.
    ///   - ocId: Page file identifier.
    private func setState(_ state: NCMediaViewerPageState, for ocId: String) {
        guard let index = indexOfPage(ocId: ocId) else {
            return
        }

        pages[index].state = state
    }

    /// Returns the page index for an `ocId`.
    ///
    /// - Parameter ocId: Page file identifier.
    /// - Returns: Page index if found.
    private func indexOfPage(ocId: String) -> Int? {
        pages.firstIndex { $0.ocId == ocId }
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
