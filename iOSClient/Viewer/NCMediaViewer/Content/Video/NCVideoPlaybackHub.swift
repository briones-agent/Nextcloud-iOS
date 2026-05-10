// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Foundation
import NextcloudKit

// MARK: - Video Playback Engine

/// Describes the selected video playback engine.
///
/// AVFoundation is preferred because it supports native iOS playback features,
/// including Picture in Picture where available.
/// VLC is used as fallback when AVFoundation cannot prepare the asset.
enum NCVideoPlaybackEngine {
    /// The hub is resolving the best playback engine.
    case loading

    /// Native AVFoundation playback using an `AVPlayer`.
    case avFoundation(player: AVPlayer)

    /// VLC fallback playback using a local file URL.
    case vlc(url: URL)

    /// Playback could not be prepared.
    case failed(message: String)
}

// MARK: - Video Playback Hub

/// Resolves and owns the best playback engine for a local video file.
///
/// The hub first tries AVFoundation. If the item reaches `.readyToPlay`,
/// the viewer uses AVFoundation. If the item fails or does not become ready
/// before the timeout, the hub falls back to VLC.
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

    private let fallbackTimeoutSeconds: Double = 1.5

    // MARK: - Public API

    /// Loads a local video file and resolves the preferred playback engine.
    ///
    /// AVFoundation is attempted first. VLC is selected only when AVFoundation
    /// fails, reports an unsupported item, or does not become ready before the
    /// fallback timeout.
    ///
    /// - Parameter url: Local video file URL.
    func load(url: URL) {
        guard currentURL != url else {
            return
        }

        stop()

        currentURL = url
        engine = .loading

        guard isValidLocalFile(url: url) else {
            engine = .failed(message: "Video file is not available.")
            return
        }

        configureAudioSession()
        prepareAVFoundation(url: url)
        startFallbackTimeout(url: url)
    }

    /// Stops playback and releases all current resources.
    func stop() {
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
    /// - Parameter url: Local video file URL.
    private func prepareAVFoundation(url: URL) {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)

        player.actionAtItemEnd = .pause

        self.playerItem = item
        self.player = player

        statusObservation = item.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else {
                    return
                }

                guard self.currentURL == url else {
                    return
                }

                switch item.status {
                case .readyToPlay:
                    self.resolveWithAVFoundation(player: player)

                case .failed:
                    self.fallbackToVLC(
                        url: url,
                        reason: item.error?.localizedDescription ?? "AVFoundation failed."
                    )

                case .unknown:
                    break

                @unknown default:
                    self.fallbackToVLC(
                        url: url,
                        reason: "AVFoundation returned an unknown status."
                    )
                }
            }
        }
    }

    /// Selects AVFoundation as playback engine.
    ///
    /// - Parameter player: Prepared AVPlayer.
    private func resolveWithAVFoundation(player: AVPlayer) {
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
    /// - Parameter url: Local video file URL.
    private func startFallbackTimeout(url: URL) {
        timeoutTask = Task { [weak self] in
            guard let self else {
                return
            }

            try? await Task.sleep(
                for: .seconds(fallbackTimeoutSeconds)
            )

            await MainActor.run {
                guard self.currentURL == url else {
                    return
                }

                if case .loading = self.engine {
                    self.fallbackToVLC(
                        url: url,
                        reason: "AVFoundation timeout."
                    )
                }
            }
        }
    }

    /// Selects VLC as playback engine.
    ///
    /// - Parameters:
    ///   - url: Local video file URL.
    ///   - reason: Debug reason for the fallback.
    private func fallbackToVLC(
        url: URL,
        reason: String
    ) {
        timeoutTask?.cancel()
        timeoutTask = nil

        statusObservation?.invalidate()
        statusObservation = nil

        player?.pause()
        player = nil
        playerItem = nil

        guard currentURL == url else {
            return
        }

        engine = .vlc(url: url)

        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: .debug,
            message: "VIDEO engine VLC fallback: \(reason)",
            consoleOnly: true
        )
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
