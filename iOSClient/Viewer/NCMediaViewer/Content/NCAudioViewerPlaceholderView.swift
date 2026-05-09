// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AVFoundation

// MARK: - Audio Viewer View

/// Displays and plays a local audio file.
///
/// This view owns a lightweight `AVPlayer` model and provides:
/// - file title
/// - play / pause button
/// - elapsed and duration labels
/// - seek slider
/// - automatic cleanup when the view disappears
struct NCAudioViewerPlaceholderView: View {

    // MARK: - Properties

    let metadata: tableMetadata
    let localURL: URL

    @StateObject private var model = NCAudioViewerModel()

    // MARK: - Body

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

            Button {
                model.togglePlayback()
            } label: {
                Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 72, weight: .regular))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .task(id: localURL) {
            await model.load(url: localURL)
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
/// The model observes playback time and duration, exposes SwiftUI-friendly state,
/// and performs cleanup when playback is stopped or the view disappears.
@MainActor
final class NCAudioViewerModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double = 0
    @Published var currentTime: Double = 0

    // MARK: - Private State

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var currentURL: URL?

    // MARK: - Public API

    /// Loads a local audio file.
    ///
    /// - Parameter url: Local audio file URL.
    func load(url: URL) async {
        guard currentURL != url else {
            return
        }

        stop()

        currentURL = url

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)

        self.player = player

        if let duration = try? await asset.load(.duration) {
            self.duration = duration.seconds.isFinite ? duration.seconds : 0
        } else {
            self.duration = 0
        }

        addTimeObserver(to: player)
    }

    /// Toggles audio playback.
    func togglePlayback() {
        guard let player else {
            return
        }

        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
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

    /// Stops playback and releases the player.
    func stop() {
        if let player {
            player.pause()
        }

        if let timeObserver,
           let player {
            player.removeTimeObserver(timeObserver)
        }

        timeObserver = nil
        player = nil
        currentURL = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    // MARK: - Private

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

                if self.duration > 0,
                   self.currentTime >= self.duration - 0.2 {
                    self.isPlaying = false
                    self.currentTime = self.duration
                }
            }
        }
    }
}
