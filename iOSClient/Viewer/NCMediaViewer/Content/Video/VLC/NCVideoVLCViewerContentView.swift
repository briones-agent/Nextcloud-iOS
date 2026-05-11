// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import SwiftUI
import UIKit
import MobileVLCKit
import NextcloudKit

// MARK: - VLC Video Viewer Content View

/// Hosts a stable UIKit VLC viewer controller inside SwiftUI.
///
/// The UIKit controller is stored inside a `StateObject` so SwiftUI rotation and
/// layout rebuilds do not recreate the VLC player/controller.
struct NCVideoVLCViewerContentView: View {
    let metadata: tableMetadata
    let url: URL
    let userAgent: String?
    let shouldAutoPlay: Bool

    @StateObject private var store: NCVideoVLCControllerStore

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

        _store = StateObject(
            wrappedValue: NCVideoVLCControllerStore(
                metadata: metadata,
                url: url,
                userAgent: userAgent,
                shouldAutoPlay: shouldAutoPlay
            )
        )
    }

    var body: some View {
        NCVideoVLCLegacyFullHostView(
            viewController: store.viewController,
            metadata: metadata,
            url: url,
            userAgent: userAgent,
            shouldAutoPlay: shouldAutoPlay
        )
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: .ncMediaViewerStopPlayback)) { _ in
            store.viewController.stop()
        }
    }
}

// MARK: - VLC Controller Store

/// Stores the UIKit VLC controller across SwiftUI rebuilds.
///
/// This prevents SwiftUI rotation from creating a second VLC controller and
/// restarting playback.
@MainActor
final class NCVideoVLCControllerStore: ObservableObject {
    let viewController: NCVideoVLCLegacyFullViewController

    init(
        metadata: tableMetadata,
        url: URL,
        userAgent: String?,
        shouldAutoPlay: Bool
    ) {
        self.viewController = NCVideoVLCLegacyFullViewController(
            metadata: metadata,
            url: url,
            userAgent: userAgent,
            shouldAutoPlay: shouldAutoPlay
        )
    }

    deinit {
        viewController.stop()
    }
}

// MARK: - VLC Legacy Full Host View

/// SwiftUI wrapper for an already-created UIKit VLC controller.
///
/// The real controller lifetime is owned by `NCVideoVLCControllerStore`.
struct NCVideoVLCLegacyFullHostView: UIViewControllerRepresentable {
    let viewController: NCVideoVLCLegacyFullViewController
    let metadata: tableMetadata
    let url: URL
    let userAgent: String?
    let shouldAutoPlay: Bool

    func makeUIViewController(context: Context) -> NCVideoVLCLegacyFullViewController {
        viewController
    }

    func updateUIViewController(
        _ viewController: NCVideoVLCLegacyFullViewController,
        context: Context
    ) {
        viewController.update(
            metadata: metadata,
            url: url,
            userAgent: userAgent,
            shouldAutoPlay: shouldAutoPlay
        )
    }

    static func dismantleUIViewController(
        _ viewController: NCVideoVLCLegacyFullViewController,
        coordinator: Coordinator
    ) {
        // Do not stop here.
        // SwiftUI can dismantle during rotation/layout rebuilds.
        // The StateObject store owns the real controller lifetime.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator { }
}

// MARK: - VLC Legacy Full View Controller

/// UIKit-only VLC viewer controller.
///
/// This mirrors the legacy media viewer behavior:
/// - a stable `UIImageView` is used as VLC drawable
/// - `player.drawable` is assigned only when needed
/// - rotation only updates UIKit layout
/// - controls are UIKit views, not SwiftUI overlays
final class NCVideoVLCLegacyFullViewController: UIViewController {

    // MARK: - Input

    private var metadata: tableMetadata
    private var url: URL
    private var userAgent: String?
    private var shouldAutoPlay: Bool

    // MARK: - Views

    private let imageVideoContainer = UIImageView()
    private let controlsContainer = UIView()
    private let titleLabel = UILabel()
    private let playPauseButton = UIButton(type: .system)
    private let backwardButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let slider = UISlider()
    private let currentTimeLabel = UILabel()
    private let durationLabel = UILabel()
    private let audioButton = UIButton(type: .system)
    private let subtitleButton = UIButton(type: .system)

