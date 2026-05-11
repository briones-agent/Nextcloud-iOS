// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import UIKit
import MobileVLCKit
import NextcloudKit

// MARK: - VLC Player Controller

/// Singleton VLC playback controller.
///
/// This object owns the only `VLCMediaPlayer` used by the media viewer.
/// The drawable is attached to a stable UIKit `UIImageView`, following the
/// legacy media viewer behavior.
///
/// Design rules:
/// - Do not hard-rebind the drawable during rotation.
/// - Do not detach the drawable from SwiftUI or UIKit teardown.
/// - Do not reload media during rotation.
/// - Release VLC resources only from `stop()`.
@MainActor
final class NCVideoVLCPlayerController: ObservableObject {
    static let shared = NCVideoVLCPlayerController()

    // MARK: - Published State

    @Published var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published var isControlsVisible = true

    @Published private(set) var audioTracks: [NCVideoVLCAudioTrack] = []
    @Published private(set) var currentAudioTrackIndex: Int32 = -1

    @Published private(set) var subtitleTracks: [NCVideoVLCSubtitleTrack] = []
    @Published private(set) var currentSubtitleTrackIndex: Int32 = -1

    // MARK: - Public State

    let mediaPlayer = VLCMediaPlayer()

    // MARK: - Private State

    private var currentURL: URL?
    private var currentUserAgent: String?

    private var monitorTask: Task<Void, Never>?
    private var controlsHideTask: Task<Void, Never>?
    private var trackRefreshTask: Task<Void, Never>?

    private init() { }

    // MARK: - Drawable

    /// Returns whether VLC is already attached to the given drawable view.
    ///
    /// - Parameter view: Candidate drawable view.
    /// - Returns: True when the VLC drawable is already this view.
    func isDrawableAttached(to view: UIView) -> Bool {
        guard let currentDrawable = mediaPlayer.drawable as? UIView else {
            return false
        }

        return currentDrawable === view
    }

