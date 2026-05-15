// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AVKit
import NextcloudKit

// MARK: - AVFoundation Video Player Content View

/// SwiftUI wrapper around a UIKit AVFoundation video controller.
///
/// This view renders a controller-owned `AVPlayerViewController`, but uses the
/// shared `NCVideoControlsView` instead of the native AVPlayerViewController controls.
/// It does not own or stop playback resources, because SwiftUI can dismantle
/// and recreate the view controller during rotation or layout rebuilds.
struct NCVideoAVPlayerContentView: UIViewControllerRepresentable {
    let player: AVPlayer
    let allowsPictureInPicture: Bool
    let shouldAutoPlay: Bool

    init(
        player: AVPlayer,
        allowsPictureInPicture: Bool = true,
        shouldAutoPlay: Bool = false
    ) {
        self.player = player
        self.allowsPictureInPicture = allowsPictureInPicture
        self.shouldAutoPlay = shouldAutoPlay
    }

    func makeUIViewController(context: Context) -> NCVideoAVPlayerViewController {
        let controller = NCVideoAVPlayerViewController(
            player: player,
            allowsPictureInPicture: allowsPictureInPicture,
            shouldAutoPlay: shouldAutoPlay
        )

        return controller
    }

    func updateUIViewController(
        _ controller: NCVideoAVPlayerViewController,
        context: Context
    ) {
        controller.update(
            player: player,
            allowsPictureInPicture: allowsPictureInPicture,
            shouldAutoPlay: shouldAutoPlay
        )
    }

    static func dismantleUIViewController(
        _ controller: NCVideoAVPlayerViewController,
        coordinator: Coordinator
    ) {
        // Do not pause or clear the player here.
        // SwiftUI can dismantle this controller during rotation while playback is still valid.
        controller.detachForSwiftUIDismantle()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {}
}

// MARK: - AVFoundation Video Player Controller

/// UIKit container for AVFoundation video playback.
///
/// The controller embeds `AVPlayerViewController` as the renderer and overlays
/// `NCVideoControlsView` so AVFoundation and VLC can share the same controls UI.
final class NCVideoAVPlayerViewController: UIViewController {

    // MARK: - Input

    private var player: AVPlayer
    private var allowsPictureInPicture: Bool
    private var shouldAutoPlay: Bool

    // MARK: - Views

    private let playerViewController = AVPlayerViewController()
    private let controlsView = NCVideoControlsView()

    // MARK: - State

    private var timeObserver: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var playbackEndObserver: NSObjectProtocol?
    private var controlsHideTimer: Timer?
    private var isScrubbing = false
    private var controlsVisible = false
    private var didAutoplay = false

    private static var autoplayedPlayerIDs = Set<ObjectIdentifier>()

    // MARK: - Init

    init(
        player: AVPlayer,
        allowsPictureInPicture: Bool,
        shouldAutoPlay: Bool
    ) {
        self.player = player
        self.allowsPictureInPicture = allowsPictureInPicture
        self.shouldAutoPlay = shouldAutoPlay

        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        cleanupObservers()
        stopControlsHideTimer()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        configureView()
        configurePlayerViewController()
        configureControlsView()
        configureTapGesture()
        configureObservers()
        updateProgressControls()
        updatePlayPauseButton()
        playIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        playerViewController.view.frame = view.bounds
    }

    // MARK: - Public API

    /// Updates the embedded AVPlayer configuration.
    ///
    /// - Parameters:
    ///   - player: Current shared AVPlayer.
    ///   - allowsPictureInPicture: Whether the native controller may support PiP.
    ///   - shouldAutoPlay: Whether this update requests autoplay.
    func update(
        player: AVPlayer,
        allowsPictureInPicture: Bool,
        shouldAutoPlay: Bool
    ) {
        let playerChanged = self.player !== player

        self.allowsPictureInPicture = allowsPictureInPicture
        self.shouldAutoPlay = shouldAutoPlay

        if playerChanged {
            cleanupObservers()
            didAutoplay = false
            self.player = player
            playerViewController.player = player
            configureObservers()
        }

        configurePlayerViewController()
        updateProgressControls()
        updatePlayPauseButton()
        playIfNeeded()
    }