    // MARK: - VLC

    private let mediaPlayer = VLCMediaPlayer()

    // MARK: - State

    private var currentURL: URL?
    private var monitorTask: Task<Void, Never>?
    private var controlsHideTask: Task<Void, Never>?
    private var trackRefreshTask: Task<Void, Never>?
    private var isSliderEditing = false
    private var controlsVisible = true

    // MARK: - Init

    init(
        metadata: tableMetadata,
        url: URL,
        userAgent: String?,
        shouldAutoPlay: Bool
    ) {
        self.metadata = metadata
        self.url = url
        self.userAgent = userAgent
        self.shouldAutoPlay = shouldAutoPlay

        super.init(
            nibName: nil,
            bundle: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    override func loadView() {
        let rootView = UIView()
        rootView.backgroundColor = .black
        rootView.isOpaque = true
        rootView.clipsToBounds = true

        imageVideoContainer.backgroundColor = .black
        imageVideoContainer.contentMode = .scaleAspectFit
        imageVideoContainer.clipsToBounds = true
        imageVideoContainer.isOpaque = true
        imageVideoContainer.translatesAutoresizingMaskIntoConstraints = false

        rootView.addSubview(imageVideoContainer)

        NSLayoutConstraint.activate([
            imageVideoContainer.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            imageVideoContainer.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            imageVideoContainer.topAnchor.constraint(equalTo: rootView.topAnchor),
            imageVideoContainer.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])

        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        configureAudioSession()
        setupGesture()
        setupControls()
        loadVideoIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        attachDrawableIfNeeded()

        if shouldAutoPlay {
            play()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // Rotation should only update UIKit layout.
        // Do not detach, force-rebind, or reload VLC here.
        attachDrawableIfNeeded()
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(
            to: size,
            with: coordinator
        )

        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.view.layoutIfNeeded()
        }, completion: { [weak self] _ in
            self?.attachDrawableIfNeeded()
        })
    }

    // MARK: - Public

    /// Updates the controller input.
    ///
    /// If the URL changes, the media is reloaded. Otherwise the existing VLC
    /// player is reused.
    func update(
        metadata: tableMetadata,
        url: URL,
        userAgent: String?,
        shouldAutoPlay: Bool
    ) {
        self.metadata = metadata
        self.userAgent = userAgent
        self.shouldAutoPlay = shouldAutoPlay

        guard self.url != url else {
            attachDrawableIfNeeded()
            updateTitle()

            if shouldAutoPlay,
               !mediaPlayer.isPlaying {
                play()
            }

            return
        }

        self.url = url
        stop()
        loadVideoIfNeeded()

        if shouldAutoPlay {
            play()
        }
    }

    /// Stops playback and releases VLC resources.
    func stop() {
        monitorTask?.cancel()
        monitorTask = nil

        controlsHideTask?.cancel()
        controlsHideTask = nil

        trackRefreshTask?.cancel()
        trackRefreshTask = nil

        mediaPlayer.stop()
        mediaPlayer.media = nil
        mediaPlayer.drawable = nil

        currentURL = nil
        isSliderEditing = false

        updatePlaybackUI()
    }

    // MARK: - Setup

    private func setupGesture() {
        let tapGesture = UITapGestureRecognizer(
            target: self,
            action: #selector(toggleControlsTapped)
        )

        view.addGestureRecognizer(tapGesture)
    }

    private func setupControls() {
        controlsContainer.backgroundColor = .clear
        controlsContainer.translatesAutoresizingMaskIntoConstraints = false
        controlsContainer.alpha = 1

        view.addSubview(controlsContainer)

        let contentView = controlsContainer

        titleLabel.textColor = .white
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.numberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        backwardButton.setImage(
            UIImage(systemName: "gobackward.15"),
            for: .normal
        )
        backwardButton.tintColor = .white
        backwardButton.translatesAutoresizingMaskIntoConstraints = false
        backwardButton.addTarget(
            self,
            action: #selector(backwardTapped),
            for: .touchUpInside
        )

        playPauseButton.setImage(
            UIImage(systemName: "play.circle.fill"),
            for: .normal
        )
        playPauseButton.tintColor = .white
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.addTarget(
            self,
            action: #selector(playPauseTapped),
            for: .touchUpInside
        )

        forwardButton.setImage(
            UIImage(systemName: "goforward.15"),
            for: .normal
        )
        forwardButton.tintColor = .white
        forwardButton.translatesAutoresizingMaskIntoConstraints = false
        forwardButton.addTarget(
            self,
            action: #selector(forwardTapped),
            for: .touchUpInside
        )

        audioButton.setImage(
            UIImage(systemName: "waveform.circle.fill"),
            for: .normal
        )
        audioButton.tintColor = .white
        audioButton.translatesAutoresizingMaskIntoConstraints = false

        subtitleButton.setImage(
            UIImage(systemName: "captions.bubble.fill"),
            for: .normal
        )
        subtitleButton.tintColor = .white
        subtitleButton.translatesAutoresizingMaskIntoConstraints = false

        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.addTarget(
            self,
            action: #selector(sliderTouchDown),
            for: .touchDown
        )
        slider.addTarget(
            self,
            action: #selector(sliderValueChanged),
            for: .valueChanged
        )
        slider.addTarget(
            self,
            action: #selector(sliderTouchEnded),
            for: [.touchUpInside, .touchUpOutside, .touchCancel]
        )

        currentTimeLabel.textColor = .white.withAlphaComponent(0.75)
        currentTimeLabel.font = .monospacedDigitSystemFont(
            ofSize: 12,
            weight: .regular
        )
        currentTimeLabel.text = "00:00"
        currentTimeLabel.translatesAutoresizingMaskIntoConstraints = false

        durationLabel.textColor = .white.withAlphaComponent(0.75)
        durationLabel.font = .monospacedDigitSystemFont(
            ofSize: 12,
            weight: .regular
        )
        durationLabel.text = "00:00"
        durationLabel.translatesAutoresizingMaskIntoConstraints = false

        let topStack = UIStackView(arrangedSubviews: [
            titleLabel,
            subtitleButton,
            audioButton
        ])
        topStack.axis = .horizontal
        topStack.alignment = .center
        topStack.spacing = 12
        topStack.translatesAutoresizingMaskIntoConstraints = false

        let centerStack = UIStackView(arrangedSubviews: [
            backwardButton,
            playPauseButton,
            forwardButton
        ])
        centerStack.axis = .horizontal
        centerStack.alignment = .center
        centerStack.distribution = .equalSpacing
        centerStack.spacing = 36
        centerStack.translatesAutoresizingMaskIntoConstraints = false

        let spacer = UIView()

        let timeStack = UIStackView(arrangedSubviews: [
            currentTimeLabel,
            spacer,
            durationLabel
        ])
        timeStack.axis = .horizontal
        timeStack.alignment = .center
        timeStack.spacing = 8
        timeStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(topStack)
        contentView.addSubview(centerStack)
        contentView.addSubview(slider)
        contentView.addSubview(timeStack)

        NSLayoutConstraint.activate([
            controlsContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controlsContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controlsContainer.topAnchor.constraint(equalTo: view.topAnchor),
            controlsContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            topStack.leadingAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.leadingAnchor, constant: 18),
            topStack.trailingAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.trailingAnchor, constant: -18),
            topStack.topAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.topAnchor, constant: 64),

            playPauseButton.widthAnchor.constraint(equalToConstant: 72),
            playPauseButton.heightAnchor.constraint(equalToConstant: 72),
            backwardButton.widthAnchor.constraint(equalToConstant: 44),
            backwardButton.heightAnchor.constraint(equalToConstant: 44),
            forwardButton.widthAnchor.constraint(equalToConstant: 44),
            forwardButton.heightAnchor.constraint(equalToConstant: 44),
            audioButton.widthAnchor.constraint(equalToConstant: 40),
            audioButton.heightAnchor.constraint(equalToConstant: 40),
            subtitleButton.widthAnchor.constraint(equalToConstant: 40),
            subtitleButton.heightAnchor.constraint(equalToConstant: 40),

            centerStack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            centerStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            slider.leadingAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.leadingAnchor, constant: 18),
            slider.trailingAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.trailingAnchor, constant: -18),
            slider.bottomAnchor.constraint(equalTo: timeStack.topAnchor, constant: -8),

