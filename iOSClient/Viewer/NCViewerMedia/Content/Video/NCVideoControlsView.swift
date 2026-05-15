// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit

// MARK: - Video Controls View Delegate

/// Receives user actions from the shared video controls view.
///
/// The controls view is playback-engine agnostic.
/// AVFoundation and VLC controllers translate these callbacks into their own player APIs.
protocol NCVideoControlsViewDelegate: AnyObject {
    func videoControlsDidTapSeekBackward(_ controlsView: NCVideoControlsView)
    func videoControlsDidTapPlayPause(_ controlsView: NCVideoControlsView)
    func videoControlsDidTapSeekForward(_ controlsView: NCVideoControlsView)
    func videoControlsDidBeginScrubbing(_ controlsView: NCVideoControlsView)
    func videoControls(_ controlsView: NCVideoControlsView, didScrubTo progress: Float)
    func videoControlsDidEndScrubbing(_ controlsView: NCVideoControlsView, progress: Float)
}

// MARK: - Video Controls View

/// Shared UIKit playback controls used by video engines.
///
/// This view contains only reusable UI and user interaction routing.
/// It does not own AVPlayer, VLCMediaPlayer, timers, media state, or playback logic.
final class NCVideoControlsView: UIView {

    // MARK: - Public

    weak var delegate: NCVideoControlsViewDelegate?

    // MARK: - Layout Constants

    private static let centerControlsWidth: CGFloat = 220
    private static let centerControlsHeight: CGFloat = 76
    private static let centerControlsSpacing: CGFloat = 28
    private static let bottomControlsHeight: CGFloat = 86
    private static let bottomControlsHorizontalInset: CGFloat = 20
    private static let bottomControlsTrailingInset: CGFloat = 16
    private static let bottomControlsTopInset: CGFloat = 16
    private static let bottomControlsStackHeight: CGFloat = 34
    private static let bottomControlsSpacing: CGFloat = 10
    private static let elapsedTimeLabelWidth: CGFloat = 54
    private static let remainingTimeLabelWidth: CGFloat = 58
    private static let seekButtonSide: CGFloat = 44
    private static let seekButtonPointSize: CGFloat = 22
    private static let playPauseButtonSide: CGFloat = 62
    private static let playPauseButtonPointSize: CGFloat = 36

    // MARK: - Views

    let centerControlsView = UIView()
    let centerControlsStackView = UIStackView()
    let bottomControlsView = UIView()
    let bottomControlsStackView = UIStackView()
    let elapsedTimeLabel = UILabel()
    let remainingTimeLabel = UILabel()
    let progressSlider = UISlider()

    private lazy var seekBackwardButton = makeCenterControlButton(
        systemName: "gobackward.10",
        pointSize: Self.seekButtonPointSize,
        side: Self.seekButtonSide,
        action: #selector(seekBackwardTapped)
    )

    private lazy var playPauseButton = makeCenterControlButton(
        systemName: "play.fill",
        pointSize: Self.playPauseButtonPointSize,
        side: Self.playPauseButtonSide,
        action: #selector(playPauseTapped)
    )

