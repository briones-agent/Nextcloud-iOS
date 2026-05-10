// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import NextcloudKit

// MARK: - Video URL Resolution

/// Resolves the playable URL for a video item.
///
/// Resolution order:
/// - Explicit metadata URL.
/// - Local provider storage file.
/// - Nextcloud direct download URL.
struct NCVideoURLResolver {
    private let utilityFileSystem = NCUtilityFileSystem()

    /// Resolves the playable URL for a video metadata object.
    ///
    /// - Parameter metadata: Video metadata.
    /// - Returns: Resolved video URL, autoplay preference, and Nextcloud error.
    func getVideoURL(
        metadata: tableMetadata
    ) async -> (url: URL?, autoplay: Bool, error: NKError) {
        if !metadata.url.isEmpty {
            if metadata.url.hasPrefix("/") {
                return (
                    url: URL(fileURLWithPath: metadata.url),
                    autoplay: true,
                    error: .success
                )
            } else {
                return (
                    url: URL(string: metadata.url),
                    autoplay: true,
                    error: .success
                )
            }
        }

        if utilityFileSystem.fileProviderStorageExists(metadata) {
            let localPath = utilityFileSystem.getDirectoryProviderStorageOcId(
                metadata.ocId,
                fileName: metadata.fileNameView,
                userId: metadata.userId,
                urlBase: metadata.urlBase
            )

            return (
                url: URL(fileURLWithPath: localPath),
                autoplay: false,
                error: .success
            )
        }

        return await getDirectDownloadURL(metadata: metadata)
    }

    /// Resolves a direct download URL from Nextcloud.
    ///
    /// - Parameter metadata: Video metadata.
    /// - Returns: Direct download URL, autoplay preference, and Nextcloud error.
    private func getDirectDownloadURL(
        metadata: tableMetadata
    ) async -> (url: URL?, autoplay: Bool, error: NKError) {
        await withCheckedContinuation { continuation in
            NextcloudKit.shared.getDirectDownload(
                fileId: metadata.fileId,
                account: metadata.account
            ) { task in
                Task {
                    let identifier = await NCNetworking.shared.networkingTasks.createIdentifier(
                        account: metadata.account,
                        path: metadata.fileId,
                        name: "getDirectDownload"
                    )

                    await NCNetworking.shared.networkingTasks.track(
                        identifier: identifier,
                        task: task
                    )
                }
            } completion: { _, urlString, _, error in
                guard error == .success,
                      let urlString,
                      let url = URL(string: urlString) else {
                    continuation.resume(
                        returning: (
                            url: nil,
                            autoplay: false,
                            error: error
                        )
                    )
                    return
                }

                continuation.resume(
                    returning: (
                        url: url,
                        autoplay: false,
                        error: error
                    )
                )
            }
        }
    }
}
