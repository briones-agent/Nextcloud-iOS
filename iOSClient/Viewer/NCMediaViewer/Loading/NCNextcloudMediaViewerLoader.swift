// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import NextcloudKit

// MARK: - Media Viewer Loader

/// Concrete media viewer loader for the Nextcloud app.
///
/// This object is responsible for:
/// - resolving detached metadata from `ocId`
/// - checking if the full media file exists locally
/// - returning a cached preview file URL without network access
/// - downloading and caching a preview file when explicitly requested
/// - downloading the full media file when needed
///
/// It must always return detached `tableMetadata` objects.
///
/// The loader is marked as `@unchecked Sendable` because it is used from Swift
/// concurrency tasks, while several app-level dependencies are legacy singleton
/// services. The loader itself does not keep mutable request state.
final class NCMediaViewerLoader: NCMediaViewerLoading, @unchecked Sendable {
    private let database = NCManageDatabase.shared
    private let global = NCGlobal.shared
    private let utilityFileSystem = NCUtilityFileSystem()
    private let fileManager = FileManager.default

    // MARK: - NCMediaViewerLoading

    /// Resolves detached metadata from an `ocId`.
    ///
    /// - Parameter ocId: Nextcloud file identifier.
    /// - Returns: Detached metadata if available.
    func metadata(for ocId: String) async -> tableMetadata? {
        await database.getMetadataFromOcIdAsync(ocId)
    }

    /// Returns the local full media URL if the file is already available.
    ///
    /// - Parameter metadata: Detached metadata for the media file.
    /// - Returns: Local full media URL if available and not empty.
    func localMediaURL(for metadata: tableMetadata) async -> URL? {
        guard let localURL = fullLocalURL(for: metadata) else {
            return nil
        }

        guard isValidLocalFile(path: localURL.path) else {
            return nil
        }

        return localURL
    }

    /// Returns a cached local preview URL if already available.
    ///
    /// This method only checks the local preview cache and never performs network
    /// requests.
    ///
    /// - Parameter metadata: Detached metadata for the media file.
    /// - Returns: Cached local preview URL if available.
    func cachedPreviewURL(for metadata: tableMetadata) async -> URL? {
        let localPath = previewLocalPath(for: metadata)

        guard isValidLocalFile(path: localPath) else {
            return nil
        }

        return URL(fileURLWithPath: localPath)
    }

    /// Downloads a preview and returns its local URL if available.
    ///
    /// This method can perform a network request and stores the preview using the
    /// existing app preview cache pipeline.
    ///
    /// - Parameter metadata: Detached metadata for the media file.
    /// - Returns: Local preview URL after download if available.
    func downloadPreviewURL(for metadata: tableMetadata) async -> URL? {
        if let cachedURL = await cachedPreviewURL(for: metadata) {
            return cachedURL
        }

        let resultsDownloadPreview = await NextcloudKit.shared.downloadPreviewAsync(
            fileId: metadata.fileId,
            etag: metadata.etag,
            account: metadata.account
        )

        if resultsDownloadPreview.error == .success,
           let data = resultsDownloadPreview.responseData?.data {
            NCUtility().createImageFileFrom(
                data: data,
                metadata: metadata
            )
        }

        return await cachedPreviewURL(for: metadata)
    }

    /// Downloads the full media file if needed.
    ///
    /// - Parameter metadata: Detached metadata for the media file.
    /// - Returns: Local full media URL after completion.
    func downloadMedia(for metadata: tableMetadata) async throws -> URL {
        if let localURL = await localMediaURL(for: metadata) {
            return localURL
        }

        print("⬇️ MEDIA VIEWER FULL DOWNLOAD:", metadata.fileNameView, metadata.ocId)

        let results = await NCNetworking.shared.downloadFile(metadata: metadata)

        if let afError = results.afError {
            throw afError
        }

        if results.nkError != .success {
            throw results.nkError
        }

        if let localURL = await localMediaURL(for: metadata) {
            return localURL
        }

        throw NCMediaViewerLoaderError.localFileUnavailable
    }

    // MARK: - Private Helpers

    /// Builds the expected full local file URL for a metadata object.
    ///
    /// - Parameter metadata: Detached metadata for the media file.
    /// - Returns: Expected local full media URL.
    private func fullLocalURL(for metadata: tableMetadata) -> URL? {
        let localPath = utilityFileSystem.getDirectoryProviderStorageOcId(
            metadata.ocId,
            fileName: metadata.fileNameView,
            userId: metadata.userId,
            urlBase: metadata.urlBase
        )

        guard !localPath.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: localPath)
    }

    /// Builds the expected local preview file path.
    ///
    /// - Parameter metadata: Detached metadata for the media file.
    /// - Returns: Local preview file path.
    private func previewLocalPath(for metadata: tableMetadata) -> String {
        utilityFileSystem.getDirectoryProviderStorageImageOcId(
            metadata.ocId,
            etag: metadata.etag,
            ext: global.previewExt1024,
            userId: metadata.userId,
            urlBase: metadata.urlBase
        )
    }

    /// Checks whether a local file exists and has a non-zero size.
    ///
    /// - Parameter path: Local file path.
    /// - Returns: True when the file exists and is not empty.
    private func isValidLocalFile(path: String) -> Bool {
        guard !path.isEmpty else {
            return false
        }

        guard fileManager.fileExists(atPath: path) else {
            return false
        }

        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let fileSize = attributes[.size] as? Int64,
              fileSize > 0 else {
            return false
        }

        return true
    }
}

// MARK: - Loader Error

/// Errors thrown by the media viewer loader.
enum NCMediaViewerLoaderError: LocalizedError {
    case localFileUnavailable

    var errorDescription: String? {
        switch self {
        case .localFileUnavailable:
            return "The local file is not available."
        }
    }
}

// MARK: - Media Viewer Loading

/// Defines the loading operations required by the media viewer.
///
/// The concrete implementation belongs to the app layer and can use:
/// - Realm
/// - FileManager
/// - NextcloudKit
/// - thumbnail cache
/// - preview download pipeline
/// - full media download pipeline
protocol NCMediaViewerLoading: Sendable {
    /// Resolves detached metadata from an `ocId`.
    ///
    /// - Parameter ocId: Nextcloud file identifier.
    /// - Returns: Detached metadata if available.
    func metadata(for ocId: String) async -> tableMetadata?

    /// Returns the local full media URL if the file is already available.
    ///
    /// - Parameter metadata: Detached metadata for the media file.
    /// - Returns: Local full media URL if available.
    func localMediaURL(for metadata: tableMetadata) async -> URL?

    /// Returns a cached local preview URL if already available.
    ///
    /// This method must not perform network requests.
    ///
    /// - Parameter metadata: Detached metadata for the media file.
    /// - Returns: Cached local preview URL if available.
    func cachedPreviewURL(for metadata: tableMetadata) async -> URL?

    /// Downloads a preview and returns its local URL if available.
    ///
    /// This method can perform network requests.
    ///
    /// - Parameter metadata: Detached metadata for the media file.
    /// - Returns: Local preview URL after download if available.
    func downloadPreviewURL(for metadata: tableMetadata) async -> URL?

    /// Downloads the full media file if needed.
    ///
    /// - Parameter metadata: Detached metadata for the media file.
    /// - Returns: Local full media URL after completion.
    func downloadMedia(for metadata: tableMetadata) async throws -> URL
}
