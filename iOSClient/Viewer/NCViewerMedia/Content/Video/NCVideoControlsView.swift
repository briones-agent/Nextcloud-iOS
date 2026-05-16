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
    var onPictureInPictureTap: (() -> Void)?

    // MARK: - Layout Constants

    // Center playback controls:
    // Defines the floating center cluster used for backward, play/pause, and forward actions.
    // `centerControlsWidth` and `centerControlsHeight` describe the full center controls area.
    // `centerControlsSpacing` controls the horizontal distance between the three center buttons.
    private static let centerControlsWidth: CGFloat = 220
    private static let centerControlsHeight: CGFloat = 76
    private static let centerControlsSpacing: CGFloat = 28

    // Bottom progress controls:
    // Defines the bottom bar that contains elapsed time, progress slider, and remaining time.
    // The bottom view has its own height, horizontal padding, top padding, and stack height.
    private static let bottomControlsHeight: CGFloat = 86
    private static let bottomControlsHorizontalInset: CGFloat = 20
    private static let bottomControlsTrailingInset: CGFloat = 16
    private static let bottomControlsTopInset: CGFloat = 16
    private static let bottomControlsStackHeight: CGFloat = 34
    private static let bottomControlsSpacing: CGFloat = 10

    // Top video action controls:
    // Defines the top action row used for non-playback actions such as Picture in Picture,
    // subtitles, audio tracks, or future video-specific commands.
    // The vertical position is not hardcoded here: it is derived from the real navigation bar
    // through `setTopActionsNavigationBar(_:)`.
    // `topActionsHeight` is the height of the action row.
    // `topActionButtonSide` is the actual square size of each action button.
    // If `topActionsHeight` is larger than `topActionButtonSide`, the buttons are vertically
    // centered inside the row, creating visual breathing space.
    private static let topActionsHeight: CGFloat = 52
    private static let topActionsHorizontalInset: CGFloat = 16
    private static let topActionsSpacing: CGFloat = 10

    // Time labels:
    // Fixed widths keep the progress slider stable while the elapsed and remaining time texts change.
    private static let elapsedTimeLabelWidth: CGFloat = 54
    private static let remainingTimeLabelWidth: CGFloat = 58

    // Playback buttons:
    // Seek buttons use a smaller symbol and touch area than the main play/pause button.
    private static let seekButtonSide: CGFloat = 44
    private static let seekButtonPointSize: CGFloat = 22
    private static let playPauseButtonSide: CGFloat = 62
    private static let playPauseButtonPointSize: CGFloat = 36

    // Top action buttons:
    // Shared sizing for buttons placed in the top action row.
    private static let topActionButtonSide: CGFloat = 44
    private static let topActionButtonPointSize: CGFloat = 21

    // MARK: - Views

    let centerControlsView = UIView()
    let centerControlsStackView = UIStackView()
    let bottomControlsView = UIView()
    let bottomControlsStackView = UIStackView()
    let topActionsView = UIView()
    let topActionsStackView = UIStackView()
    let elapsedTimeLabel = UILabel()
    let remainingTimeLabel = UILabel()
    let progressSlider = UISlider()

    private var topActionsTopConstraint: NSLayoutConstraint?
    private weak var navigationBar: UINavigationBar?

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

    private lazy var pictureInPictureButton = makeTopActionButton(
        systemName: "pip.enter",
        fallbackSystemName: "pip",
        action: #selector(pictureInPictureTapped)
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

    /// Shows or hides the Picture in Picture action.
    ///
    /// - Parameter isVisible: True when the current playback engine supports Picture in Picture.
    func setPictureInPictureVisible(_ isVisible: Bool) {
        setTopActionButton(pictureInPictureButton, visible: isVisible)
    }

    /// Updates the navigation bar reference used by the top actions area.
    ///
    /// The controls view converts the real navigation bar frame into its own
    /// coordinate space so top actions remain aligned below the actual viewer chrome
    /// across iPhone, iPad, rotation, and compact/regular layouts.
    ///
    /// - Parameter navigationBar: Navigation bar used as vertical reference for top actions.
    func setTopActionsNavigationBar(_ navigationBar: UINavigationBar?) {
        self.navigationBar = navigationBar
        updateTopActionsPosition()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        updateTopActionsPosition()
    }

    private func updateTopActionsPosition() {
        guard let topActionsTopConstraint else {
            return
        }

        guard let navigationBar else {
            topActionsTopConstraint.constant = safeAreaInsets.top
            return
        }

        let navigationFrame = navigationBar.convert(
            navigationBar.bounds,
            to: self
        )

        topActionsTopConstraint.constant = navigationFrame.maxY
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

        topActionsView.translatesAutoresizingMaskIntoConstraints = false
        topActionsView.backgroundColor = .clear

        topActionsStackView.axis = .horizontal
        topActionsStackView.alignment = .center
        topActionsStackView.distribution = .fill
        topActionsStackView.spacing = Self.topActionsSpacing
        topActionsStackView.translatesAutoresizingMaskIntoConstraints = false

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
        addSubview(topActionsView)

        centerControlsView.addSubview(centerControlsStackView)
        bottomControlsView.addSubview(bottomControlsStackView)
        topActionsView.addSubview(topActionsStackView)

        centerControlsStackView.addArrangedSubview(seekBackwardButton)
        centerControlsStackView.addArrangedSubview(playPauseButton)
        centerControlsStackView.addArrangedSubview(seekForwardButton)

        bottomControlsStackView.addArrangedSubview(elapsedTimeLabel)
        bottomControlsStackView.addArrangedSubview(progressSlider)
        bottomControlsStackView.addArrangedSubview(remainingTimeLabel)

        topActionsStackView.addArrangedSubview(pictureInPictureButton)

        let topActionsTopConstraint = topActionsView.topAnchor.constraint(equalTo: topAnchor)
        self.topActionsTopConstraint = topActionsTopConstraint

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

            topActionsView.leadingAnchor.constraint(equalTo: leadingAnchor),
            topActionsView.trailingAnchor.constraint(equalTo: trailingAnchor),
            topActionsTopConstraint,
            topActionsView.heightAnchor.constraint(equalToConstant: Self.topActionsHeight),

            topActionsStackView.leadingAnchor.constraint(equalTo: topActionsView.leadingAnchor, constant: Self.topActionsHorizontalInset),
            topActionsStackView.centerYAnchor.constraint(equalTo: topActionsView.centerYAnchor),
            topActionsStackView.heightAnchor.constraint(equalToConstant: Self.topActionsHeight),

            bottomControlsStackView.leadingAnchor.constraint(equalTo: bottomControlsView.leadingAnchor, constant: Self.bottomControlsHorizontalInset),
            bottomControlsStackView.trailingAnchor.constraint(equalTo: bottomControlsView.trailingAnchor, constant: -Self.bottomControlsTrailingInset),
            bottomControlsStackView.topAnchor.constraint(equalTo: bottomControlsView.topAnchor, constant: Self.bottomControlsTopInset),
            bottomControlsStackView.heightAnchor.constraint(equalToConstant: Self.bottomControlsStackHeight),

            elapsedTimeLabel.widthAnchor.constraint(equalToConstant: Self.elapsedTimeLabelWidth),
            remainingTimeLabel.widthAnchor.constraint(equalToConstant: Self.remainingTimeLabelWidth),
            pictureInPictureButton.widthAnchor.constraint(equalToConstant: Self.topActionButtonSide),
            pictureInPictureButton.heightAnchor.constraint(equalToConstant: Self.topActionButtonSide)
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

    private func makeTopActionButton(
        systemName: String,
        fallbackSystemName: String,
        action: Selector
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.36)
        button.layer.cornerRadius = Self.topActionButtonSide / 2
        button.clipsToBounds = true
        button.isHidden = true
        button.isEnabled = false
        button.translatesAutoresizingMaskIntoConstraints = false

        let symbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: Self.topActionButtonPointSize,
            weight: .regular
        )

        let image = UIImage(systemName: systemName)
            ?? UIImage(systemName: fallbackSystemName)

        button.setImage(
            image?.withConfiguration(symbolConfiguration),
            for: .normal
        )

        button.addTarget(
            self,
            action: action,
            for: .touchUpInside
        )

        return button
    }

    private func setTopActionButton(_ button: UIButton, visible: Bool) {
        button.isHidden = !visible
        button.isEnabled = visible

        if visible {
            bringSubviewToFront(topActionsView)
            topActionsView.bringSubviewToFront(topActionsStackView)
        }
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
    private func pictureInPictureTapped() {
        onPictureInPictureTap?()
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
