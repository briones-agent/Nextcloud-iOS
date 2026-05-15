import AVFoundation
import UIKit
import MobileVLCKit
import NextcloudKit

// MARK: - Playback Controls

extension NCVideoVLCViewController {
    /// Creates a large center playback control button.
    ///
    /// - Parameters:
    ///   - systemName: SF Symbol name used by the button.
    ///   - pointSize: Symbol point size.
    ///   - side: Button side length.
    ///   - action: Selector invoked when the button is tapped.
    /// - Returns: Configured button.
    func makeCenterControlButton(
        systemName: String,
        pointSize: CGFloat,
        side: CGFloat,
        action: Selector
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.18)
        button.layer.cornerRadius = side / 2
        button.clipsToBounds = true
        button.translatesAutoresizingMaskIntoConstraints = false

        let symbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: pointSize,
            weight: .regular
        )

        button.setImage(
            UIImage(systemName: systemName)?.withConfiguration(symbolConfiguration),
            for: .normal
        )

        button.addTarget(
            self,
            action: action,
            for: .touchUpInside
        )

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: side),
            button.heightAnchor.constraint(equalToConstant: side)
        ])

        return button
    }

    /// Configures a time label used by the bottom playback bar.
    ///
    /// - Parameter label: Label to configure.
    func configureTimeLabel(_ label: UILabel) {
        label.textColor = UIColor.white.withAlphaComponent(0.86)
        label.font = .monospacedDigitSystemFont(
            ofSize: 16,
            weight: .regular
        )
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = true
        label.text = "0:00"
    }

    /// Seeks ten seconds backward in the current VLC media.
    @objc
    func seekBackwardTapped() {
        showControls(animated: true)
        scheduleControlsHide()
        seek(byMilliseconds: -10_000)
    }

    /// Toggles VLC playback.
    @objc
    func playPauseTapped() {
        showControls(animated: true)
        scheduleControlsHide()
        if mediaPlayer.isPlaying {
            mediaPlayer.pause()
        } else {
            mediaPlayer.play()
        }

        updatePlayPauseButton()
        updateProgressControls()
    }

    /// Seeks ten seconds forward in the current VLC media.
    @objc
    func seekForwardTapped() {
        showControls(animated: true)
        scheduleControlsHide()
        seek(byMilliseconds: 10_000)
    }

    /// Moves the current VLC playback time by a relative millisecond offset.
    ///
    /// - Parameter deltaMilliseconds: Relative seek offset in milliseconds.
    func seek(byMilliseconds deltaMilliseconds: Int32) {
        let duration = mediaPlayer.media?.length.intValue ?? 0
        guard duration > 0 else {
            return
        }

        let currentTime = mediaPlayer.time.intValue
        let targetTime = max(
            0,
            min(
                Int(duration),
                Int(currentTime + deltaMilliseconds)
            )
        )

        mediaPlayer.time = VLCTime(int: Int32(targetTime))
        updateProgressControls()
    }

    /// Begins slider scrubbing.
    @objc
    func sliderTouchBegan() {
        showControls(animated: true)
        stopControlsHideTimer()
        isScrubbing = true
    }

    /// Updates the time labels while the user is dragging the slider.
    @objc
    func sliderValueChanged() {
        updateProgressLabels(position: progressSlider.value)
    }

    /// Applies the selected slider position to VLC playback.
    @objc
    func sliderTouchEnded() {
        mediaPlayer.position = progressSlider.value
        isScrubbing = false
        updateProgressControls()
        scheduleControlsHide()
    }

    /// Updates the play/pause button icon from the current VLC playback state.
    func updatePlayPauseButton() {
        let imageName = mediaPlayer.isPlaying ? "pause.fill" : "play.fill"

        let symbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 36,
            weight: .regular
        )

        playPauseButton.setImage(
            UIImage(systemName: imageName)?.withConfiguration(symbolConfiguration),
            for: .normal
        )
    }

    /// Starts periodic progress updates.
    func startProgressTimer() {
        stopProgressTimer()

        progressTimer = Timer.scheduledTimer(
            withTimeInterval: 0.35,
            repeats: true
        ) { [weak self] _ in
            self?.updateProgressControls()
        }
    }

    /// Stops periodic progress updates.
    func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    /// Updates slider and time labels from the current VLC playback position.
    func updateProgressControls() {
        guard !isScrubbing else {
            return
        }

        let position = max(0, min(1, mediaPlayer.position))
        progressSlider.value = position
        updateProgressLabels(position: position)
        updatePlayPauseButton()
    }

    /// Updates elapsed and remaining time labels.
    ///
    /// - Parameter position: Normalized playback position between 0 and 1.
    func updateProgressLabels(position: Float) {
        let duration = mediaPlayer.media?.length.intValue ?? 0
        let elapsed = Int(Float(duration) * position)
        let remaining = max(0, Int(duration) - elapsed)

        elapsedTimeLabel.text = formatPlaybackTime(milliseconds: elapsed)
        remainingTimeLabel.text = "−" + formatPlaybackTime(milliseconds: remaining)
    }

    /// Formats milliseconds as a compact playback time.
    ///
    /// - Parameter milliseconds: Time value in milliseconds.
    /// - Returns: Formatted time string.
    func formatPlaybackTime(milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds / 1000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Controls Visibility

extension NCVideoVLCViewController {
    /// Shows the VLC playback controls.
    ///
    /// - Parameter animated: Whether the visibility change should be animated.
    internal func showControls(animated: Bool) {
        controlsVisible = true
        setControlsVisible(true, animated: animated)
    }

    /// Hides the VLC playback controls.
    ///
    /// - Parameter animated: Whether the visibility change should be animated.
    internal func hideControls(animated: Bool) {
        controlsVisible = false
        stopControlsHideTimer()
        setControlsVisible(false, animated: animated)
    }

    /// Applies the current controls visibility to the control views.
    ///
    /// - Parameters:
    ///   - visible: Whether controls should be visible.
    ///   - animated: Whether the visibility change should be animated.
    internal func setControlsVisible(_ visible: Bool, animated: Bool) {
        let changes = {
            self.centerControlsView.alpha = visible ? 1 : 0
            self.bottomControlsView.alpha = visible ? 1 : 0
        }

        let completion: (Bool) -> Void = { _ in
            self.centerControlsView.isHidden = !visible
            self.bottomControlsView.isHidden = !visible
        }

        if visible {
            centerControlsView.isHidden = false
            bottomControlsView.isHidden = false
        }

        guard animated else {
            changes()
            completion(true)
            return
        }

        UIView.animate(
            withDuration: 0.22,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseInOut],
            animations: changes,
            completion: completion
        )
    }

    /// Schedules automatic hiding for the VLC playback controls.
    internal func scheduleControlsHide() {
        stopControlsHideTimer()

        controlsHideTimer = Timer.scheduledTimer(
            withTimeInterval: 3.0,
            repeats: false
        ) { [weak self] _ in
            self?.hideControls(animated: true)
        }
    }

    /// Stops the automatic controls hide timer.
    internal func stopControlsHideTimer() {
        controlsHideTimer?.invalidate()
        controlsHideTimer = nil
    }
}
