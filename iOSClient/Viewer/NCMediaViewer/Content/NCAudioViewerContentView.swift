// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AVFoundation
import NextcloudKit
import MediaPlayer

// MARK: - Audio Viewer View

/// Displays and plays a local audio file.
///
/// This view owns a lightweight `AVPlayer` model and provides:
/// - file title
/// - play / pause button
/// - loop button
/// - previous / next buttons
/// - restart button
/// - elapsed and duration labels
/// - seek slider
/// - automatic cleanup when the view disappears
struct NCAudioViewerContentView: View {
    let metadata: tableMetadata
    let localURL: URL
    let canGoPrevious: Bool
    let canGoNext: Bool
    let shouldAutoPlay: Bool
    let onPrevious: (_ shouldAutoPlay: Bool) -> Void
    let onNext: (_ shouldAutoPlay: Bool) -> Void
    let onAutoPlayConsumed: () -> Void

    @StateObject private var model = NCAudioViewerModel()

    init(
        metadata: tableMetadata,
        localURL: URL,
        canGoPrevious: Bool = false,
        canGoNext: Bool = false,
        shouldAutoPlay: Bool = false,
        onPrevious: @escaping (_ shouldAutoPlay: Bool) -> Void = { _ in },
        onNext: @escaping (_ shouldAutoPlay: Bool) -> Void = { _ in },
        onAutoPlayConsumed: @escaping () -> Void = {}
    ) {
        self.metadata = metadata
        self.localURL = localURL
        self.canGoPrevious = canGoPrevious
        self.canGoNext = canGoNext
        self.shouldAutoPlay = shouldAutoPlay
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.onAutoPlayConsumed = onAutoPlayConsumed
    }

