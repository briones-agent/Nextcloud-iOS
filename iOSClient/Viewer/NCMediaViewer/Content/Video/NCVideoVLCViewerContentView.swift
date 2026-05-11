// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit
import MobileVLCKit
import NextcloudKit

// MARK: - VLC Audio Track

struct NCVideoVLCAudioTrack: Identifiable, Equatable {
    let id: Int32
    let name: String
}

// MARK: - VLC Subtitle Track

struct NCVideoVLCSubtitleTrack: Identifiable, Equatable {
    let id: Int32
    let name: String
}

// MARK: - VLC Video Viewer Content View

/// Displays a video using MobileVLCKit with SwiftUI overlay controls.
///
/// This view is used as fallback when AVFoundation cannot prepare the video.
/// The implementation is isolated from image, Live Photo, audio, and AVFoundation logic.
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
                .zIndex(0)

            if !model.isControlsVisible {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .zIndex(1)
                    .onTapGesture {
                        model.showControls()
                    }
            }

            if model.isControlsVisible {
                NCVideoVLCControlsView(
                    model: model,
                    displayFileName: displayFileName,
                    onBackgroundTap: {
                        model.toggleControls()
                    }
                )
                .transition(.opacity)
                .zIndex(2)
            }
        }
        .background(Color.black)
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
@MainActor
final class NCVideoVLCPlayerModel: ObservableObject {

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
    private var monitorTask: Task<Void, Never>?
    private var controlsHideTask: Task<Void, Never>?
    private var trackRefreshTask: Task<Void, Never>?

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
        refreshTracksRepeatedly()

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
        trackRefreshTask?.cancel()
        trackRefreshTask = nil

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

        audioTracks = []
        currentAudioTrackIndex = -1

        subtitleTracks = []
        currentSubtitleTrackIndex = -1
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
        let names = readAudioTrackNames()
        let indexes = readAudioTrackIndexes()
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
        let names = readSubtitleTrackNames()
        let indexes = readSubtitleTrackIndexes()
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

    /// Reads VLC audio track names using tolerant casting.
    ///
    /// - Returns: Audio track names exposed by VLC.
    private func readAudioTrackNames() -> [String] {
        readStringArray(mediaPlayer.audioTrackNames)
    }

    /// Reads VLC audio track indexes using tolerant casting.
    ///
    /// - Returns: Audio track indexes exposed by VLC.
    private func readAudioTrackIndexes() -> [Int32] {
        readInt32Array(mediaPlayer.audioTrackIndexes)
    }

    /// Reads VLC subtitle track names using tolerant casting.
    ///
    /// - Returns: Subtitle track names exposed by VLC.
    private func readSubtitleTrackNames() -> [String] {
        readStringArray(mediaPlayer.videoSubTitlesNames)
    }

    /// Reads VLC subtitle track indexes using tolerant casting.
    ///
    /// - Returns: Subtitle track indexes exposed by VLC.
    private func readSubtitleTrackIndexes() -> [Int32] {
        readInt32Array(mediaPlayer.videoSubTitlesIndexes)
    }

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
    ///   - disabledTitle: Title used for disabled track index.
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
    let onBackgroundTap: () -> Void

    var body: some View {
        ZStack {
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
            .contentShape(Rectangle())
            .onTapGesture {
                onBackgroundTap()
            }

            VStack {
                topBar

                Spacer()

                centerControls

                Spacer()

                bottomControls
            }
            .padding(.horizontal, 18)
            .padding(.top, topPadding)
            .padding(.bottom, bottomPadding)
            .foregroundStyle(.white)
        }
    }

    // MARK: - Sections

    private var topBar: some View {
        HStack(spacing: 12) {
            Text(displayFileName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            subtitleTrackButton
            audioTrackButton
        }
        .foregroundStyle(.white.opacity(0.95))
    }

    private var subtitleTrackButton: some View {
        Menu {
            if model.subtitleTracks.isEmpty {
                Button("No subtitles") { }
                    .disabled(true)
            } else {
                ForEach(model.subtitleTracks) { track in
                    Button {
                        model.selectSubtitleTrack(index: track.id)
                    } label: {
                        HStack {
                            Text(track.name)

                            if track.id == model.currentSubtitleTrackIndex {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "captions.bubble.fill")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.55))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var audioTrackButton: some View {
        Menu {
            if model.audioTracks.isEmpty {
                Button("No audio tracks") { }
                    .disabled(true)
            } else {
                ForEach(model.audioTracks) { track in
                    Button {
                        model.selectAudioTrack(index: track.id)
                    } label: {
                        HStack {
                            Text(track.name)

                            if track.id == model.currentAudioTrackIndex {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.55))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
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

    /// Top padding used to keep VLC controls below the navigation bar.
    ///
    /// VLC controls are rendered inside the viewer content, while the UIKit
    /// navigation bar can still be visible above them. This extra inset prevents
    /// the top bar from overlapping the navigation area.
    private var topPadding: CGFloat {
        let windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }

        let window = windowScene?.windows.first { $0.isKeyWindow }
        let safeTop = window?.safeAreaInsets.top ?? 0

        return safeTop + 64
    }

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
