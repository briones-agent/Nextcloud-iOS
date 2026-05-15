// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import UIKit
import MobileVLCKit
import NextcloudKit

// MARK: - VLC View Controller

/// UIKit-only VLC video controller.
///
/// This controller is intentionally outside the SwiftUI paging hierarchy.
/// It owns one stable drawable view and one VLCMediaPlayer.
final class NCVideoVLCViewController: UIViewController {

    // MARK: - Input

    private var metadata: tableMetadata
    private var url: URL
    private var userAgent: String?
    private weak var contextMenuController: NCMainTabBarController?

    // MARK: - Paging Callbacks

    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?

    // MARK: - Views

    internal let drawableView = UIView()
    internal let centerControlsView = UIView()
    internal let centerControlsStackView = UIStackView()
    internal let bottomControlsView = UIView()
    internal let bottomControlsStackView = UIStackView()
    internal let elapsedTimeLabel = UILabel()
    internal let remainingTimeLabel = UILabel()
    internal let progressSlider = UISlider()

    internal lazy var previousButton: UIButton = makeCenterControlButton(
        systemName: "gobackward.10",
        pointSize: 22,
        side: 44,
        action: #selector(seekBackwardTapped)
    )

    internal lazy var playPauseButton: UIButton = makeCenterControlButton(
        systemName: "play.fill",
        pointSize: 36,
        side: 62,
        action: #selector(playPauseTapped)
    )

    internal lazy var nextButton: UIButton = makeCenterControlButton(
        systemName: "goforward.10",
        pointSize: 22,
        side: 44,
        action: #selector(seekForwardTapped)
    )

    // MARK: - VLC

    internal let mediaPlayer = VLCMediaPlayer()

    internal var progressTimer: Timer?
    internal var controlsHideTimer: Timer?
    internal var controlsVisible = true
    internal var isScrubbing = false

    // MARK: - Navigation Items

    private lazy var moreNavigationItem = UIBarButtonItem(
        image: NCImageCache.shared.getImageButtonMore(),
        primaryAction: nil,
        menu: makeMoreMenu()
    )

    // MARK: - Init

    init(
        metadata: tableMetadata,
        url: URL,
        userAgent: String?,
        contextMenuController: NCMainTabBarController?
    ) {
        self.metadata = metadata
        self.url = url
        self.userAgent = userAgent
        self.contextMenuController = contextMenuController

        super.init(
            nibName: nil,
            bundle: nil
        )

        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopControlsHideTimer()
        stop()
    }

    // MARK: - Lifecycle