    private lazy var seekForwardButton = makeCenterControlButton(
        systemName: "goforward.10",
        pointSize: Self.seekButtonPointSize,
        side: Self.seekButtonSide,
        action: #selector(seekForwardTapped)
    )

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)

        configureLayout()
        configureActions()
        updatePlayPauseButton(isPlaying: false)
        updateProgress(
            progress: 0,
            elapsedText: "0:00",
            remainingText: "−0:00"
        )
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)

        configureLayout()
        configureActions()
        updatePlayPauseButton(isPlaying: false)
        updateProgress(
            progress: 0,
            elapsedText: "0:00",
            remainingText: "−0:00"
        )
    }

    // MARK: - Public Updates

    /// Updates the play/pause icon.
    ///
    /// - Parameter isPlaying: True when playback is currently active.
    func updatePlayPauseButton(isPlaying: Bool) {
        let imageName = isPlaying ? "pause.fill" : "play.fill"

        let symbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: Self.playPauseButtonPointSize,
            weight: .regular
        )

        playPauseButton.setImage(
            UIImage(systemName: imageName)?.withConfiguration(symbolConfiguration),
            for: .normal
        )
    }

    /// Updates slider and time labels.
    ///
    /// - Parameters:
    ///   - progress: Normalized playback progress between 0 and 1.
    ///   - elapsedText: Formatted elapsed time.
    ///   - remainingText: Formatted remaining time.
    func updateProgress(
        progress: Float,
        elapsedText: String,
        remainingText: String
    ) {
        progressSlider.value = max(0, min(1, progress))
        elapsedTimeLabel.text = elapsedText
        remainingTimeLabel.text = remainingText
    }

    /// Enables or disables seeking controls.
    ///
    /// - Parameter isEnabled: True when the current engine supports seeking.
    func setSeekingEnabled(_ isEnabled: Bool) {
        seekBackwardButton.isEnabled = isEnabled
        seekForwardButton.isEnabled = isEnabled
        progressSlider.isEnabled = isEnabled

        let alpha: CGFloat = isEnabled ? 1 : 0.45
        seekBackwardButton.alpha = alpha
        seekForwardButton.alpha = alpha
        progressSlider.alpha = alpha
    }

    // MARK: - Configuration

    private func configureLayout() {
        backgroundColor = .clear
        translatesAutoresizingMaskIntoConstraints = false

        centerControlsView.translatesAutoresizingMaskIntoConstraints = false
        centerControlsView.backgroundColor = .clear

        centerControlsStackView.axis = .horizontal
        centerControlsStackView.alignment = .center
        centerControlsStackView.distribution = .equalSpacing
        centerControlsStackView.spacing = Self.centerControlsSpacing
        centerControlsStackView.translatesAutoresizingMaskIntoConstraints = false

        bottomControlsView.translatesAutoresizingMaskIntoConstraints = false
        bottomControlsView.backgroundColor = UIColor.black.withAlphaComponent(0.26)

        bottomControlsStackView.axis = .horizontal
        bottomControlsStackView.alignment = .center
        bottomControlsStackView.spacing = Self.bottomControlsSpacing
        bottomControlsStackView.translatesAutoresizingMaskIntoConstraints = false

        configureTimeLabel(elapsedTimeLabel)
        configureTimeLabel(remainingTimeLabel)

        progressSlider.minimumValue = 0
        progressSlider.maximumValue = 1
        progressSlider.value = 0
        progressSlider.minimumTrackTintColor = .white
        progressSlider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.28)
        progressSlider.thumbTintColor = .white

        addSubview(centerControlsView)
        addSubview(bottomControlsView)

        centerControlsView.addSubview(centerControlsStackView)
        bottomControlsView.addSubview(bottomControlsStackView)

        centerControlsStackView.addArrangedSubview(seekBackwardButton)
        centerControlsStackView.addArrangedSubview(playPauseButton)
        centerControlsStackView.addArrangedSubview(seekForwardButton)

        bottomControlsStackView.addArrangedSubview(elapsedTimeLabel)
        bottomControlsStackView.addArrangedSubview(progressSlider)
        bottomControlsStackView.addArrangedSubview(remainingTimeLabel)

        NSLayoutConstraint.activate([
            centerControlsView.centerXAnchor.constraint(equalTo: centerXAnchor),
            centerControlsView.centerYAnchor.constraint(equalTo: centerYAnchor),
            centerControlsView.widthAnchor.constraint(equalToConstant: Self.centerControlsWidth),
            centerControlsView.heightAnchor.constraint(equalToConstant: Self.centerControlsHeight),

            centerControlsStackView.leadingAnchor.constraint(equalTo: centerControlsView.leadingAnchor),
            centerControlsStackView.trailingAnchor.constraint(equalTo: centerControlsView.trailingAnchor),
            centerControlsStackView.topAnchor.constraint(equalTo: centerControlsView.topAnchor),
            centerControlsStackView.bottomAnchor.constraint(equalTo: centerControlsView.bottomAnchor),

            bottomControlsView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomControlsView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomControlsView.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomControlsView.heightAnchor.constraint(equalToConstant: Self.bottomControlsHeight),

            bottomControlsStackView.leadingAnchor.constraint(equalTo: bottomControlsView.leadingAnchor, constant: Self.bottomControlsHorizontalInset),
            bottomControlsStackView.trailingAnchor.constraint(equalTo: bottomControlsView.trailingAnchor, constant: -Self.bottomControlsTrailingInset),
            bottomControlsStackView.topAnchor.constraint(equalTo: bottomControlsView.topAnchor, constant: Self.bottomControlsTopInset),
            bottomControlsStackView.heightAnchor.constraint(equalToConstant: Self.bottomControlsStackHeight),

            elapsedTimeLabel.widthAnchor.constraint(equalToConstant: Self.elapsedTimeLabelWidth),
            remainingTimeLabel.widthAnchor.constraint(equalToConstant: Self.remainingTimeLabelWidth)
        ])
    }

    private func configureActions() {
        progressSlider.addTarget(
            self,
            action: #selector(sliderTouchBegan),
            for: .touchDown
        )

        progressSlider.addTarget(
            self,
            action: #selector(sliderValueChanged),
            for: .valueChanged
        )

        progressSlider.addTarget(
            self,
            action: #selector(sliderTouchEnded),
            for: [.touchUpInside, .touchUpOutside, .touchCancel]
        )
    }

    private func configureTimeLabel(_ label: UILabel) {
        label.textColor = UIColor.white.withAlphaComponent(0.86)
        label.font = .monospacedDigitSystemFont(
            ofSize: 16,
            weight: .regular
        )
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = true
        label.text = "0:00"
    }

    private func makeCenterControlButton(
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

    // MARK: - Actions

    @objc
    private func seekBackwardTapped() {
        delegate?.videoControlsDidTapSeekBackward(self)
    }

    @objc
    private func playPauseTapped() {
        delegate?.videoControlsDidTapPlayPause(self)
    }

    @objc
    private func seekForwardTapped() {
        delegate?.videoControlsDidTapSeekForward(self)
    }

    @objc
    private func sliderTouchBegan() {
        delegate?.videoControlsDidBeginScrubbing(self)
    }

    @objc
    private func sliderValueChanged() {
        delegate?.videoControls(self, didScrubTo: progressSlider.value)
    }

    @objc
    private func sliderTouchEnded() {
        delegate?.videoControlsDidEndScrubbing(
            self,
            progress: progressSlider.value
        )
    }
}
