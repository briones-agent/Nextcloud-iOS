// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import NextcloudKit

// MARK: - Video Viewer Content View

/// Displays a video using the shared video playback controller.
///
/// This view does not own the AVPlayer directly.
/// VLC playback is rendered through `NCVideoVLCViewerContentView`, which returns
/// a stable UIKit controller owned by `NCVideoVLCStablePlayer`.
///
/// Loading rules:
/// - If the same video is already loaded, the existing player is reused.
/// - If the page is not selected, the view does not load a new video.
/// - AVFoundation is paused/resumed when page selection changes.
/// - VLC is paused/resumed when page selection changes.
/// - Real global stop events are handled through `.ncMediaViewerStopPlayback`.
struct NCVideoViewerContentView: View {
    let metadata: tableMetadata
    let localURL: URL?
    let previewURL: URL?
    let userAgent: String?
    let isSelected: Bool

    @StateObject private var playback = NCVideoPlaybackController.shared

    @State private var errorMessage: String?
    @State private var playerOpacity: Double = 0

    private let resolver = NCVideoURLResolver()

    init(
        metadata: tableMetadata,
        localURL: URL?,
        previewURL: URL? = nil,
        userAgent: String? = nil,
        isSelected: Bool = true
    ) {
        self.metadata = metadata
        self.localURL = localURL
        self.previewURL = previewURL
        self.userAgent = userAgent
        self.isSelected = isSelected
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            previewPlaceholderView

            if let errorMessage {
                failedView(errorMessage)
            } else {
                switch playback.engine {
                case .loading:
                    EmptyView()

                case .avFoundation(let player):
                    NCVideoAVPlayerContentView(
                        player: player,
                        allowsPictureInPicture: true,
                        shouldAutoPlay: isSelected
                    )
                    .padding(.bottom, videoPlayerBottomPadding)
                    .ignoresSafeArea(edges: [.top, .leading, .trailing])
                    .opacity(playerOpacity)
                    .onAppear {
                        fadeInPlayer()
                    }

                case .vlc(let url):
                    NCVideoVLCViewerContentView(
                        metadata: metadata,
                        url: url,
                        userAgent: userAgent,
                        shouldAutoPlay: isSelected
                    )
                    .ignoresSafeArea()
                    .opacity(playerOpacity)
                    .onAppear {
                        fadeInPlayer()
                        startVLCIfSelected(url: url)
                    }
                    .onChange(of: url) { _, newURL in
                        fadeInPlayer()
                        startVLCIfSelected(url: newURL)
                    }
                    .onChange(of: isSelected) { _, selected in
                        if selected {
                            fadeInPlayer()
                            startVLCIfSelected(url: url)
                        }
                    }

                case .failed(let message):
                    failedView(message)
                }
            }
        }
        .background(Color.black)
        .task(id: taskIdentifier) {
            let expectedTaskIdentifier = taskIdentifier

            playerOpacity = 0
            errorMessage = nil

            if playback.isCurrentVideo(
                ocId: metadata.ocId,
                etag: metadata.etag
            ) {
                guard isSelected else {
                    return
                }

                resumeCurrentPlaybackIfNeeded()
                fadeInPlayer()
                return
            }

            guard isSelected else {
                return
            }

            await resolveAndLoadVideo(
                expectedTaskIdentifier: expectedTaskIdentifier
            )
        }
        .onChange(of: isSelected) { _, selected in
            handleSelectionChange(selected)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ncMediaViewerStopPlayback)) { _ in
            playerOpacity = 0
            playback.stop()
            NCVideoVLCStablePlayer.shared.stop()
        }
        .onDisappear {
            // Do not stop here.
            // SwiftUI can call onDisappear during rotation or layout rebuilds.
            playerOpacity = 0
        }
    }

    // MARK: - Views

    @ViewBuilder
    private var previewPlaceholderView: some View {
        if let previewURL {
            NCImageViewerContentView(
                identifier: metadata.ocId,
                previewURL: previewURL,
                fullURL: nil,
                backgroundStyle: .black
            )
        } else {
            Color.black
                .ignoresSafeArea()
        }
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash")
                .font(.system(size: 44, weight: .regular))

            Text("Video not available")
                .font(.headline)

            Text(message)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .foregroundStyle(.white)
        .padding(24)
    }

    // MARK: - Loading

    private var taskIdentifier: String {
        "\(metadata.ocId)|\(metadata.etag)|\(isSelected)"
    }

    /// Resolves the playable video URL and loads it into the shared playback controller.
    ///
    /// - Parameter expectedTaskIdentifier: Task identity captured before starting async resolution.
    @MainActor
    private func resolveAndLoadVideo(
        expectedTaskIdentifier: String
    ) async {
        errorMessage = nil

        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: .debug,
            message: "VIDEO resolve start ocId \(metadata.ocId), fileName \(metadata.fileNameView), fileId \(metadata.fileId)",
            consoleOnly: true
        )

        let result = await resolver.getVideoURL(metadata: metadata)

        guard !Task.isCancelled else {
            nkLog(
                tag: NCGlobal.shared.logTagViewer,
                emoji: .debug,
                message: "VIDEO resolve cancelled ocId \(metadata.ocId)",
                consoleOnly: true
            )
            return
        }

        guard expectedTaskIdentifier == taskIdentifier else {
            nkLog(
                tag: NCGlobal.shared.logTagViewer,
                emoji: .debug,
                message: "VIDEO resolve ignored stale task ocId \(metadata.ocId)",
                consoleOnly: true
            )
            return
        }

        guard isSelected else {
            return
        }

        guard result.error == .success,
              let url = result.url else {
            nkLog(
                tag: NCGlobal.shared.logTagViewer,
                emoji: .error,
                message: "VIDEO resolve failed ocId \(metadata.ocId), error \(result.error.errorDescription)",
                consoleOnly: true
            )

            errorMessage = result.error.errorDescription
            return
        }

        guard expectedTaskIdentifier == taskIdentifier else {
            nkLog(
                tag: NCGlobal.shared.logTagViewer,
                emoji: .debug,
                message: "VIDEO load ignored stale task ocId \(metadata.ocId), url \(url.absoluteString)",
                consoleOnly: true
            )
            return
        }

        guard isSelected else {
            return
        }

        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: .debug,
            message: "VIDEO resolve done url \(url.absoluteString), isFileURL \(url.isFileURL), fileName \(resolvedFileName)",
            consoleOnly: true
        )

        playback.loadVideo(
            metadata: metadata,
            url: url,
            fileName: resolvedFileName,
            userAgent: userAgent,
            httpHeaders: httpHeaders(for: url),
            shouldAutoPlay: result.autoplay || isSelected
        )
    }

    /// Returns HTTP headers for remote video playback.
    ///
    /// Local file URLs do not need HTTP headers.
    ///
    /// - Parameter url: Resolved video URL.
    /// - Returns: HTTP headers for AVFoundation remote playback.
    private func httpHeaders(for url: URL) -> [String: String] {
        guard !url.isFileURL else {
            return [:]
        }

        guard let userAgent,
              !userAgent.isEmpty else {
            return [:]
        }

        return [
            "User-Agent": userAgent
        ]
    }

    // MARK: - Playback Selection

    /// Handles page selection changes for AVFoundation and VLC.
    ///
    /// Page changes should pause playback, not release media.
    /// The full media viewer close event is responsible for releasing resources.
    ///
    /// - Parameter selected: Whether this page is currently selected.
    @MainActor
    private func handleSelectionChange(_ selected: Bool) {
        switch playback.engine {
        case .avFoundation(let player):
            if selected {
                if player.timeControlStatus != .playing {
                    player.play()
                }
            } else {
                player.pause()
            }

        case .vlc:
            if selected {
                resumeCurrentPlaybackIfNeeded()
            } else {
                NCVideoVLCStablePlayer.shared.pause()
            }

        case .loading,
             .failed:
            break
        }
    }

    /// Resumes the already selected current playback engine.
    ///
    /// AVFoundation resumes the existing player.
    /// VLC reconfigures the stable UIKit controller and resumes the existing media
    /// if it was only paused during page scrolling.
    @MainActor
    private func resumeCurrentPlaybackIfNeeded() {
        switch playback.engine {
        case .avFoundation(let player):
            if player.timeControlStatus != .playing {
                player.play()
            }

        case .vlc(let url):
            startVLCIfSelected(url: url)

        case .loading,
             .failed:
            break
        }
    }

    // MARK: - Helpers

    /// Starts or resumes VLC only when this page is selected.
    ///
    /// This is intentionally controlled here instead of inside the VLC bridge,
    /// because `UIViewControllerRepresentable.updateUIViewController` can be called
    /// during swipe, prefetch, rotation, and layout rebuilds.
    @MainActor
    private func startVLCIfSelected(url: URL) {
        guard isSelected else {
            return
        }

        NCVideoVLCStablePlayer.shared.configure(
            metadata: metadata,
            url: url,
            userAgent: userAgent,
            shouldAutoPlay: true
        )
    }

    /// Fades the active video player over the preview placeholder.
    @MainActor
    private func fadeInPlayer() {
        playerOpacity = 0

        withAnimation(.easeInOut(duration: 0.30)) {
            playerOpacity = 1
        }
    }

    /// Extra bottom padding used only for the native AVPlayer controller.
    ///
    /// This keeps the native playback scrubber away from the bottom edge / home indicator
    /// without changing image, Live Photo, audio, or VLC layout.
    private var videoPlayerBottomPadding: CGFloat {
        let windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }

        let window = windowScene?.windows.first { $0.isKeyWindow }
        let safeBottom = window?.safeAreaInsets.bottom ?? 0

        return max(safeBottom, 16)
    }

    private var resolvedFileName: String {
        if !metadata.fileNameView.isEmpty {
            return metadata.fileNameView
        }

        return metadata.fileName
    }
}

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
                autoplay: true,
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