    override func loadView() {
        let rootView = UIView()
        rootView.backgroundColor = .black
        rootView.isOpaque = true
        rootView.clipsToBounds = true

        drawableView.backgroundColor = .black
        drawableView.isOpaque = true
        drawableView.clipsToBounds = true
        drawableView.translatesAutoresizingMaskIntoConstraints = false

        rootView.addSubview(drawableView)

        centerControlsView.translatesAutoresizingMaskIntoConstraints = false
        centerControlsView.backgroundColor = .clear

        centerControlsStackView.axis = .horizontal
        centerControlsStackView.alignment = .center
        centerControlsStackView.distribution = .equalCentering
        centerControlsStackView.spacing = 28
        centerControlsStackView.translatesAutoresizingMaskIntoConstraints = false

        centerControlsStackView.addArrangedSubview(previousButton)
        centerControlsStackView.addArrangedSubview(playPauseButton)
        centerControlsStackView.addArrangedSubview(nextButton)

        centerControlsView.addSubview(centerControlsStackView)
        rootView.addSubview(centerControlsView)

        bottomControlsView.backgroundColor = UIColor.black.withAlphaComponent(0.36)
        bottomControlsView.translatesAutoresizingMaskIntoConstraints = false

        configureTimeLabel(elapsedTimeLabel)
        configureTimeLabel(remainingTimeLabel)

        progressSlider.minimumValue = 0
        progressSlider.maximumValue = 1
        progressSlider.value = 0
        progressSlider.minimumTrackTintColor = .white
        progressSlider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.42)
        progressSlider.thumbTintColor = .white
        progressSlider.translatesAutoresizingMaskIntoConstraints = false
        progressSlider.addTarget(self, action: #selector(sliderTouchBegan), for: .touchDown)
        progressSlider.addTarget(self, action: #selector(sliderValueChanged), for: .valueChanged)
        progressSlider.addTarget(self, action: #selector(sliderTouchEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        bottomControlsStackView.axis = .horizontal
        bottomControlsStackView.alignment = .center
        bottomControlsStackView.distribution = .fill
        bottomControlsStackView.spacing = 10
        bottomControlsStackView.translatesAutoresizingMaskIntoConstraints = false

        bottomControlsStackView.addArrangedSubview(elapsedTimeLabel)
        bottomControlsStackView.addArrangedSubview(progressSlider)
        bottomControlsStackView.addArrangedSubview(remainingTimeLabel)

        bottomControlsView.addSubview(bottomControlsStackView)
        rootView.addSubview(bottomControlsView)

        NSLayoutConstraint.activate([
            drawableView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            drawableView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            drawableView.topAnchor.constraint(equalTo: rootView.topAnchor),
            drawableView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            centerControlsView.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            centerControlsView.centerYAnchor.constraint(equalTo: rootView.centerYAnchor),
            centerControlsView.widthAnchor.constraint(equalToConstant: 220),
            centerControlsView.heightAnchor.constraint(equalToConstant: 76),

            centerControlsStackView.leadingAnchor.constraint(equalTo: centerControlsView.leadingAnchor),
            centerControlsStackView.trailingAnchor.constraint(equalTo: centerControlsView.trailingAnchor),
            centerControlsStackView.topAnchor.constraint(equalTo: centerControlsView.topAnchor),
            centerControlsStackView.bottomAnchor.constraint(equalTo: centerControlsView.bottomAnchor),

            bottomControlsView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            bottomControlsView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            bottomControlsView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            bottomControlsView.heightAnchor.constraint(equalToConstant: 86),

            bottomControlsStackView.leadingAnchor.constraint(equalTo: bottomControlsView.leadingAnchor, constant: 20),
            bottomControlsStackView.trailingAnchor.constraint(equalTo: bottomControlsView.trailingAnchor, constant: -16),
            bottomControlsStackView.topAnchor.constraint(equalTo: bottomControlsView.topAnchor, constant: 16),
            bottomControlsStackView.heightAnchor.constraint(equalToConstant: 34),

            elapsedTimeLabel.widthAnchor.constraint(equalToConstant: 54),
            remainingTimeLabel.widthAnchor.constraint(equalToConstant: 58)
        ])

        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .black

        configureNavigationItem()
        configureAudioSession()
        configureSwipeGestures()
        configureTapGesture()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        start()
        showControls(animated: false)
        scheduleControlsHide()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        attachDrawable()
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
            self?.attachDrawable()
        })
    }

    // MARK: - Public API

    /// Updates the current VLC input.
    ///
    /// If the URL changes, the current media is stopped and the new media is prepared.
    /// The navigation title and context menu are refreshed for the new metadata.
    ///
    /// - Parameters:
    ///   - metadata: Updated video metadata.
    ///   - url: Updated playable URL.
    ///   - userAgent: Optional HTTP User-Agent.
    func update(
        metadata: tableMetadata,
        url: URL,
        userAgent: String?,
        contextMenuController: NCMainTabBarController?
    ) {
        let urlChanged = self.url != url

        if urlChanged {
            stop()
        }

        self.metadata = metadata
        self.url = url
        self.userAgent = userAgent
        self.contextMenuController = contextMenuController

        updateTitle()
        refreshMoreMenu()

        if urlChanged {
            start()
        }

        updatePlayPauseButton()
        showControls(animated: true)
        scheduleControlsHide()
    }

    // MARK: - Navigation

