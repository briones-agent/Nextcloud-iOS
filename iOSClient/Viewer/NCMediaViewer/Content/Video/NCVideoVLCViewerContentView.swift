// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MobileVLCKit
import NextcloudKit
import UIKit
import SwiftUI

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

/// Displays the singleton VLC player with SwiftUI controls.
///
/// This view does not own playback. It only renders the VLC drawable and controls.
struct NCVideoVLCViewerContentView: View {
    @ObservedObject var controller: NCVideoVLCPlayerController

    let displayFileName: String

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            NCVideoVLCRenderView(controller: controller)
                .ignoresSafeArea()
                .zIndex(0)

            if !controller.isControlsVisible {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .zIndex(1)
                    .onTapGesture {
                        controller.showControls()
                    }
            }

            if controller.isControlsVisible {
                NCVideoVLCControlsView(
                    controller: controller,
                    displayFileName: displayFileName,
                    onBackgroundTap: {
                        controller.toggleControls()
                    }
                )
                .transition(.opacity)
                .zIndex(2)
            }
        }
        .background(Color.black)
        .animation(.easeInOut(duration: 0.18), value: controller.isControlsVisible)
    }
}

// MARK: - VLC Render View

/// UIKit render surface used by the shared VLC playback controller.
///
/// This view only provides a drawable surface for VLC.
/// It does not own playback, does not stop playback, and does not detach the
/// drawable during dismantle because SwiftUI can dismantle views during rotation.
struct NCVideoVLCRenderView: UIViewRepresentable {
    let controller: NCVideoVLCPlayerController

    func makeUIView(context: Context) -> NCVideoVLCDrawableView {
        let view = NCVideoVLCDrawableView()
        view.backgroundColor = .black
        view.clipsToBounds = true

        view.onDrawableReady = { [weak controller] drawableView, force in
            controller?.attachDrawable(
                drawableView,
                force: force
            )
        }

        controller.attachDrawable(
            view,
            force: true
        )

        return view
    }

    func updateUIView(
        _ view: NCVideoVLCDrawableView,
        context: Context
    ) {
        controller.attachDrawable(
            view,
            force: false
        )

        DispatchQueue.main.async { [weak controller, weak view] in
            guard let view else {
                return
            }

            controller?.attachDrawable(
                view,
                force: true
            )
        }
    }

    static func dismantleUIView(
        _ view: NCVideoVLCDrawableView,
        coordinator: Coordinator
    ) {
        // Do not stop VLC here.
        // Do not detach the drawable here.
        // SwiftUI can call dismantle during rotation/layout rebuilds while
        // playback is still valid.
        view.onDrawableReady = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator { }
}

// MARK: - VLC Drawable View

/// UIView used as VLC drawable target.
///
/// VLC can keep playing audio while losing its video surface after rotation.
/// This view force-rebinds the drawable when it enters a window and whenever
/// its bounds become valid after layout.
final class NCVideoVLCDrawableView: UIView {
    var onDrawableReady: ((_ view: NCVideoVLCDrawableView, _ force: Bool) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()

        guard window != nil else {
            return
        }

        requestDrawableAttach(force: true)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        guard bounds.width > 0,
              bounds.height > 0 else {
            return
        }

        requestDrawableAttach(force: true)
    }

    private func requestDrawableAttach(force: Bool) {
        onDrawableReady?(self, force)

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.window != nil,
                  self.bounds.width > 0,
                  self.bounds.height > 0 else {
                return
            }

            self.onDrawableReady?(self, true)
        }
    }
}

// MARK: - VLC Controls View

/// SwiftUI controls overlay for VLC playback.
///
/// This view does not own the VLC player. It only sends control commands to the
/// singleton VLC playback controller.
struct NCVideoVLCControlsView: View {
    @ObservedObject var controller: NCVideoVLCPlayerController

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

            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
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
            if controller.subtitleTracks.isEmpty {
                Button("No subtitles") { }
                    .disabled(true)
            } else {
                ForEach(controller.subtitleTracks) { track in
                    Button {
                        controller.selectSubtitleTrack(index: track.id)
                    } label: {
                        HStack {
                            Text(track.name)

                            if track.id == controller.currentSubtitleTrackIndex {
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
            if controller.audioTracks.isEmpty {
                Button("No audio tracks") { }
                    .disabled(true)
            } else {
                ForEach(controller.audioTracks) { track in
                    Button {
                        controller.selectAudioTrack(index: track.id)
                    } label: {
                        HStack {
                            Text(track.name)

                            if track.id == controller.currentAudioTrackIndex {
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
                controller.skip(by: -15)
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 36, weight: .regular))
            }
            .buttonStyle(.plain)

            Button {
                controller.togglePlayback()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 72, weight: .regular))
            }
            .buttonStyle(.plain)

            Button {
                controller.skip(by: 15)
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
                    get: { controller.currentTime },
                    set: { controller.currentTime = $0 }
                ),
                in: 0...max(controller.duration, 1),
                onEditingChanged: { isEditing in
                    controller.showControls()

                    if !isEditing {
                        controller.seek(to: controller.currentTime)
                    }
                }
            )
            .disabled(controller.duration <= 0)

            HStack {
                Text(formatTime(controller.currentTime))

                Spacer()

                Text(formatTime(controller.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.75))
        }
    }

    // MARK: - Helpers

    /// Top padding used to keep VLC controls below the navigation bar.
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

// MARK: - VLC Player Controller

/// Singleton VLC playback controller.
///
/// This object owns the only `VLCMediaPlayer` used by the media viewer.
/// SwiftUI views can be recreated during rotation or layout updates, but the
/// VLC player remains stable and only receives a new drawable surface.
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
    private var monitorTask: Task<Void, Never>?
    private var controlsHideTask: Task<Void, Never>?
    private var trackRefreshTask: Task<Void, Never>?

    private init() { }

    // MARK: - Public API

    /// Attaches the current VLC drawable view.
    ///
    /// This method can be called repeatedly after rotation or layout changes.
    /// VLC can keep audio alive while losing the video output surface, so when
    /// `force` is true the drawable is rebound even if it appears to be the same view.
    ///
    /// - Parameters:
    ///   - view: UIView used as VLC drawable target.
    ///   - force: Whether the drawable should be rebound even if it is already attached.
    @MainActor
    func attachDrawable(
        _ view: UIView,
        force: Bool = false
    ) {
        guard view.window != nil,
              view.bounds.width > 0,
              view.bounds.height > 0 else {
            return
        }

        let currentDrawable = mediaPlayer.drawable as? UIView

        if !force,
           currentDrawable === view {
            return
        }

        let wasPlaying = mediaPlayer.isPlaying

        mediaPlayer.drawable = nil
        mediaPlayer.drawable = view

        if wasPlaying {
            mediaPlayer.play()
        }

        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: .debug,
            message: "VIDEO VLC drawable attached force \(force), bounds \(view.bounds)",
            consoleOnly: true
        )
    }

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

    /// Stops playback and releases VLC resources.
    ///
    /// This is called only by the global video playback controller when playback
    /// really has to stop. It should not be called by SwiftUI view teardown.
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
