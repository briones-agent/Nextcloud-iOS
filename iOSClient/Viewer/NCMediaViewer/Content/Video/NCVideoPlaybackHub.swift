// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Foundation
import NextcloudKit

// MARK: - Video Playback Engine

/// Describes the currently selected video playback engine.
///
/// AVFoundation is preferred because it supports native iOS playback features,
/// including Picture in Picture where available. VLC is used as fallback when
/// AVFoundation cannot prepare the asset.
enum NCVideoPlaybackEngine {
    /// The hub is resolving the best playback engine.
    case loading

    /// Native AVFoundation playback using an `AVPlayer`.
    case avFoundation(player: AVPlayer)

    /// VLC fallback playback using a local or remote URL.
    case vlc(url: URL)

    /// Playback could not be prepared.
    case failed(message: String)
}

// MARK: - Video Playback Hub

/// Resolves and owns the best playback engine for a video URL.
///
/// The input URL can be either:
/// - a local file URL
/// - a remote direct-download URL
///
/// The hub first tries AVFoundation. If the item reaches `.readyToPlay`,
/// the viewer uses AVFoundation. If the item fails or does not become ready
/// before the fallback timeout, the hub switches to VLC.
///
/// A generation token is used to ignore stale AVFoundation callbacks or timeout
/// tasks produced by an older load request.
@MainActor
final class NCVideoPlaybackHub: ObservableObject {

    // MARK: - Published State

    /// Current resolved playback engine.
    @Published private(set) var engine: NCVideoPlaybackEngine = .loading

    // MARK: - Private State

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var statusObservation: NSKeyValueObservation?
    private var timeoutTask: Task<Void, Never>?
    private var currentURL: URL?
    private var loadToken = UUID()

    private let fallbackTimeoutMilliseconds = 1_500

    // MARK: - Public API

    /// Loads a video URL and resolves the preferred playback engine.
    ///
    /// AVFoundation is attempted first. VLC is selected only when AVFoundation
    /// fails, reports an unsupported item, or does not become ready before the
    /// fallback timeout.
    ///
    /// - Parameters:
    ///   - url: Local or remote video URL.
    ///   - httpHeaders: Optional HTTP headers used by AVFoundation for remote playback.
    func load(
        url: URL,
        httpHeaders: [String: String] = [:]
    ) {
        if currentURL == url,
           !isLoading {
            return
        }

        stop()

        let token = UUID()
        loadToken = token
        currentURL = url
        engine = .loading

        if url.isFileURL,
           !isValidLocalFile(url: url) {
            engine = .failed(message: "Video file is not available.")
            return
        }

        configureAudioSession()

        prepareAVFoundation(
            url: url,
            httpHeaders: url.isFileURL ? [:] : httpHeaders,
            token: token
        )

        startFallbackTimeout(
            url: url,
            token: token
        )
    }

    /// Stops playback and releases all current resources.
    ///
    /// This also invalidates the current load generation so stale timeout tasks
    /// and AVFoundation status callbacks cannot update the engine anymore.
    func stop() {
        loadToken = UUID()

        timeoutTask?.cancel()
        timeoutTask = nil

        statusObservation?.invalidate()
        statusObservation = nil

        player?.pause()
        player = nil
        playerItem = nil
        currentURL = nil

        engine = .loading
    }

    /// Pauses the current AVFoundation player if active.
    ///
    /// VLC playback is stopped by the VLC view when it is dismantled.
    func pause() {
        player?.pause()
    }

    // MARK: - AVFoundation Resolution

    /// Prepares an AVFoundation player item and observes its status.
    ///
    /// - Parameters:
    ///   - url: Local or remote video URL.
    ///   - httpHeaders: Optional HTTP headers used by AVFoundation for remote playback.
    ///   - token: Load generation token used to ignore stale callbacks.
    private func prepareAVFoundation(
        url: URL,
        httpHeaders: [String: String],
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

        playerItem = item
        self.player = player

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
                    self.fallbackToVLC(
                        url: url,
                        reason: item.error?.localizedDescription ?? "AVFoundation failed.",
                        token: token
                    )

                case .unknown:
                    break

                @unknown default:
                    self.fallbackToVLC(
                        url: url,
                        reason: "AVFoundation returned an unknown status.",
                        token: token
                    )
                }
            }
        }
    }

    /// Selects AVFoundation as playback engine.
    ///
    /// - Parameters:
    ///   - player: Prepared AVPlayer.
    ///   - token: Load generation token used to ignore stale callbacks.
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
    ///
    /// - Parameters:
    ///   - url: Local or remote video URL.
    ///   - token: Load generation token used to ignore stale timeout tasks.
    private func startFallbackTimeout(
        url: URL,
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
                    self.fallbackToVLC(
                        url: url,
                        reason: "AVFoundation timeout.",
                        token: token
                    )
                }
            }
        }
    }

    /// Selects VLC as playback engine.
    ///
    /// - Parameters:
    ///   - url: Local or remote video URL.
    ///   - reason: Debug reason for the fallback.
    ///   - token: Load generation token used to ignore stale callbacks.
    private func fallbackToVLC(
        url: URL,
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

        player?.pause()
        player = nil
        playerItem = nil

        engine = .vlc(url: url)

        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: .debug,
            message: "VIDEO engine VLC fallback: \(reason)",
            consoleOnly: true
        )
    }

    // MARK: - State Helpers

    /// Returns whether the hub is currently resolving an engine.
    private var isLoading: Bool {
        if case .loading = engine {
            return true
        }

        return false
    }

    /// Returns whether a callback belongs to the current load request.
    ///
    /// - Parameters:
    ///   - url: URL associated with the callback.
    ///   - token: Load generation token associated with the callback.
    /// - Returns: True when the callback belongs to the active load request.
    private func isCurrentLoad(
        url: URL,
        token: UUID
    ) -> Bool {
        loadToken == token && currentURL == url
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

    /// Checks whether a local file exists and has a non-zero size.
    ///
    /// - Parameter url: Local file URL.
    /// - Returns: True when the file exists and is not empty.
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
