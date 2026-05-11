// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Foundation
import NextcloudKit

// MARK: - Video Playback Engine

/// Describes the currently rendered video playback engine.
///
/// The engine is owned by `NCVideoPlaybackController`.
/// Views only render the selected engine; they do not own playback resources.
enum NCVideoPlaybackEngine {
    /// No playable engine is currently ready.
    case loading

    /// Native AVFoundation playback using the shared controller-owned `AVPlayer`.
    case avFoundation(player: AVPlayer)

    /// VLC fallback playback using the shared VLC playback controller.
    case vlc(controller: NCVideoVLCPlayerController)

    /// Playback could not be prepared.
    case failed(message: String)
}

// MARK: - Video Playback Controller

/// Singleton video playback controller used by the SwiftUI media viewer.
///
/// This controller is the only owner of video playback resources:
/// - one AVFoundation player at a time
/// - one VLC player controller at a time
///
/// SwiftUI views can be recreated during rotation, paging, or layout rebuilds.
/// Playback must therefore not be owned by individual views.
@MainActor
final class NCVideoPlaybackController: ObservableObject {
    static let shared = NCVideoPlaybackController()

    // MARK: - Published State

    @Published private(set) var engine: NCVideoPlaybackEngine = .loading

    // MARK: - Private State

    private var avPlayer: AVPlayer?
    private var avPlayerItem: AVPlayerItem?
    private var statusObservation: NSKeyValueObservation?
    private var timeoutTask: Task<Void, Never>?

    let vlcController = NCVideoVLCPlayerController.shared

    private var currentOcId: String?
    private var currentEtag: String?
    private var currentURL: URL?
    private var currentFileName: String?
    private var loadToken = UUID()

    private let fallbackTimeoutMilliseconds = 1_500

    private init() { }

    // MARK: - Public API

    /// Returns whether the requested metadata is already owned by this controller.
    ///
    /// This check is used by views to avoid resolving/reloading the same media during
    /// rotation or SwiftUI rebuilds.
    ///
    /// - Parameters:
    ///   - ocId: Nextcloud file identifier.
    ///   - etag: Metadata ETag.
    /// - Returns: True when the current loaded media matches the supplied identity.
    func isCurrentVideo(
        ocId: String,
        etag: String
    ) -> Bool {
        currentOcId == ocId && currentEtag == etag && currentURL != nil
    }

    /// Loads a video URL if it is not already loaded.
    ///
    /// Calling this method again for the same `ocId`, `etag`, and URL is idempotent.
    /// It does not stop, recreate, or restart the existing player.
    ///
    /// - Parameters:
    ///   - metadata: Video metadata used as playback identity.
    ///   - url: Local or remote playable URL.
    ///   - fileName: Original metadata file name used to detect legacy formats.
    ///   - userAgent: Optional User-Agent used by VLC for remote playback.
    ///   - httpHeaders: Optional HTTP headers used by AVFoundation for remote playback.
    ///   - shouldAutoPlay: Whether playback should start automatically.
    func loadVideo(
        metadata: tableMetadata,
        url: URL,
        fileName: String,
        userAgent: String?,
        httpHeaders: [String: String],
        shouldAutoPlay: Bool
    ) {
        if isSameLoadedVideo(
            metadata: metadata,
            url: url
        ) {
            resumeCurrentPlaybackIfNeeded(shouldAutoPlay: shouldAutoPlay)

            nkLog(
                tag: NCGlobal.shared.logTagViewer,
                emoji: .debug,
                message: "VIDEO controller reuse existing player ocId \(metadata.ocId)",
                consoleOnly: true
            )

            return
        }

        stop()

        let token = UUID()
        loadToken = token
        currentOcId = metadata.ocId
        currentEtag = metadata.etag
        currentURL = url
        currentFileName = fileName
        engine = .loading

        if url.isFileURL,
           !isValidLocalFile(url: url) {
            engine = .failed(message: "Video file is not available.")
            return
        }

        configureAudioSession()

        if shouldUseVLCWithoutAVFoundation(
            url: url,
            fileName: fileName
        ) {
            loadVLC(
                metadata: metadata,
                url: url,
                userAgent: userAgent,
                shouldAutoPlay: shouldAutoPlay,
                reason: "direct legacy format \(resolvedVideoExtension(url: url, fileName: fileName))",
                token: token
            )
            return
        }

        prepareAVFoundation(
            metadata: metadata,
            url: url,
            httpHeaders: url.isFileURL ? [:] : httpHeaders,
            userAgent: userAgent,
            shouldAutoPlay: shouldAutoPlay,
            token: token
        )

        startFallbackTimeout(
            metadata: metadata,
            url: url,
            userAgent: userAgent,
            shouldAutoPlay: shouldAutoPlay,
            token: token
        )
    }

