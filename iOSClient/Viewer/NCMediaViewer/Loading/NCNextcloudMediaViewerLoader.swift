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
/// - returning or downloading a preview file
/// - downloading the full media file when needed
///
/// It must always return detached `tableMetadata` objects.
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

    /// Returns a local preview URL.
    ///
    /// This method first checks the local preview cache. If no preview exists,
    /// it downloads one from the server and stores it using the existing app
    /// preview cache pipeline.
    ///
    /// - Parameter metadata: Detached metadata for the media file.
    /// - Returns: Local preview URL if available.
    func previewURL(for metadata: tableMetadata, index: Int) async -> URL? {
        let localPath = previewLocalPath(for: metadata)

        if isValidLocalFile(path: localPath) {
            nkLog(tag: NCGlobal.shared.logTagViewer, emoji: .debug, message: "PREVIEW local \(index)", consoleOnly: true)
            return URL(fileURLWithPath: localPath)
        }

        nkLog(tag: NCGlobal.shared.logTagViewer, emoji: .debug, message: "PREVIEW request \(index)", consoleOnly: true)

        let result = await NextcloudKit.shared.downloadPreviewAsync(
            fileId: metadata.fileId,
            etag: metadata.etag,
            account: metadata.account
        )

        if result.error == .success,
           let data = result.responseData?.data {
            NCUtility().createImageFileFrom(
                data: data,
                metadata: metadata
            )
        }

        guard isValidLocalFile(path: localPath) else {
            nkLog(tag: NCGlobal.shared.logTagViewer, emoji: .debug, message: "PREVIEW failed \(index)", consoleOnly: true)
            return nil
        }

        nkLog(tag: NCGlobal.shared.logTagViewer, emoji: .debug, message: "PREVIEW ready \(index)", consoleOnly: true)

        return URL(fileURLWithPath: localPath)
    }

    /// Returns the local full media URL if the file is already available.
    ///
    /// This method never performs network requests.
    ///
    /// - Parameter metadata: Detached metadata for the media file.
    /// - Returns: Local full media URL if available.
    func localMediaURL(for metadata: tableMetadata, index: Int) async -> URL? {
        let localPath = fullLocalPath(for: metadata)

        guard isValidLocalFile(path: localPath) else {
            return nil
        }

        nkLog(tag: NCGlobal.shared.logTagViewer, emoji: .debug, message: "FULL local \(index)", consoleOnly: true)

        return URL(fileURLWithPath: localPath)
    }

    /// Downloads the full media file if needed.
    ///
    /// - Parameter metadata: Detached metadata for the media file.
    /// - Returns: Local full media URL after completion.
    func downloadMedia(for metadata: tableMetadata, index: Int) async throws -> URL {
        if let localURL = await localMediaURL(for: metadata, index: index) {
            nkLog(tag: NCGlobal.shared.logTagViewer, emoji: .debug, message: "FULL resolve \(index)", consoleOnly: true)
            return localURL
        }

        nkLog(tag: NCGlobal.shared.logTagViewer, emoji: .debug, message: "FULL network request \(index)", consoleOnly: true)

        let result = await NCNetworking.shared.downloadFile(metadata: metadata)

        if let afError = result.afError {
            nkLog(tag: NCGlobal.shared.logTagViewer, emoji: .debug, message: "FULL error \(index)", consoleOnly: true)
            throw afError
        }

        if result.nkError != .success {
            nkLog(tag: NCGlobal.shared.logTagViewer, emoji: .debug, message: "FULL error \(index)", consoleOnly: true)
            throw result.nkError
        }

        if let localURL = await localMediaURL(for: metadata, index: index) {
            nkLog(tag: NCGlobal.shared.logTagViewer, emoji: .debug, message: "FULL ready \(index)", consoleOnly: true)
            return localURL
        }

        nkLog(tag: NCGlobal.shared.logTagViewer, emoji: .debug, message: "FULL unavailable after download \(index)", consoleOnly: true)

        throw NCMediaViewerLoaderError.localFileUnavailable
    }

    // MARK: - Private Helpers

    /// Builds the expected full local file path.
    ///
    /// - Parameter metadata: Detached metadata for the media file.
    /// - Returns: Local full media file path.
    private func fullLocalPath(for metadata: tableMetadata) -> String {
        utilityFileSystem.getDirectoryProviderStorageOcId(
            metadata.ocId,
            fileName: metadata.fileNameView,
            userId: metadata.userId,
            urlBase: metadata.urlBase
        )
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
    func localMediaURL(for metadata: tableMetadata, index: Int) async -> URL?

    /// Returns a local preview URL.
    ///
    /// The implementation can return a cached preview or download one if needed.
    ///
    /// - Parameter metadata: Detached metadata for the media file.
    /// - Returns: Local preview URL if available.
    func previewURL(for metadata: tableMetadata, index: Int) async -> URL?

    /// Downloads the full media file if needed.
    ///
    /// - Parameter metadata: Detached metadata for the media file.
    /// - Returns: Local full media URL after completion.
    func downloadMedia(for metadata: tableMetadata, index: Int) async throws -> URL
}