    /// Detaches UIKit delegates and observers during SwiftUI dismantle.
    func detachForSwiftUIDismantle() {
        playerViewController.delegate = nil
        cleanupObservers()
        stopControlsHideTimer()
    }

    // MARK: - Configuration

    private func configureView() {
        view.backgroundColor = .black
        view.clipsToBounds = true
    }

    private func configurePlayerViewController() {
        playerViewController.player = player
        playerViewController.showsPlaybackControls = false
        playerViewController.allowsPictureInPicturePlayback = allowsPictureInPicture
        playerViewController.canStartPictureInPictureAutomaticallyFromInline = false
        playerViewController.requiresLinearPlayback = false
        playerViewController.videoGravity = .resizeAspect
        playerViewController.view.backgroundColor = .black
        playerViewController.delegate = self

        if playerViewController.parent == nil {
            addChild(playerViewController)
            view.addSubview(playerViewController.view)
            playerViewController.view.frame = view.bounds
            playerViewController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            playerViewController.didMove(toParent: self)
        }
    }

    private func configureControlsView() {
        controlsView.delegate = self
        controlsView.alpha = 0
        controlsView.isHidden = true
        controlsView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(controlsView)

        NSLayoutConstraint.activate([
            controlsView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controlsView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controlsView.topAnchor.constraint(equalTo: view.topAnchor),
            controlsView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureTapGesture() {
        let tapGesture = UITapGestureRecognizer(
            target: self,
            action: #selector(handleSingleTap(_:))
        )
        tapGesture.numberOfTapsRequired = 1
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = self
        view.addGestureRecognizer(tapGesture)
    }

    private func configureObservers() {
        timeControlStatusObservation = player.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            Task { @MainActor in
                self?.updatePlayPauseButton()
            }
        }

        itemStatusObservation = player.currentItem?.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            Task { @MainActor in
                self?.handleCurrentItemStatusChange()
            }
        }

        if let currentItem = player.currentItem {
            playbackEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: currentItem,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.handlePlaybackDidEnd()
                }
            }
        }

