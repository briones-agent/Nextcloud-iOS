// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit
import Photos
import PhotosUI
import NextcloudKit

// MARK: - Live Photo Viewer Content View

/// Displays a Live Photo using a paired image file and video file.
///
/// The view loads a `PHLivePhoto` from local resources and renders it through
/// `PHLivePhotoView`.
struct NCLivePhotoViewerContentView: View {
    let imageURL: URL?
    let videoURL: URL?
    let backgroundStyle: NCViewerBackgroundStyle

    @State private var livePhoto: PHLivePhoto?
    @State private var failedMessage: String?

    init(
        imageURL: URL?,
        videoURL: URL?,
        backgroundStyle: NCViewerBackgroundStyle = .system
    ) {
        self.imageURL = imageURL
        self.videoURL = videoURL
        self.backgroundStyle = backgroundStyle
    }

    var body: some View {
        ZStack {
            Color.ncViewerBackground(backgroundStyle)
                .ignoresSafeArea()

            if let livePhoto {
                NCLivePhotoViewRepresentable(
                    livePhoto: livePhoto,
                    backgroundStyle: backgroundStyle
                )
                .ignoresSafeArea()
            } else if let failedMessage {
                failedView(failedMessage)
            } else {
                ProgressView()
                    .tint(progressTintColor)
            }
        }
        .background(Color.ncViewerBackground(backgroundStyle))
        .task(id: taskIdentifier) {
            await loadLivePhotoIfNeeded()
        }
    }

    private var taskIdentifier: String {
        "\(imageURL?.absoluteString ?? "")-\(videoURL?.absoluteString ?? "")"
    }

    private var progressTintColor: Color {
        switch backgroundStyle {
        case .black:
            return .white
        case .system, .white, .custom:
            return .accentColor
        }
    }

    private var primaryForegroundStyle: Color {
        switch backgroundStyle {
        case .black:
            return .white
        case .system, .white, .custom:
            return .primary
        }
    }

    private var secondaryForegroundStyle: Color {
        switch backgroundStyle {
        case .black:
            return .white.opacity(0.65)
        case .system, .white, .custom:
            return .secondary
        }
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "livephoto.slash")
                .font(.system(size: 44, weight: .regular))

            Text("Live Photo load failed")
                .font(.headline)

            Text(message)
                .font(.caption)
                .foregroundStyle(secondaryForegroundStyle)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(primaryForegroundStyle)
        .padding(24)
    }

    /// Loads the Live Photo only when both still image and paired video resources are available.
    ///
    /// Missing resources are not treated as a visual failure because the viewer can
    /// still render the still image through the normal image pipeline.
    private func loadLivePhotoIfNeeded() async {
        guard livePhoto == nil else {
            return
        }

        failedMessage = nil

        guard let imageURL,
              let videoURL else {
            return
        }

        guard FileManager.default.fileExists(atPath: imageURL.path),
              FileManager.default.fileExists(atPath: videoURL.path) else {
            return
        }

        let resourceURLs = [
            imageURL,
            videoURL
        ]

        let loadedLivePhoto = await requestLivePhoto(resourceURLs: resourceURLs)

        guard !Task.isCancelled else {
            return
        }

        guard let loadedLivePhoto else {
            failedMessage = "PHLivePhoto could not load these resources."
            return
        }

        failedMessage = nil
        livePhoto = loadedLivePhoto
    }

    /// Requests a `PHLivePhoto` from the provided photo and video resource URLs.
    ///
    /// The Photos framework can invoke the result handler more than once.
    /// This wrapper guarantees that the Swift continuation is resumed only once.
    ///
    /// - Parameter resourceURLs: Local resource URLs required to build the Live Photo.
    /// - Returns: A `PHLivePhoto` when the request succeeds, otherwise `nil`.
    @MainActor
    private func requestLivePhoto(resourceURLs: [URL]) async -> PHLivePhoto? {
        guard resourceURLs.count >= 2 else {
            nkLog(tag: NCGlobal.shared.logTagViewer, emoji: .debug, message: "LIVE PHOTO failure: missing resources \(resourceURLs.count)", consoleOnly: true)
            return nil
        }

        return await withCheckedContinuation { continuation in
            final class ResumeBox {
                private var didResume = false
                private let lock = NSLock()

                func resumeOnce(
                    _ continuation: CheckedContinuation<PHLivePhoto?, Never>,
                    returning livePhoto: PHLivePhoto?
                ) {
                    lock.lock()
                    defer { lock.unlock() }

                    guard !didResume else {
                        return
                    }

                    didResume = true
                    continuation.resume(returning: livePhoto)
                }
            }

            let resumeBox = ResumeBox()

            PHLivePhoto.request(
                withResourceFileURLs: resourceURLs,
                placeholderImage: nil,
                targetSize: .zero,
                contentMode: .aspectFit
            ) { livePhoto, info in
                if let cancelled = info[PHLivePhotoInfoCancelledKey] as? Bool,
                   cancelled {
                    resumeBox.resumeOnce(
                        continuation,
                        returning: nil
                    )
                    return
                }

                if info[PHLivePhotoInfoErrorKey] != nil {
                    resumeBox.resumeOnce(
                        continuation,
                        returning: nil
                    )
                    return
                }

                guard let livePhoto else {
                    return
                }

                resumeBox.resumeOnce(
                    continuation,
                    returning: livePhoto
                )
            }
        }
    }
}

// MARK: - Live Photo View Representable

/// UIKit wrapper for `PHLivePhotoView`.
private struct NCLivePhotoViewRepresentable: UIViewRepresentable {
    let livePhoto: PHLivePhoto
    let backgroundStyle: NCViewerBackgroundStyle

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.backgroundColor = .ncViewerBackground(backgroundStyle)
        view.contentMode = .scaleAspectFit
        view.livePhoto = livePhoto
        view.isMuted = false
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        view.backgroundColor = .ncViewerBackground(backgroundStyle)

        if view.livePhoto !== livePhoto {
            view.livePhoto = livePhoto
        }
    }
}