    /// Attaches the VLC drawable only when needed.
    ///
    /// This intentionally avoids hard-rebinding the drawable during rotation.
    /// The legacy media viewer assigned the drawable to a stable `UIImageView`
    /// and let UIKit layout handle rotation.
    ///
    /// - Parameter view: Stable UIKit drawable view.
    func attachDrawableIfNeeded(_ view: UIView) {
        guard view.window != nil,
              view.bounds.width > 0,
              view.bounds.height > 0 else {
            return
        }

        if isDrawableAttached(to: view) {
            return
        }

        mediaPlayer.drawable = view

        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: .debug,
            message: "VIDEO VLC drawable attached to stable UIImageView bounds \(view.bounds)",
            consoleOnly: true
        )
    }

    // MARK: - Loading

    /// Loads a VLC media item when needed and optionally starts playback.
    ///
    /// Calling this method again with the same URL is idempotent and does not
    /// recreate the media player or restart playback.
    ///
    /// - Parameters:
    ///   - metadata: Video metadata used for logging.
    ///   - url: Local or remote video URL.
    ///   - userAgent: Optional HTTP User-Agent used for remote playback.
    ///   - shouldAutoPlay: Whether playback should start immediately.
    func load(
        metadata: tableMetadata,
        url: URL,
        userAgent: String?,
        shouldAutoPlay: Bool
    ) {
        if currentURL == url {
            if shouldAutoPlay,
               !mediaPlayer.isPlaying {
                play()
            }

            return
        }

        stop()

        currentURL = url
        currentUserAgent = userAgent

        currentTime = 0
        duration = 0
        isPlaying = false
        isControlsVisible = true

        let media = VLCMedia(url: url)

        if let userAgent,
           !userAgent.isEmpty,
           !url.isFileURL {
            media.addOption(":http-user-agent=\(userAgent)")
        }

        mediaPlayer.media = media

        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: .debug,
            message: "VIDEO VLC load \(metadata.ocId), url \(url.absoluteString), userAgent \(userAgent != nil)",
            consoleOnly: true
        )

        startMonitoring()
        refreshTracksRepeatedly()

        if shouldAutoPlay {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                Task { @MainActor in
                    self?.play()
                }
            }
        }
    }

    // MARK: - Playback

    /// Starts playback.
    func play() {
        mediaPlayer.play()
        isPlaying = true
        scheduleControlsAutoHide()
    }

    /// Pauses playback.
    func pause() {
        mediaPlayer.pause()
        isPlaying = false
        showControls()
    }

    /// Toggles play or pause.
    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Skips playback by a relative number of seconds.
    ///
    /// - Parameter seconds: Relative offset in seconds.
    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    /// Seeks playback to a specific time.
    ///
    /// - Parameter seconds: Target playback position in seconds.
    func seek(to seconds: Double) {
        guard duration > 0 else {
            return
        }

        let clampedSeconds = min(
            max(seconds, 0),
            duration
        )

        currentTime = clampedSeconds

        let position = Float(clampedSeconds / duration)
        mediaPlayer.position = min(max(position, 0), 1)

        scheduleControlsAutoHide()
    }

    /// Stops playback and releases VLC resources.
    ///
    /// This is the only place where the VLC drawable is detached.
    /// SwiftUI and UIKit view teardown must not call this unless playback really
    /// has to stop.
    func stop() {
        trackRefreshTask?.cancel()
        trackRefreshTask = nil

        controlsHideTask?.cancel()
        controlsHideTask = nil

        monitorTask?.cancel()
        monitorTask = nil

        mediaPlayer.stop()
        mediaPlayer.media = nil
        mediaPlayer.drawable = nil

        currentURL = nil
        currentUserAgent = nil

        currentTime = 0
        duration = 0
        isPlaying = false
        isControlsVisible = true

        audioTracks = []
        currentAudioTrackIndex = -1

        subtitleTracks = []
        currentSubtitleTrackIndex = -1
    }

    // MARK: - Tracks

    /// Selects a VLC audio track.
    ///
    /// - Parameter index: VLC audio track index.
    func selectAudioTrack(index: Int32) {
        mediaPlayer.currentAudioTrackIndex = index
        currentAudioTrackIndex = index
        showControls()

        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: .debug,
            message: "VIDEO VLC selected audio track index \(index)",
            consoleOnly: true
        )
    }

    /// Selects a VLC subtitle track.
    ///
    /// - Parameter index: VLC subtitle track index.
    func selectSubtitleTrack(index: Int32) {
        mediaPlayer.currentVideoSubTitleIndex = index
        currentSubtitleTrackIndex = index
        showControls()

        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: .debug,
            message: "VIDEO VLC selected subtitle track index \(index)",
            consoleOnly: true
        )
    }

    // MARK: - Controls

    /// Shows controls immediately.
    func showControls() {
        controlsHideTask?.cancel()
        controlsHideTask = nil
        isControlsVisible = true
    }

    /// Shows or hides controls.
    func toggleControls() {
        isControlsVisible.toggle()

        if isControlsVisible {
            scheduleControlsAutoHide()
        }
    }

    /// Hides controls after a short delay while playback is active.
    private func scheduleControlsAutoHide() {
        controlsHideTask?.cancel()

        guard isPlaying else {
            return
        }

        controlsHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))

            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                self?.isControlsVisible = false
            }
        }
    }

    // MARK: - Monitoring

    /// Starts polling VLC playback state.
    private func startMonitoring() {
        monitorTask?.cancel()

        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))

                await MainActor.run {
                    self?.updatePlaybackState()
                }
            }
        }
    }

    /// Updates SwiftUI state from the current VLC player state.
    private func updatePlaybackState() {
        isPlaying = mediaPlayer.isPlaying

        let currentSeconds = Double(mediaPlayer.time.intValue) / 1_000

        if currentSeconds.isFinite {
            currentTime = max(currentSeconds, 0)
        } else {
            currentTime = 0
        }

        if let media = mediaPlayer.media {
            let durationSeconds = Double(media.length.intValue) / 1_000

            if durationSeconds.isFinite,
               durationSeconds > 0 {
                duration = durationSeconds
            }
        }

        updateAudioTracks()
        updateSubtitleTracks()
    }

    /// Refreshes VLC audio and subtitle tracks multiple times after media loading.
    private func refreshTracksRepeatedly() {
        trackRefreshTask?.cancel()

        trackRefreshTask = Task { [weak self] in
            let delays: [Duration] = [
                .milliseconds(150),
                .milliseconds(400),
                .milliseconds(800),
                .milliseconds(1_500),
                .milliseconds(2_500)
            ]

            for delay in delays {
                try? await Task.sleep(for: delay)

                guard !Task.isCancelled else {
                    return
                }

                await MainActor.run {
                    self?.updateAudioTracks()
                    self?.updateSubtitleTracks()
                }
            }
        }
    }

    /// Updates available VLC audio tracks.
    private func updateAudioTracks() {
        let names = readStringArray(mediaPlayer.audioTrackNames)
        let indexes = readInt32Array(mediaPlayer.audioTrackIndexes)
        let currentIndex = mediaPlayer.currentAudioTrackIndex

        let tracks = indexes.enumerated().map { offset, index in
            NCVideoVLCAudioTrack(
                id: index,
                name: trackName(
                    names: names,
                    offset: offset,
                    index: index,
                    fallbackPrefix: "Audio",
                    disabledTitle: "Disable"
                )
            )
        }

        if audioTracks != tracks {
            audioTracks = tracks

            nkLog(
                tag: NCGlobal.shared.logTagViewer,
                emoji: .debug,
                message: "VIDEO VLC audio tracks \(tracks.map { "\($0.id):\($0.name)" }), current \(currentIndex)",
                consoleOnly: true
            )
        }

        if currentAudioTrackIndex != currentIndex {
            currentAudioTrackIndex = currentIndex
        }
    }

    /// Updates available VLC subtitle tracks.
    private func updateSubtitleTracks() {
        let names = readStringArray(mediaPlayer.videoSubTitlesNames)
        let indexes = readInt32Array(mediaPlayer.videoSubTitlesIndexes)
        let currentIndex = mediaPlayer.currentVideoSubTitleIndex

        let tracks = indexes.enumerated().map { offset, index in
            NCVideoVLCSubtitleTrack(
                id: index,
                name: trackName(
                    names: names,
                    offset: offset,
                    index: index,
                    fallbackPrefix: "Subtitle",
                    disabledTitle: "Disable"
                )
            )
        }

        if subtitleTracks != tracks {
            subtitleTracks = tracks

            nkLog(
                tag: NCGlobal.shared.logTagViewer,
                emoji: .debug,
                message: "VIDEO VLC subtitle tracks \(tracks.map { "\($0.id):\($0.name)" }), current \(currentIndex)",
                consoleOnly: true
            )
        }

        if currentSubtitleTrackIndex != currentIndex {
            currentSubtitleTrackIndex = currentIndex
        }
    }

    // MARK: - Helpers

    /// Converts an Objective-C array-like value into strings.
    ///
    /// - Parameter values: Values exposed by MobileVLCKit.
    /// - Returns: Converted string values.
    private func readStringArray(_ values: [Any]) -> [String] {
        values.compactMap { value in
            if let string = value as? String {
                return string
            }

            if let description = value as? CustomStringConvertible {
                return description.description
            }

            return nil
        }
    }

    /// Converts an Objective-C array-like value into Int32 indexes.
    ///
    /// - Parameter values: Values exposed by MobileVLCKit.
    /// - Returns: Converted Int32 values.
    private func readInt32Array(_ values: [Any]) -> [Int32] {
        values.compactMap { value in
            if let number = value as? NSNumber {
                return number.int32Value
            }

            if let intValue = value as? Int {
                return Int32(intValue)
            }

            if let int32Value = value as? Int32 {
                return int32Value
            }

            return nil
        }
    }

    /// Returns a display name for a VLC track.
    ///
    /// - Parameters:
    ///   - names: VLC track names.
    ///   - offset: Track offset.
    ///   - index: VLC track index.
    ///   - fallbackPrefix: Prefix used when VLC does not expose a name.
    ///   - disabledTitle: Prefix used for disabled VLC tracks.
    /// - Returns: User-visible track title.
    private func trackName(
        names: [String],
        offset: Int,
        index: Int32,
        fallbackPrefix: String,
        disabledTitle: String
    ) -> String {
        if names.indices.contains(offset) {
            let name = names[offset]

            if !name.isEmpty {
                return name
            }
        }

        if index == -1 {
            return disabledTitle
        }

        return "\(fallbackPrefix) \(offset + 1)"
    }
}