        let interval = CMTime(
            seconds: 0.5,
            preferredTimescale: CMTimeScale(NSEC_PER_SEC)
        )

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] _ in
            self?.updateProgressControls()
        }
    }

    private func cleanupObservers() {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil

        timeControlStatusObservation?.invalidate()
        timeControlStatusObservation = nil

        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
            self.playbackEndObserver = nil
        }

        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    // MARK: - Controls Visibility

    @objc
    private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: view)

        if controlsVisible {
            guard !controlsHitFramesContain(location) else {
                return
            }

            hideControls(animated: true)
        } else {
            showControls(animated: true)
            scheduleControlsHide()
        }
    }

    private func showControls(animated: Bool) {
        setControlsVisible(true, animated: animated)
    }

    private func hideControls(animated: Bool) {
        stopControlsHideTimer()
        setControlsVisible(false, animated: animated)
    }

    private func setControlsVisible(_ visible: Bool, animated: Bool) {
        controlsVisible = visible

        let changes = {
            self.controlsView.alpha = visible ? 1 : 0
        }

        let completion: (Bool) -> Void = { _ in
            self.controlsView.isHidden = !visible
        }

        if visible {
            controlsView.isHidden = false
        }

        guard animated else {
            changes()
            completion(true)
            return
        }

        UIView.animate(
            withDuration: 0.18,
            animations: changes,
            completion: completion
        )
    }

    private func scheduleControlsHide() {
        stopControlsHideTimer()

        controlsHideTimer = Timer.scheduledTimer(
            withTimeInterval: 4,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.hideControls(animated: true)
            }
        }
    }

    private func stopControlsHideTimer() {
        controlsHideTimer?.invalidate()
        controlsHideTimer = nil
    }

    // MARK: - Playback

    private func playIfNeeded() {
        let playerIdentifier = ObjectIdentifier(player)

        guard shouldAutoPlay,
              !didAutoplay,
              !Self.autoplayedPlayerIDs.contains(playerIdentifier) else {
            return
        }

        didAutoplay = true
        Self.autoplayedPlayerIDs.insert(playerIdentifier)

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.player.timeControlStatus != .playing else {
                return
            }

            self.player.play()

            nkLog(
                tag: NCGlobal.shared.logTagViewer,
                emoji: .debug,
                message: "VIDEO AVPlayer autoplay",
                consoleOnly: true
            )
        }
    }

    private func handleCurrentItemStatusChange() {
        updateProgressControls()
        updatePlayPauseButton()

        guard player.currentItem?.status == .readyToPlay else {
            return
        }

        showControls(animated: false)
    }

    private func handlePlaybackDidEnd() {
        player.pause()
        stopControlsHideTimer()

        let startTime = CMTime(
            seconds: 0,
            preferredTimescale: 600
        )

        player.seek(
            to: startTime,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateProgressControls()
                self?.updatePlayPauseButton()
                self?.showControls(animated: true)
            }
        }
    }

    private func togglePlayPause() {
        switch player.timeControlStatus {
        case .playing:
            player.pause()

        case .paused,
             .waitingToPlayAtSpecifiedRate:
            player.play()

        @unknown default:
            player.play()
        }

        updatePlayPauseButton()
        scheduleControlsHide()
    }

    private func seek(by seconds: Double) {
        let currentSeconds = player.currentTime().seconds

        guard currentSeconds.isFinite else {
            return
        }

        seek(to: currentSeconds + seconds)
    }

    private func seek(to seconds: Double) {
        let duration = currentDurationSeconds()
        let boundedSeconds: Double

        if duration > 0 {
            boundedSeconds = max(0, min(duration, seconds))
        } else {
            boundedSeconds = max(0, seconds)
        }

        let targetTime = CMTime(
            seconds: boundedSeconds,
            preferredTimescale: 600
        )

        player.seek(
            to: targetTime,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateProgressControls()
            }
        }
    }

    // MARK: - Progress

    private func updatePlayPauseButton() {
        controlsView.updatePlayPauseButton(isPlaying: player.timeControlStatus == .playing)
    }

    private func updateProgressControls() {
        guard !isScrubbing else {
            return
        }

        let currentSeconds = player.currentTime().seconds
        let durationSeconds = currentDurationSeconds()

        guard currentSeconds.isFinite,
              durationSeconds.isFinite,
              durationSeconds > 0 else {
            controlsView.updateProgress(
                progress: 0,
                elapsedText: "0:00",
                remainingText: "−0:00"
            )
            return
        }

        let progress = Float(max(0, min(1, currentSeconds / durationSeconds)))
        let remainingSeconds = max(0, durationSeconds - currentSeconds)

        controlsView.updateProgress(
            progress: progress,
            elapsedText: formatPlaybackTime(seconds: currentSeconds),
            remainingText: "−" + formatPlaybackTime(seconds: remainingSeconds)
        )
    }

    private func updateProgressLabels(progress: Float) {
        let durationSeconds = currentDurationSeconds()

        guard durationSeconds.isFinite,
              durationSeconds > 0 else {
            controlsView.updateProgress(
                progress: progress,
                elapsedText: "0:00",
                remainingText: "−0:00"
            )
            return
        }

        let elapsedSeconds = durationSeconds * Double(progress)
        let remainingSeconds = max(0, durationSeconds - elapsedSeconds)

        controlsView.updateProgress(
            progress: progress,
            elapsedText: formatPlaybackTime(seconds: elapsedSeconds),
            remainingText: "−" + formatPlaybackTime(seconds: remainingSeconds)
        )
    }

    private func currentDurationSeconds() -> Double {
        if let duration = player.currentItem?.duration.seconds,
           duration.isFinite,
           duration > 0 {
            return duration
        }

        let duration = player.currentItem?.asset.duration.seconds ?? 0
        return duration.isFinite ? duration : 0
    }

    private func formatPlaybackTime(seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%d:%02d", minutes, seconds)
    }

    private func controlsHitFramesContain(_ location: CGPoint) -> Bool {
        let centerControlsFrame = controlsView.centerControlsView.convert(
            controlsView.centerControlsView.bounds,
            to: view
        )
        let bottomControlsFrame = controlsView.bottomControlsView.convert(
            controlsView.bottomControlsView.bounds,
            to: view
        )

        return centerControlsFrame.contains(location) || bottomControlsFrame.contains(location)
    }
}

