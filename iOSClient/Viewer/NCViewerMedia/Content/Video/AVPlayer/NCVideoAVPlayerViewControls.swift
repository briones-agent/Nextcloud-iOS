// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
import AVKit
import NextcloudKit

// MARK: - Controls Visibility

extension NCVideoAVPlayerViewController {
    /// Handles single taps by toggling the shared AVPlayer controls.
    ///
    /// - Parameter gesture: Source tap gesture recognizer.
    @objc
    func handleSingleTap(_ gesture: UITapGestureRecognizer) {
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

    /// Shows the shared AVPlayer controls.
    ///
    /// - Parameter animated: Whether the visibility change should be animated.
    func showControls(animated: Bool) {
        setControlsVisible(true, animated: animated)
    }

    /// Hides the shared AVPlayer controls.
    ///
    /// - Parameter animated: Whether the visibility change should be animated.
    func hideControls(animated: Bool) {
        stopControlsHideTimer()
        setControlsVisible(false, animated: animated)
    }

    /// Applies the current controls visibility state to the shared controls view.
    ///
    /// - Parameters:
    ///   - visible: Whether controls should be visible.
    ///   - animated: Whether the visibility change should be animated.
    func setControlsVisible(_ visible: Bool, animated: Bool) {
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

    /// Schedules automatic hiding for the shared AVPlayer controls.
    func scheduleControlsHide() {
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

    /// Stops the automatic controls hide timer.
    func stopControlsHideTimer() {
        controlsHideTimer?.invalidate()
        controlsHideTimer = nil
    }
}

// MARK: - Playback Controls

extension NCVideoAVPlayerViewController {
    /// Resets playback to the beginning when the current AVPlayer item ends.
    func handlePlaybackDidEnd() {
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
                guard let self else {
                    return
                }

                self.updateProgressControls()
                self.updatePlayPauseButton()

                guard !NCVideoAVPlayerPictureInPictureManager.shared.isActive else {
                    return
                }

                self.showControls(animated: true)
            }
        }
    }

    /// Toggles AVPlayer playback.
    func togglePlayPause() {
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

    /// Seeks by a relative number of seconds.
    ///
    /// - Parameter seconds: Relative seek offset in seconds.
    func seek(by seconds: Double) {
        let currentSeconds = player.currentTime().seconds

        guard currentSeconds.isFinite else {
            return
        }

        seek(to: currentSeconds + seconds)
    }

    /// Seeks to an absolute playback time.
    ///
    /// - Parameter seconds: Absolute target time in seconds.
    func seek(to seconds: Double) {
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
}

// MARK: - Progress

extension NCVideoAVPlayerViewController {
    /// Updates the shared play/pause button from the current AVPlayer state.
    func updatePlayPauseButton() {
        controlsView.updatePlayPauseButton(isPlaying: player.timeControlStatus == .playing)
    }

    /// Updates slider and time labels from the current AVPlayer playback position.
    func updateProgressControls() {
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

    /// Updates elapsed and remaining labels while scrubbing.
    ///
    /// - Parameter progress: Normalized playback progress between 0 and 1.
    func updateProgressLabels(progress: Float) {
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

    /// Returns the current AVPlayer item duration in seconds.
    ///
    /// `AVAsset.duration` is deprecated on modern iOS versions, so controls rely only
    /// on the current item's loaded duration. When the duration is not available yet,
    /// the controls temporarily report zero.
    ///
    /// - Returns: Duration in seconds, or zero when unavailable.
    func currentDurationSeconds() -> Double {
        guard let duration = player.currentItem?.duration.seconds,
              duration.isFinite,
              duration > 0 else {
            return 0
        }

        return duration
    }

    /// Formats seconds as a compact playback time.
    ///
    /// - Parameter seconds: Time value in seconds.
    /// - Returns: Formatted time string.
    func formatPlaybackTime(seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Returns whether a point is inside one of the visible controls areas.
    ///
    /// - Parameter location: Point in this controller's root view coordinate space.
    /// - Returns: True when the point is inside top action, center, or bottom controls.
    func controlsHitFramesContain(_ location: CGPoint) -> Bool {
        let topActionsFrame = controlsView.topActionsView.convert(
            controlsView.topActionsView.bounds,
            to: view
        )
        let centerControlsFrame = controlsView.centerControlsView.convert(
            controlsView.centerControlsView.bounds,
            to: view
        )
        let bottomControlsFrame = controlsView.bottomControlsView.convert(
            controlsView.bottomControlsView.bounds,
            to: view
        )

        return topActionsFrame.contains(location)
            || centerControlsFrame.contains(location)
            || bottomControlsFrame.contains(location)
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