    /// Stops the current video only if the supplied page owns playback.
    ///
    /// - Parameter ocId: Page file identifier.
    func stopIfCurrent(ocId: String) {
        guard currentOcId == ocId else {
            return
        }

        stop()
    }

    /// Stops all video playback and releases AVFoundation and VLC resources.
    func stop() {
        loadToken = UUID()

        timeoutTask?.cancel()
        timeoutTask = nil

        statusObservation?.invalidate()
        statusObservation = nil

        avPlayer?.pause()
        avPlayer = nil
        avPlayerItem = nil

        vlcController.stop()

        currentOcId = nil
        currentEtag = nil
        currentURL = nil
        currentFileName = nil

        engine = .loading
    }

    // MARK: - AVFoundation

    /// Prepares an AVFoundation player item and observes its readiness.
    private func prepareAVFoundation(
        metadata: tableMetadata,
        url: URL,
        httpHeaders: [String: String],
        userAgent: String?,
        shouldAutoPlay: Bool,
        token: UUID
    ) {
        let assetOptions: [String: Any]? = httpHeaders.isEmpty
            ? nil
            : [
                "AVURLAssetHTTPHeaderFieldsKey": httpHeaders
            ]

        let asset = AVURLAsset(
            url: url,
            options: assetOptions
        )

        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)

        player.actionAtItemEnd = .pause

        avPlayerItem = item
        avPlayer = player

        statusObservation = item.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else {
                    return
                }

                guard self.isCurrentLoad(
                    url: url,
                    token: token
                ) else {
                    return
                }