    /// Configures the navigation bar items.
    private func configureNavigationItem() {
        updateTitle()

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "chevron.backward"),
            style: .plain,
            target: self,
            action: #selector(closeTapped)
        )

        navigationItem.rightBarButtonItem = moreNavigationItem
    }

    /// Updates the navigation title from the current metadata.
    private func updateTitle() {
        title = metadata.fileNameView.isEmpty
            ? metadata.fileName
            : metadata.fileNameView
    }

    /// Rebuilds the More menu using the current metadata.
    private func refreshMoreMenu() {
        moreNavigationItem.menu = makeMoreMenu()
    }

    /// Builds the VLC-specific More menu.
    ///
    /// The menu uses `sender: self`, so menu actions present from the visible
    /// VLC controller instead of the SwiftUI viewer underneath.
    private func makeMoreMenu() -> UIMenu {
        UIMenu(title: "", children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self else {
                    completion([])
                    return
                }

                if let menu = NCContextMenuViewer(
                    metadata: self.metadata,
                    controller: self.contextMenuController,
                    webView: false,
                    sender: self
                ).viewMenu() {
                    completion(menu.children)
                } else {
                    completion([])
                }
            }
        ])
    }

    @objc
    private func closeTapped() {
        close()
    }

    private func close() {
        stopControlsHideTimer()
        stopProgressTimer()
        stop()

        Task { @MainActor in
            NCVideoVLCPresenter.clearCurrent(self)
        }

        dismiss(animated: false) {
            NotificationCenter.default.post(
                name: .ncMediaVLCViewerClose,
                object: nil
            )
        }
    }

    // MARK: - Swipe Navigation

    /// Configures UIKit swipe gestures for previous and next media navigation.
    private func configureSwipeGestures() {
        let swipeLeft = UISwipeGestureRecognizer(
            target: self,
            action: #selector(handleSwipe(_:))
        )
        swipeLeft.direction = .left
        swipeLeft.delegate = self

        let swipeRight = UISwipeGestureRecognizer(
            target: self,
            action: #selector(handleSwipe(_:))
        )
        swipeRight.direction = .right
        swipeRight.delegate = self

        view.addGestureRecognizer(swipeLeft)
        view.addGestureRecognizer(swipeRight)
    }

    /// Configures a single tap gesture to toggle VLC playback controls.
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

    /// Handles single taps by toggling the VLC playback controls.
    ///
    /// - Parameter gesture: Source tap gesture recognizer.
    @objc
    private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: view)

        if controlsVisible {
            guard !centerControlsView.frame.contains(location),
                  !bottomControlsView.frame.contains(location) else {
                return
            }

            hideControls(animated: true)
        } else {
            showControls(animated: true)
            scheduleControlsHide()
        }
    }

    /// Handles horizontal VLC swipe gestures.
    ///
    /// Left moves to the next media item.
    /// Right moves to the previous media item.
    /// The controller itself does not know the media list; it only forwards the intent
    /// through callbacks owned by the presenter/viewer layer.
    ///
    /// - Parameter gesture: Source swipe gesture recognizer.
    @objc
    private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
        switch gesture.direction {
        case .left:
            onNext?()

        case .right:
            onPrevious?()

        default:
            break
        }
    }

    // MARK: - Playback

    /// Prepares VLC playback without starting it automatically.
    private func start() {
        attachDrawable()

        let media = VLCMedia(url: url)

        if let userAgent,
           !userAgent.isEmpty,
           !url.isFileURL {
            media.addOption(":http-user-agent=\(userAgent)")
        }

        mediaPlayer.media = media
        updatePlayPauseButton()
        updateProgressControls()
        startProgressTimer()

        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: .debug,
            message: "VIDEO VLC UIKit prepared without autoplay ocId \(metadata.ocId), url \(url.absoluteString)",
            consoleOnly: true
        )
    }

    /// Stops VLC playback and releases resources.
    private func stop() {
        mediaPlayer.stop()
        mediaPlayer.media = nil
        mediaPlayer.drawable = nil
        stopProgressTimer()
        updatePlayPauseButton()
        updateProgressControls()
    }

    /// Attaches the drawable view to VLC.
    private func attachDrawable() {
        guard drawableView.bounds.width > 0,
              drawableView.bounds.height > 0 else {
            return
        }

        mediaPlayer.drawable = drawableView
    }

    // MARK: - Helpers

    /// Configures the audio session for movie playback.
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
}

// MARK: - Gesture Delegate

extension NCVideoVLCViewController: UIGestureRecognizerDelegate {
    /// Allows tap and swipe gestures to coexist with VLC's drawable view and UIKit controls.
    ///
    /// - Parameters:
    ///   - gestureRecognizer: Gesture recognizer asking for simultaneous recognition.
    ///   - otherGestureRecognizer: Other gesture recognizer involved in the decision.
    /// - Returns: True to avoid VLC/touch handling from suppressing viewer gestures.
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

        if centerControlsView.frame.contains(location) || bottomControlsView.frame.contains(location) {
            return false
        }

        return true
    }
}
