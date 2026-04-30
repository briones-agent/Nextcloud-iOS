// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Nextcloud Media Viewer Loader

/// Concrete media viewer loader for the Nextcloud app.
///
/// This object is responsible for:
/// - resolving metadata from `ocId`
/// - checking if the full media file exists locally
/// - returning an optional preview file URL
/// - downloading the full media file when needed
///
/// It must always return detached `tableMetadata` objects.
final class NCNextcloudMediaViewerLoader: NCMediaViewerLoading, @unchecked Sendable {

    // MARK: - Dependencies

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
    /// - Returns: Local full media URL if available.
    func localMediaURL(for metadata: tableMetadata) async -> URL? {
        guard let localURL = fullLocalURL(for: metadata) else {
            return nil
        }

        guard fileManager.fileExists(atPath: localURL.path) else {
            return nil
        }

        return localURL
    }

    /// Returns a local preview URL if available.
    ///
    /// For the first implementation this returns `nil`.
    /// Later this can point to your thumbnail/preview cache.
    ///
    /// - Parameter metadata: Detached metadata for the media file.
    /// - Returns: Local preview URL if available.
    func previewURL(for metadata: tableMetadata) async -> URL? {
        let localPath = utilityFileSystem.getDirectoryProviderStorageImageOcId(metadata.ocId,
                                                                               etag: metadata.etag,
                                                                               ext: global.previewExt1024,
                                                                               userId: metadata.userId,
                                                                               urlBase: metadata.urlBase)

        guard !localPath.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: localPath)
    }

    /// Downloads the full media file if needed.
    ///
    /// - Parameter metadata: Detached metadata for the media file.
    /// - Returns: Local full media URL after completion.
    func downloadMedia(for metadata: tableMetadata) async throws -> URL {
        if let localURL = await localMediaURL(for: metadata) {
            return localURL
        }

        // Replace this with the real Nextcloud download pipeline.
        //
        // Expected behavior:
        // 1. Start or attach to the download for `metadata`.
        // 2. Wait until the full media file exists locally.
        // 3. Return the final local file URL.
        //
        // This method intentionally throws for now so the integration point is explicit.
        throw NCMediaViewerLoaderError.downloadNotImplemented
    }

    // MARK: - Private

    /// Builds the expected full local file URL for a metadata object.
    ///
    /// This is a placeholder implementation.
    /// Replace it with the same path logic already used by the app.
    ///
    /// - Parameter metadata: Detached metadata for the media file.
    /// - Returns: Expected local full media URL.
    private func fullLocalURL(for metadata: tableMetadata) -> URL? {
        let localPath = utilityFileSystem.getDirectoryProviderStorageOcId(metadata.ocId, fileName: metadata.fileNameView, userId: metadata.userId, urlBase: metadata.urlBase)

        guard !localPath.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: localPath)
    }
}

// MARK: - Loader Error

/// Errors thrown by the media viewer loader.
enum NCMediaViewerLoaderError: LocalizedError {

    case downloadNotImplemented
    case localFileUnavailable

    var errorDescription: String? {
        switch self {
        case .downloadNotImplemented:
            return "Download is not implemented yet."

        case .localFileUnavailable:
            return "The local file is not available."
        }
    }
}