                switch item.status {
                case .readyToPlay:
                    self.resolveWithAVFoundation(
                        player: player,
                        token: token
                    )

                case .failed:
                    self.loadVLC(
                        metadata: metadata,
                        url: url,
                        userAgent: userAgent,
                        shouldAutoPlay: shouldAutoPlay,
                        reason: item.error?.localizedDescription ?? "AVFoundation failed.",
                        token: token
                    )

                case .unknown:
                    break

                @unknown default:
                    self.loadVLC(
                        metadata: metadata,
                        url: url,
                        userAgent: userAgent,
                        shouldAutoPlay: shouldAutoPlay,
                        reason: "AVFoundation returned an unknown status.",
                        token: token
                    )
                }
            }
        }
    }

    /// Selects AVFoundation as the active rendering engine.
    private func resolveWithAVFoundation(
        player: AVPlayer,
        token: UUID
    ) {
        guard loadToken == token else {
            return
        }

        timeoutTask?.cancel()
        timeoutTask = nil

        engine = .avFoundation(player: player)

        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: .debug,
            message: "VIDEO engine AVFoundation",
            consoleOnly: true
        )
    }

    /// Starts a timeout after which VLC is selected if AVFoundation is still loading.
    private func startFallbackTimeout(
        metadata: tableMetadata,
        url: URL,
        userAgent: String?,
        shouldAutoPlay: Bool,
        token: UUID
    ) {
        timeoutTask = Task { [weak self] in
            guard let self else {
                return
            }

            try? await Task.sleep(
                for: .milliseconds(self.fallbackTimeoutMilliseconds)
            )

            await MainActor.run {
                guard self.isCurrentLoad(
                    url: url,
                    token: token
                ) else {
                    return
                }

                if case .loading = self.engine {
                    self.loadVLC(
                        metadata: metadata,
                        url: url,
                        userAgent: userAgent,
                        shouldAutoPlay: shouldAutoPlay,
                        reason: "AVFoundation timeout.",
                        token: token
                    )
                }
            }
        }
    }

    // MARK: - VLC

    /// Selects VLC as the active rendering engine.
    private func loadVLC(
        metadata: tableMetadata,
        url: URL,
        userAgent: String?,
        shouldAutoPlay: Bool,
        reason: String,
        token: UUID
    ) {
        guard isCurrentLoad(
            url: url,
            token: token
        ) else {
            return
        }

        timeoutTask?.cancel()
        timeoutTask = nil

        statusObservation?.invalidate()
        statusObservation = nil

        avPlayer?.pause()
        avPlayer = nil
        avPlayerItem = nil

        vlcController.load(
            metadata: metadata,
            url: url,
            userAgent: userAgent,
            shouldAutoPlay: shouldAutoPlay
        )

        engine = .vlc(controller: vlcController)

        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: .debug,
            message: "VIDEO engine VLC: \(reason)",
            consoleOnly: true
        )
    }

    // MARK: - State Helpers

    /// Returns whether the supplied media request is already loaded.
    private func isSameLoadedVideo(
        metadata: tableMetadata,
        url: URL
    ) -> Bool {
        currentOcId == metadata.ocId &&
        currentEtag == metadata.etag &&
        currentURL == url
    }

    /// Returns whether a callback belongs to the current load request.
    private func isCurrentLoad(
        url: URL,
        token: UUID
    ) -> Bool {
        loadToken == token && currentURL == url
    }

    /// Resumes the current player if requested.
    private func resumeCurrentPlaybackIfNeeded(shouldAutoPlay: Bool) {
        guard shouldAutoPlay else {
            return
        }

        switch engine {
        case .avFoundation(let player):
            if player.timeControlStatus != .playing {
                player.play()
            }

        case .vlc(let controller):
            if !controller.isPlaying {
                controller.play()
            }

        case .loading,
             .failed:
            break
        }
    }

    // MARK: - Private Helpers

    /// Configures the audio session for video playback.
    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .moviePlayback,
                options: []
            )

            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            nkLog(
                tag: NCGlobal.shared.logTagViewer,
                emoji: .error,
                message: "VIDEO audio session error: \(error.localizedDescription)",
                consoleOnly: true
            )
        }
    }

    /// Returns whether a video format should bypass AVFoundation and use VLC directly.
    private func shouldUseVLCWithoutAVFoundation(
        url: URL,
        fileName: String
    ) -> Bool {
        let pathExtension = resolvedVideoExtension(
            url: url,
            fileName: fileName
        )

        let legacyVideoExtensions: Set<String> = [
            "avi",
            "divx",
            "xvid",
            "wmv",
            "flv",
            "vob",
            "mkv"
        ]

        return legacyVideoExtensions.contains(pathExtension)
    }

    /// Resolves the best available video extension.
    private func resolvedVideoExtension(
        url: URL,
        fileName: String
    ) -> String {
        let metadataExtension = URL(fileURLWithPath: fileName)
            .pathExtension
            .lowercased()

        if !metadataExtension.isEmpty {
            return metadataExtension
        }

        return url.pathExtension.lowercased()
    }

    /// Checks whether a local file exists and has a non-zero size.
    private func isValidLocalFile(url: URL) -> Bool {
        let path = url.path

        guard FileManager.default.fileExists(atPath: path) else {
            return false
        }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = attributes[.size] as? Int64,
              fileSize > 0 else {
            return false
        }

        return true
    }
}
