// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit
import Photos
import PhotosUI

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

    /// Loads a `PHLivePhoto` from local image and video resources.
    private func loadLivePhotoIfNeeded() async {
        guard livePhoto == nil else {
            return
        }

        guard let imageURL,
              let videoURL else {
            failedMessage = "Missing Live Photo resources."
            return
        }

        guard FileManager.default.fileExists(atPath: imageURL.path),
              FileManager.default.fileExists(atPath: videoURL.path) else {
            failedMessage = "Live Photo resource files do not exist."
            return
        }

        let resourceURLs = [
            imageURL,
            videoURL
        ]

        let loadedLivePhoto = await requestLivePhoto(resourceURLs: resourceURLs)

        guard let loadedLivePhoto else {
            failedMessage = "PHLivePhoto could not load these resources."
            return
        }

        failedMessage = nil
        livePhoto = loadedLivePhoto
    }

    /// Requests a `PHLivePhoto` from local resource URLs.
    ///
    /// - Parameter resourceURLs: Local image and paired video URLs.
    /// - Returns: Loaded Live Photo if Photos can build it.
    private func requestLivePhoto(resourceURLs: [URL]) async -> PHLivePhoto? {
        await withCheckedContinuation { continuation in
            PHLivePhoto.request(
                withResourceFileURLs: resourceURLs,
                placeholderImage: nil,
                targetSize: .zero,
                contentMode: .aspectFit
            ) { livePhoto, info in
                if let cancelled = info[PHLivePhotoInfoCancelledKey] as? Bool,
                   cancelled {
                    continuation.resume(returning: nil)
                    return
                }

                if info[PHLivePhotoInfoErrorKey] != nil {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: livePhoto)
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

