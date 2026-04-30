// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

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