// MARK: - Shared Controls Delegate

extension NCVideoAVPlayerViewController: NCVideoControlsViewDelegate {
    /// Handles the shared controls backward seek action.
    ///
    /// - Parameter controlsView: Shared controls view that emitted the action.
    func videoControlsDidTapSeekBackward(_ controlsView: NCVideoControlsView) {
        seek(by: -10)
    }

    /// Handles the shared controls play/pause action.
    ///
    /// - Parameter controlsView: Shared controls view that emitted the action.
    func videoControlsDidTapPlayPause(_ controlsView: NCVideoControlsView) {
        togglePlayPause()
    }

    /// Handles the shared controls forward seek action.
    ///
    /// - Parameter controlsView: Shared controls view that emitted the action.
    func videoControlsDidTapSeekForward(_ controlsView: NCVideoControlsView) {
        seek(by: 10)
    }

    /// Handles the beginning of slider scrubbing from the shared controls view.
    ///
    /// - Parameter controlsView: Shared controls view that emitted the action.
    func videoControlsDidBeginScrubbing(_ controlsView: NCVideoControlsView) {
        showControls(animated: true)
        stopControlsHideTimer()
        isScrubbing = true
    }

    /// Updates AVFoundation time labels while scrubbing from the shared controls view.
    ///
    /// - Parameters:
    ///   - controlsView: Shared controls view that emitted the action.
    ///   - progress: Normalized target progress between 0 and 1.
    func videoControls(_ controlsView: NCVideoControlsView, didScrubTo progress: Float) {
        updateProgressLabels(progress: progress)
    }

    /// Applies the selected AVFoundation playback position after scrubbing ends.
    ///
    /// - Parameters:
    ///   - controlsView: Shared controls view that emitted the action.
    ///   - progress: Normalized target progress between 0 and 1.
    func videoControlsDidEndScrubbing(_ controlsView: NCVideoControlsView, progress: Float) {
        isScrubbing = false
        seek(to: currentDurationSeconds() * Double(progress))
        updateProgressControls()
        scheduleControlsHide()
    }
}

// MARK: - Gesture Delegate

extension NCVideoAVPlayerViewController: UIGestureRecognizerDelegate {
    /// Allows tap gestures to coexist with the embedded AVPlayerViewController.
    ///
    /// - Parameters:
    ///   - gestureRecognizer: Gesture recognizer asking for simultaneous recognition.
    ///   - otherGestureRecognizer: Other gesture recognizer involved in the decision.
    /// - Returns: True to avoid AVPlayerViewController touch handling from suppressing controls.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    /// Prevents the background tap recognizer from stealing touches that begin on controls.
    ///
    /// - Parameters:
    ///   - gestureRecognizer: Gesture recognizer asking whether it should receive the touch.
    ///   - touch: Source touch.
    /// - Returns: False for visible playback controls, true otherwise.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        guard controlsVisible else {
            return true
        }

        let location = touch.location(in: view)

        if controlsHitFramesContain(location) {
            return false
        }

        return true
    }
}

// MARK: - AVPlayerViewController Delegate

extension NCVideoAVPlayerViewController: AVPlayerViewControllerDelegate {
    func playerViewControllerWillStartPictureInPicture(
        _ playerViewController: AVPlayerViewController
    ) {
        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: .debug,
            message: "VIDEO PiP will start",
            consoleOnly: true
        )
    }

    func playerViewControllerDidStartPictureInPicture(
        _ playerViewController: AVPlayerViewController
    ) {
        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: .debug,
            message: "VIDEO PiP did start",
            consoleOnly: true
        )
    }

    func playerViewControllerWillStopPictureInPicture(
        _ playerViewController: AVPlayerViewController
    ) {
        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: .debug,
            message: "VIDEO PiP will stop",
            consoleOnly: true
        )
    }

    func playerViewControllerDidStopPictureInPicture(
        _ playerViewController: AVPlayerViewController
    ) {
        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: .debug,
            message: "VIDEO PiP did stop",
            consoleOnly: true
        )
    }
}