            timeStack.leadingAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.leadingAnchor, constant: 18),
            timeStack.trailingAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.trailingAnchor, constant: -18),
            timeStack.bottomAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.bottomAnchor, constant: -18)
        ])

        updateTitle()
        updatePlaybackUI()
    }

    private func updateTitle() {
        if !metadata.fileNameView.isEmpty {
            titleLabel.text = metadata.fileNameView
        } else {
            titleLabel.text = metadata.fileName
        }
    }

    // MARK: - Loading

    private func loadVideoIfNeeded() {
        guard currentURL != url else {
            attachDrawableIfNeeded()
            return
        }

        currentURL = url

        let media = VLCMedia(url: url)

        if let userAgent,
           !userAgent.isEmpty,
           !url.isFileURL {
            media.addOption(":http-user-agent=\(userAgent)")
        }

        mediaPlayer.media = media

        attachDrawableIfNeeded()
        startMonitoring()
        refreshTracksRepeatedly()

        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: .debug,
            message: "VIDEO VLC legacy full load \(metadata.ocId), url \(url.absoluteString)",
            consoleOnly: true
        )
    }

    private func attachDrawableIfNeeded() {
        guard imageVideoContainer.window != nil,
              imageVideoContainer.bounds.width > 0,
              imageVideoContainer.bounds.height > 0 else {
            return
        }

        if let currentDrawable = mediaPlayer.drawable as? UIView,
           currentDrawable === imageVideoContainer {
            return
        }

        mediaPlayer.drawable = imageVideoContainer
    }

    // MARK: - Playback

    private func play() {
        attachDrawableIfNeeded()

        mediaPlayer.play()
        updatePlaybackUI()
        scheduleControlsAutoHide()
    }

    private func pause() {
        mediaPlayer.pause()
        updatePlaybackUI()
        showControls()
    }

    private func togglePlayback() {
        if mediaPlayer.isPlaying {
            pause()
        } else {
            play()
        }
    }

    private func seek(to seconds: Double) {
        let duration = currentDuration

        guard duration > 0 else {
            return
        }

        let clampedSeconds = min(
            max(seconds, 0),
            duration
        )

        let position = Float(clampedSeconds / duration)
        mediaPlayer.position = min(max(position, 0), 1)

        updatePlaybackUI()
        scheduleControlsAutoHide()
    }

    private func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    // MARK: - Controls Actions

    @objc
    private func toggleControlsTapped() {
        setControlsVisible(
            !controlsVisible,
            animated: true
        )
    }

    @objc
    private func playPauseTapped() {
        togglePlayback()
    }

    @objc
    private func backwardTapped() {
        skip(by: -15)
    }

    @objc
    private func forwardTapped() {
        skip(by: 15)
    }

    @objc
    private func sliderTouchDown() {
        isSliderEditing = true
        showControls()
    }

    @objc
    private func sliderValueChanged() {
        guard currentDuration > 0 else {
            return
        }

        let seconds = Double(slider.value) * currentDuration
        currentTimeLabel.text = formatTime(seconds)
    }

    @objc
    private func sliderTouchEnded() {
        isSliderEditing = false

        guard currentDuration > 0 else {
            return
        }

        seek(to: Double(slider.value) * currentDuration)
    }

    // MARK: - Controls Visibility

    private func showControls() {
        setControlsVisible(
            true,
            animated: true
        )
    }

    private func setControlsVisible(
        _ visible: Bool,
        animated: Bool
    ) {
        controlsHideTask?.cancel()
        controlsHideTask = nil

        controlsVisible = visible

        let changes = {
            self.controlsContainer.alpha = visible ? 1 : 0
        }

        if animated {
            UIView.animate(
                withDuration: 0.18,
                animations: changes
            )
        } else {
            changes()
        }

        if visible,
           mediaPlayer.isPlaying {
            scheduleControlsAutoHide()
        }
    }

    private func scheduleControlsAutoHide() {
        controlsHideTask?.cancel()

        guard mediaPlayer.isPlaying else {
            return
        }

        controlsHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))

            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                self?.setControlsVisible(
                    false,
                    animated: true
                )
            }
        }
    }

    // MARK: - Monitoring

    private var currentTime: Double {
        let seconds = Double(mediaPlayer.time.intValue) / 1_000
        return seconds.isFinite ? max(seconds, 0) : 0
    }

    private var currentDuration: Double {
        guard let media = mediaPlayer.media else {
            return 0
        }

        let seconds = Double(media.length.intValue) / 1_000
        return seconds.isFinite ? max(seconds, 0) : 0
    }

    private func startMonitoring() {
        monitorTask?.cancel()

        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))

                await MainActor.run {
                    self?.updatePlaybackUI()
                }
            }
        }
    }

    private func updatePlaybackUI() {
        let isPlaying = mediaPlayer.isPlaying

        playPauseButton.setImage(
            UIImage(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill"),
            for: .normal
        )

        let duration = currentDuration
        let time = currentTime

        if !isSliderEditing {
            if duration > 0 {
                slider.value = Float(time / duration)
            } else {
                slider.value = 0
            }

            currentTimeLabel.text = formatTime(time)
        }

        durationLabel.text = formatTime(duration)
        slider.isEnabled = duration > 0
    }

    // MARK: - Tracks

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
                    self?.setupAudioButton()
                    self?.setupSubtitleButton()
                }
            }
        }
    }

    private func setupAudioButton() {
        let names = readStringArray(mediaPlayer.audioTrackNames)
        let indexes = readInt32Array(mediaPlayer.audioTrackIndexes)

        audioButton.menu = makeTrackMenu(
            titleWhenEmpty: "No audio tracks",
            names: names,
            indexes: indexes,
            currentIndex: mediaPlayer.currentAudioTrackIndex,
            disabledTitle: "Disable",
            fallbackPrefix: "Audio"
        ) { [weak self] index in
            self?.mediaPlayer.currentAudioTrackIndex = index
        }

        audioButton.showsMenuAsPrimaryAction = true
        audioButton.isHidden = indexes.isEmpty
    }

    private func setupSubtitleButton() {
        let names = readStringArray(mediaPlayer.videoSubTitlesNames)
        let indexes = readInt32Array(mediaPlayer.videoSubTitlesIndexes)

        subtitleButton.menu = makeTrackMenu(
            titleWhenEmpty: "No subtitles",
            names: names,
            indexes: indexes,
            currentIndex: mediaPlayer.currentVideoSubTitleIndex,
            disabledTitle: "Disable",
            fallbackPrefix: "Subtitle"
        ) { [weak self] index in
            self?.mediaPlayer.currentVideoSubTitleIndex = index
        }

        subtitleButton.showsMenuAsPrimaryAction = true
        subtitleButton.isHidden = indexes.isEmpty
    }

    private func makeTrackMenu(
        titleWhenEmpty: String,
        names: [String],
        indexes: [Int32],
        currentIndex: Int32,
        disabledTitle: String,
        fallbackPrefix: String,
        selection: @escaping (_ index: Int32) -> Void
    ) -> UIMenu {
        guard !indexes.isEmpty else {
            return UIMenu(
                children: [
                    UIAction(
                        title: titleWhenEmpty,
                        attributes: [.disabled],
                        handler: { _ in }
                    )
                ]
            )
        }

        let actions = indexes.enumerated().map { offset, index in
            UIAction(
                title: trackName(
                    names: names,
                    offset: offset,
                    index: index,
                    fallbackPrefix: fallbackPrefix,
                    disabledTitle: disabledTitle
                ),
                state: index == currentIndex ? .on : .off
            ) { _ in
                selection(index)
            }
        }

        return UIMenu(children: actions)
    }

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

    // MARK: - Helpers

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
                message: "VIDEO VLC audio session error: \(error.localizedDescription)",
                consoleOnly: true
            )
        }
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
