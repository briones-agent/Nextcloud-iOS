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
    let topOverlayInset: CGFloat

    @State private var livePhoto: PHLivePhoto?
    @State private var failedMessage: String?
    @State private var isPlayingLivePhoto = false

    init(
        imageURL: URL?,
        videoURL: URL?,
        backgroundStyle: NCViewerBackgroundStyle = .system,
        topOverlayInset: CGFloat = 0
    ) {
        self.imageURL = imageURL
        self.videoURL = videoURL
        self.backgroundStyle = backgroundStyle
        self.topOverlayInset = topOverlayInset
    }

    var body: some View {
        ZStack {
            Color.ncViewerBackground(backgroundStyle)
                .ignoresSafeArea()

            stillImageView

            if isPlayingLivePhoto, let livePhoto {
                NCLivePhotoViewRepresentable(livePhoto: livePhoto, backgroundStyle: backgroundStyle,isPlaying: $isPlayingLivePhoto)
                    .ignoresSafeArea()
            }

            livePhotoBadge

            if let failedMessage {
                failedOverlay(failedMessage)
            }
        }
        .background(Color.ncViewerBackground(backgroundStyle))
        .task(id: taskIdentifier) {
            await loadLivePhotoIfNeeded()
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.25)
                .onEnded { _ in
                    guard livePhoto != nil else {
                        return
                    }

                    isPlayingLivePhoto = true
                }
        )
    }

    /// Badge shown below the navigation bar on the leading side.
    private var livePhotoBadge: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height
            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            let topInset = isLandscape && !isPad ? max(topOverlayInset, 76) : topOverlayInset

            VStack {
                HStack {
                    HStack(spacing: 5) {
                        Image(systemName: "livephoto")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.gray)

                        Text("LIVE")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.gray)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.72))
                    .overlay(
                        Capsule()
                            .stroke(.gray.opacity(0.22), lineWidth: 1)
                    )
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
                    .padding(.leading, 12)
                    .padding(.top, topInset)

                    Spacer()
                }

                Spacer()
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var stillImageView: some View {
        if let imageURL {
            NCImageViewerContentView(
                identifier: imageURL.absoluteString,
                previewURL: nil,
                fullURL: imageURL,
                backgroundStyle: backgroundStyle
            )
        } else {
            Color.ncViewerBackground(backgroundStyle)
                .ignoresSafeArea()
        }
    }

    private func failedOverlay(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "livephoto.slash")
                .font(.system(size: 24, weight: .regular))

            Text(message)
                .font(.caption)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(primaryForegroundStyle)
        .padding(12)
        .background(.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding()
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

        let resourceURLs = [imageURL, videoURL]
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
    /// This wrapper waits for the non-degraded Live Photo and resumes the continuation only once.
    ///
    /// - Parameter resourceURLs: Local resource URLs required to build the Live Photo.
    /// - Returns: A playable `PHLivePhoto` when the request succeeds, otherwise `nil`.
    @MainActor
    private func requestLivePhoto(resourceURLs: [URL]) async -> PHLivePhoto? {
        guard resourceURLs.count >= 2 else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            final class ResumeBox {
                private var didResume = false
                private let lock = NSLock()

                func resumeOnce(_ continuation: CheckedContinuation<PHLivePhoto?, Never>, returning livePhoto: PHLivePhoto?) {
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

            PHLivePhoto.request(withResourceFileURLs: resourceURLs, placeholderImage: nil, targetSize: .zero, contentMode: .aspectFit) { livePhoto, info in
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

                let isDegraded = (info[PHLivePhotoInfoIsDegradedKey] as? Bool) == true

                if isDegraded {
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
///
/// The wrapper installs a long-press gesture directly on `PHLivePhotoView`.
/// Playback starts when the gesture begins and stops when the gesture ends,
/// matching the native Live Photo interaction.
private struct NCLivePhotoViewRepresentable: UIViewRepresentable {
    let livePhoto: PHLivePhoto
    let backgroundStyle: NCViewerBackgroundStyle
    @Binding var isPlaying: Bool

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.backgroundColor = .ncViewerBackground(backgroundStyle)
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.livePhoto = livePhoto
        view.isMuted = false
        view.delegate = context.coordinator

        DispatchQueue.main.async {
            view.startPlayback(with: .full)
        }

        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        view.backgroundColor = .ncViewerBackground(backgroundStyle)

        if view.livePhoto !== livePhoto {
            view.livePhoto = livePhoto
        }

        view.delegate = context.coordinator
        context.coordinator.isPlaying = $isPlaying
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isPlaying: $isPlaying)
    }

    final class Coordinator: NSObject, PHLivePhotoViewDelegate {
        var isPlaying: Binding<Bool>

        init(isPlaying: Binding<Bool>) {
            self.isPlaying = isPlaying
        }

        func livePhotoView(_ livePhotoView: PHLivePhotoView, didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
            isPlaying.wrappedValue = false
        }
    }
}
