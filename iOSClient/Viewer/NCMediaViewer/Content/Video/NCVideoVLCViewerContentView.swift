// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit
import MobileVLCKit
import NextcloudKit

// MARK: - VLC Video Viewer Content View

/// Displays a video using MobileVLCKit with SwiftUI overlay controls.
///
/// This view is used as fallback when AVFoundation cannot prepare the video.
/// The URL can be either a local file URL or a remote direct-download URL.
///
/// The implementation is intentionally isolated from image, Live Photo, audio,
/// and AVFoundation playback logic.
struct NCVideoVLCViewerContentView: View {
    let metadata: tableMetadata
    let url: URL
    let userAgent: String?
    let shouldAutoPlay: Bool

    @StateObject private var model = NCVideoVLCPlayerModel()

    init(
        metadata: tableMetadata,
        url: URL,
        userAgent: String? = nil,
        shouldAutoPlay: Bool = true
    ) {
        self.metadata = metadata
        self.url = url
        self.userAgent = userAgent
        self.shouldAutoPlay = shouldAutoPlay
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            NCVideoVLCRenderView(mediaPlayer: model.mediaPlayer)
                .ignoresSafeArea()

            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture {
                    model.toggleControls()
                }

            if model.isControlsVisible {
                NCVideoVLCControlsView(
                    model: model,
                    displayFileName: displayFileName
                )
                .transition(.opacity)
            }
        }
        .background(Color.black)
        .contentShape(Rectangle())
        .onTapGesture {
            model.toggleControls()
        }
        .task(id: taskIdentifier) {
            model.load(
                metadata: metadata,
                url: url,
                userAgent: userAgent,
                shouldAutoPlay: shouldAutoPlay
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .ncMediaViewerStopPlayback)) { _ in
            model.stop()
        }
        .onDisappear {
            model.stop()
        }
        .animation(.easeInOut(duration: 0.18), value: model.isControlsVisible)
    }

    // MARK: - Helpers

    private var taskIdentifier: String {
        "\(metadata.ocId)|\(metadata.etag)|\(url.absoluteString)|\(shouldAutoPlay)"
    }

    private var displayFileName: String {
        if !metadata.fileNameView.isEmpty {
            return metadata.fileNameView
        }

        return metadata.fileName
    }
}

// MARK: - VLC Render View

/// UIKit render surface used by `VLCMediaPlayer`.
///
/// This wrapper only assigns the drawable view.
/// Playback state, media loading, and controls are owned by `NCVideoVLCPlayerModel`.
private struct NCVideoVLCRenderView: UIViewRepresentable {
    let mediaPlayer: VLCMediaPlayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        view.clipsToBounds = true

        mediaPlayer.drawable = view

        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        if mediaPlayer.drawable == nil {
            mediaPlayer.drawable = view
        }
    }

    static func dismantleUIView(
        _ view: UIView,
        coordinator: Coordinator
    ) { }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator { }
}

// MARK: - VLC Player Model

/// Lightweight VLC playback model.
///
/// The model owns `VLCMediaPlayer`, exposes SwiftUI-friendly playback state,
/// polls playback time, and provides basic controls such as play, pause, seek,
/// restart, and short skip.
@MainActor
final class NCVideoVLCPlayerModel: ObservableObject {

    // MARK: - Published State

    @Published var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published var isControlsVisible = true

    // MARK: - Public State

    let mediaPlayer = VLCMediaPlayer()

    // MARK: - Private State

    private var currentURL: URL?
    private var monitorTask: Task<Void, Never>?
    private var controlsHideTask: Task<Void, Never>?

    // MARK: - Public API

    /// Loads a VLC media item and optionally starts playback.
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
            if shouldAutoPlay {
                play()
            }

            return
        }

        stop()

        currentURL = url
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

        if shouldAutoPlay {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                Task { @MainActor in
                    self?.play()
                }
            }
        }
    }

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

    /// Restarts playback from the beginning.
    func restart() {
        seek(to: 0)

        if isPlaying {
            mediaPlayer.play()
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

    /// Shows or hides controls.
    func toggleControls() {
        isControlsVisible.toggle()

        if isControlsVisible {
            scheduleControlsAutoHide()
        }
    }

    /// Shows controls immediately.
    func showControls() {
        controlsHideTask?.cancel()
        controlsHideTask = nil
        isControlsVisible = true
    }

    /// Stops playback and releases VLC resources.
    func stop() {
        controlsHideTask?.cancel()
        controlsHideTask = nil

        monitorTask?.cancel()
        monitorTask = nil

        mediaPlayer.stop()
        mediaPlayer.media = nil

        currentURL = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        isControlsVisible = true
    }

    // MARK: - Private

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

        let time = mediaPlayer.time
        let currentSeconds = Double(time.intValue) / 1_000

        if currentSeconds.isFinite {
            currentTime = max(currentSeconds, 0)
        } else {
            currentTime = 0
        }

        guard let media = mediaPlayer.media else {
            return
        }

        let length = media.length
        let durationSeconds = Double(length.intValue) / 1_000

        if durationSeconds.isFinite,
           durationSeconds > 0 {
            duration = durationSeconds
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
}

// MARK: - VLC Controls View

/// SwiftUI controls overlay for VLC playback.
private struct NCVideoVLCControlsView: View {
    @ObservedObject var model: NCVideoVLCPlayerModel

    let displayFileName: String

    var body: some View {
        VStack {
            topBar

            Spacer()

            centerControls

            Spacer()

            bottomControls
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, bottomPadding)
        .foregroundStyle(.white)
        .background(
            LinearGradient(
                colors: [
                    .black.opacity(0.55),
                    .clear,
                    .black.opacity(0.7)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }

    // MARK: - Sections

    private var topBar: some View {
        HStack {
            Text(displayFileName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()
        }
        .foregroundStyle(.white.opacity(0.9))
    }

    private var centerControls: some View {
        HStack(spacing: 36) {
            Button {
                model.skip(by: -15)
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 36, weight: .regular))
            }
            .buttonStyle(.plain)

            Button {
                model.togglePlayback()
            } label: {
                Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 72, weight: .regular))
            }
            .buttonStyle(.plain)

            Button {
                model.skip(by: 15)
            } label: {
                Image(systemName: "goforward.15")
                    .font(.system(size: 36, weight: .regular))
            }
            .buttonStyle(.plain)
        }
        .shadow(radius: 4)
    }

    private var bottomControls: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { model.currentTime },
                    set: { model.currentTime = $0 }
                ),
                in: 0...max(model.duration, 1),
                onEditingChanged: { isEditing in
                    model.showControls()

                    if !isEditing {
                        model.seek(to: model.currentTime)
                    }
                }
            )
            .disabled(model.duration <= 0)

            HStack {
                Text(formatTime(model.currentTime))

                Spacer()

                Text(formatTime(model.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.75))
        }
    }

    // MARK: - Helpers

    private var bottomPadding: CGFloat {
        let windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }

        let window = windowScene?.windows.first { $0.isKeyWindow }
        let safeBottom = window?.safeAreaInsets.bottom ?? 0

        return max(safeBottom + 8, 24)
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
