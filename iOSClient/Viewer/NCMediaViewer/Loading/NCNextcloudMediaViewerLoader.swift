// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import NextcloudKit

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

    /// Returns a local preview URL if available.
    ///
    /// For the first implementation this returns `nil`.
    /// Later this can point to your thumbnail/preview cache.
    ///
    /// - Parameter metadata: Detached metadata for the media file.
    /// - Returns: Local preview URL if available.
    func previewURL(for metadata: tableMetadata) async -> URL? {
        var localPath = utilityFileSystem.getDirectoryProviderStorageImageOcId(
            metadata.ocId,
            etag: metadata.etag,
            ext: global.previewExt1024,
            userId: metadata.userId,
            urlBase: metadata.urlBase
        )

        if isValidLocalFile(path: localPath) {
            return URL(fileURLWithPath: localPath)
        }

        let resultsDownloadPreview = await NextcloudKit.shared.downloadPreviewAsync(
            fileId: metadata.fileId,
            etag: metadata.etag,
            account: metadata.account
        )

        if resultsDownloadPreview.error == .success,
           let data = resultsDownloadPreview.responseData?.data {
            NCUtility().createImageFileFrom(data: data, metadata: metadata)
        }

        localPath = utilityFileSystem.getDirectoryProviderStorageImageOcId(
            metadata.ocId,
            etag: metadata.etag,
            ext: global.previewExt1024,
            userId: metadata.userId,
            urlBase: metadata.urlBase
        )

        guard isValidLocalFile(path: localPath) else {
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

// MARK: - Media Viewer Loading

/// Defines the loading operations required by the media viewer.
///
/// The concrete implementation belongs to the app layer and can use:
/// - Realm
/// - FileManager
/// - NextcloudKit
/// - thumbnail cache
/// - download pipeline
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

    /// Returns a local preview URL if available.
    ///
    /// This can be a cached thumbnail or preview image.
    ///
    /// - Parameter metadata: Detached metadata for the media file.
    /// - Returns: Local preview URL if available.
    func previewURL(for metadata: tableMetadata) async -> URL?

    /// Downloads the full media file if needed.
    ///
    /// - Parameter metadata: Detached metadata for the media file.
    /// - Returns: Local full media URL after completion.
    func downloadMedia(for metadata: tableMetadata) async throws -> URL
}