    var body: some View {
        VStack(spacing: 28) {
            artworkView

            VStack(spacing: 8) {
                Text(displayFileName)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Text(metadata.contentType.isEmpty ? "Audio" : metadata.contentType)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            .padding(.horizontal, 24)

            VStack(spacing: 10) {
                Slider(
                    value: Binding(
                        get: { model.currentTime },
                        set: { model.seek(to: $0) }
                    ),
                    in: 0...max(model.duration, 1)
                )
                .disabled(model.duration <= 0)

                HStack {
                    Text(formatTime(model.currentTime))

                    Spacer()

                    Text(formatTime(model.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 32)

            HStack(spacing: 28) {
                Button {
                    let shouldAutoPlay = model.isPlaying

                    model.pause()
                    onPrevious(shouldAutoPlay)
                } label: {
                    Image(systemName: "backward.end.circle")
                        .font(.system(size: 38, weight: .regular))
                        .foregroundStyle(canGoPrevious ? .white.opacity(0.75) : .white.opacity(0.22))
                }
                .buttonStyle(.plain)
                .disabled(!canGoPrevious)

                Button {
                    model.toggleLoop()
                } label: {
                    Image(systemName: model.isLoopEnabled ? "repeat.circle.fill" : "repeat.circle")
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(model.isLoopEnabled ? .white : .white.opacity(0.45))
                }
                .buttonStyle(.plain)

                Button {
                    if model.isPlaying {
                        model.pause()
                    } else {
                        model.play()
                    }
                } label: {
                    Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 72, weight: .regular))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button {
                    model.restart()
                } label: {
                    Image(systemName: "gobackward")
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
                .disabled(model.duration <= 0)

                Button {
                    let shouldAutoPlay = model.isPlaying

                    model.pause()
                    onNext(shouldAutoPlay)
                } label: {
                    Image(systemName: "forward.end.circle")
                        .font(.system(size: 38, weight: .regular))
                        .foregroundStyle(canGoNext ? .white.opacity(0.75) : .white.opacity(0.22))
                }
                .buttonStyle(.plain)
                .disabled(!canGoNext)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .task(id: localURL) {
            await model.load(
                url: localURL,
                title: displayFileName,
                artist: metadata.contentType.isEmpty ? nil : metadata.contentType,
                onPrevious: onPrevious,
                onNext: onNext
            )

            consumeAutoPlayIfNeeded()
        }
        .onChange(of: shouldAutoPlay) { _, _ in
            consumeAutoPlayIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ncMediaViewerStopPlayback)) { _ in
            model.pause()
        }
        .onDisappear {
            model.stop()
        }
    }

    // MARK: - Views

    private var artworkView: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.08))
                .frame(width: 180, height: 180)

            Image(systemName: "waveform")
                .font(.system(size: 76, weight: .regular))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    // MARK: - Private

    private var displayFileName: String {
        if !metadata.fileNameView.isEmpty {
            return metadata.fileNameView
        }

        return metadata.fileName
    }

    /// Starts playback when this page receives an auto-play request.
    @MainActor
    private func consumeAutoPlayIfNeeded() {
        guard shouldAutoPlay else {
            return
        }

        guard model.play() else {
            return
        }

        onAutoPlayConsumed()
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite,
              seconds >= 0 else {
            return "00:00"
        }

        let totalSeconds = Int(seconds.rounded())
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60

        return String(
            format: "%02d:%02d",
            minutes,
            remainingSeconds
        )
    }
}

// MARK: - Audio Viewer Model

/// Lightweight audio playback model backed by `AVPlayer`.
///
/// The model observes playback time and item completion, exposes SwiftUI-friendly
/// state, and performs cleanup when playback is stopped or the view disappears.
@MainActor
final class NCAudioViewerModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double = 0
    @Published var currentTime: Double = 0
    @Published private(set) var isLoopEnabled = false

    // MARK: - Private State

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var currentURL: URL?
    private var nowPlayingTitle: String = "Audio"
    private var nowPlayingArtist: String?
    private var onPreviousCommand: ((_ shouldAutoPlay: Bool) -> Void)?
    private var onNextCommand: ((_ shouldAutoPlay: Bool) -> Void)?

    // MARK: - Public API

    /// Loads a local audio file.
    ///
    /// - Parameters:
    ///   - url: Local audio file URL.
    ///   - title: Display title used for Now Playing.
    ///   - artist: Optional secondary text used for Now Playing.
    ///   - onPrevious: Callback used by previous-track remote command.
    ///   - onNext: Callback used by next-track remote command.
    func load(
        url: URL,
        title: String,
        artist: String? = nil,
        onPrevious: ((_ shouldAutoPlay: Bool) -> Void)? = nil,
        onNext: ((_ shouldAutoPlay: Bool) -> Void)? = nil
    ) async {
        nowPlayingTitle = title
        nowPlayingArtist = artist
        onPreviousCommand = onPrevious
        onNextCommand = onNext

        guard currentURL != url else {
            updateNowPlayingInfo()
            return
        }

        stop()

        currentURL = url
        nowPlayingTitle = title
        nowPlayingArtist = artist
        onPreviousCommand = onPrevious
        onNextCommand = onNext

        configureAudioSession()
        configureRemoteCommands()

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)

        player.actionAtItemEnd = .pause

        self.player = player

        if let duration = try? await asset.load(.duration),
           duration.seconds.isFinite {
            self.duration = duration.seconds
        } else {
            self.duration = 0
        }

        addTimeObserver(to: player)
        addEndObserver(for: item, player: player)
        updateNowPlayingInfo()
    }

    /// Starts audio playback.
    ///
    /// - Returns: True when playback was started.
    @discardableResult
    func play() -> Bool {
        guard let player else {
            return false
        }

        if duration > 0,
           currentTime >= duration - 0.2 {
            seek(to: 0)
        }

        player.play()
        isPlaying = true
        updateNowPlayingInfo()

        return true
    }

    /// Toggles audio playback.
    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Toggles loop playback.
    func toggleLoop() {
        isLoopEnabled.toggle()
    }

    /// Restarts playback from the beginning.
    func restart() {
        seek(to: 0)

        if isPlaying {
            player?.play()
            updateNowPlayingInfo()
        }
    }

    /// Seeks to a specific playback time.
    ///
    /// - Parameter seconds: Target playback position in seconds.
    func seek(to seconds: Double) {
        guard let player else {
            return
        }

        let clampedSeconds = min(
            max(seconds, 0),
            max(duration, 0)
        )

        currentTime = clampedSeconds
        updateNowPlayingInfo()

        let time = CMTime(
            seconds: clampedSeconds,
            preferredTimescale: 600
        )

        player.seek(
            to: time,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    /// Pauses playback without releasing the player.
    func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }

    /// Stops playback and releases the player.
    func stop() {
        if let player {
            player.pause()
        }

        if let timeObserver,
           let player {
            player.removeTimeObserver(timeObserver)
        }

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }

        timeObserver = nil
        endObserver = nil
        player = nil
        currentURL = nil
        onPreviousCommand = nil
        onNextCommand = nil

        isPlaying = false
        currentTime = 0
        duration = 0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
    }

    // MARK: - Private

    /// Configures the audio session for media playback.
    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                options: []
            )

            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            nkLog(
                tag: NCGlobal.shared.logTagViewer,
                emoji: .error,
                message: "AUDIO session error: \(error.localizedDescription)",
                consoleOnly: true
            )
        }
    }

    /// Configures Lock Screen, Control Center, and headset remote commands.
    private func configureRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)

        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true

        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                _ = self?.play()
            }

            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.pause()
            }

            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.togglePlayback()
            }

            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }

            Task { @MainActor in
                self?.seek(to: event.positionTime)
            }

            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else {
                    return
                }

                let shouldAutoPlay = self.isPlaying

                self.pause()
                self.onPreviousCommand?(shouldAutoPlay)
            }

            return .success
        }

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else {
                    return
                }

                let shouldAutoPlay = self.isPlaying

                self.pause()
                self.onNextCommand?(shouldAutoPlay)
            }

            return .success
        }
    }

    /// Updates the system Now Playing information shown on Lock Screen and Control Center.
    private func updateNowPlayingInfo() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlayingTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]

        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }

        if let nowPlayingArtist {
            info[MPMediaItemPropertyArtist] = nowPlayingArtist
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Adds a periodic time observer to update SwiftUI playback state.
    ///
    /// - Parameter player: Player to observe.
    private func addTimeObserver(to player: AVPlayer) {
        let interval = CMTime(
            seconds: 0.25,
            preferredTimescale: 600
        )

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            guard let self else {
                return
            }

            Task { @MainActor in
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                self.updateNowPlayingInfo()
            }
        }
    }

    /// Observes the end of playback and restarts the item when loop is enabled.
    ///
    /// - Parameters:
    ///   - item: Player item to observe.
    ///   - player: Player that owns the item.
    private func addEndObserver(
        for item: AVPlayerItem,
        player: AVPlayer
    ) {
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self, weak player] _ in
            guard let self,
                  let player else {
                return
            }

            Task { @MainActor in
                if self.isLoopEnabled {
                    self.currentTime = 0

                    player.seek(
                        to: .zero,
                        toleranceBefore: .zero,
                        toleranceAfter: .zero
                    ) { _ in
                        Task { @MainActor in
                            player.play()
                            self.isPlaying = true
                            self.updateNowPlayingInfo()
                        }
                    }
                } else {
                    self.currentTime = self.duration
                    self.isPlaying = false
                    self.updateNowPlayingInfo()
                }
            }
        }
    }
}
