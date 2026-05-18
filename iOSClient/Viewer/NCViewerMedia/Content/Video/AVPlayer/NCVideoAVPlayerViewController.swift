// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import AVKit
import UIKit
import NextcloudKit

// MARK: - AVPlayer View Controller

/// UIKit-only AVPlayer video controller.
///
/// This controller is intentionally outside the SwiftUI paging hierarchy.
/// It owns one stable player container view, one AVPlayer, one AVPlayerViewController, and one shared controls view.
final class NCVideoAVPlayerViewController: UIViewController {

    // MARK: - Input

    private var metadata: tableMetadata
    private var url: URL
    private var userAgent: String?
    private weak var contextMenuController: NCMainTabBarController?

    // MARK: - Paging Callbacks

    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var canGoPrevious = false
    var canGoNext = false

    // MARK: - Views

    internal let playerContainerView = UIView()
    internal let controlsView = NCVideoControlsView()

    // MARK: - AVPlayer

    internal let player = AVPlayer()
    internal let playerViewController = AVPlayerViewController()

    internal var controlsHideTimer: Timer?
    internal var controlsVisible = false
    internal var isScrubbing = false

    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var playbackEndObserver: NSObjectProtocol?
    private var timeObserverToken: Any?
    private var preparedURL: URL?

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

        playerContainerView.backgroundColor = .black
        playerContainerView.isOpaque = true
        playerContainerView.clipsToBounds = true
        playerContainerView.translatesAutoresizingMaskIntoConstraints = false

        controlsView.delegate = self
        controlsView.alpha = 0
        controlsView.isHidden = true
        controlsView.translatesAutoresizingMaskIntoConstraints = false

        rootView.addSubview(playerContainerView)
        rootView.addSubview(controlsView)

        NSLayoutConstraint.activate([
            playerContainerView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            playerContainerView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            playerContainerView.topAnchor.constraint(equalTo: rootView.topAnchor),
            playerContainerView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            controlsView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            controlsView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            controlsView.topAnchor.constraint(equalTo: rootView.topAnchor),
            controlsView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])

        updateControlsNavigationBar()
        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .black

        configureNavigationItem()
        configureAudioSession()
        configurePlayerViewController()
        configureSwipeGestures()
        configureTapGesture()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        start()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        updatePictureInPictureLayout()
        updateControlsNavigationBar()
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
            self?.updatePictureInPictureLayout()
            self?.updateControlsNavigationBar()
        })
    }

    // MARK: - Public API

    /// Updates the current AVPlayer input.
    ///
    /// If the URL changes, the current item is stopped and the new item is prepared.
    /// The navigation title and context menu are refreshed for the new metadata.
    ///
    /// - Parameters:
    ///   - metadata: Updated video metadata.
    ///   - url: Updated playable URL.
    ///   - userAgent: Optional HTTP User-Agent.
    ///   - contextMenuController: Updated context menu controller.
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
        updateProgressControls()
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

    /// Builds the AVPlayer-specific More menu.
    ///
    /// The menu uses `sender: self`, so menu actions present from the visible
    /// AVPlayer controller instead of the SwiftUI viewer underneath.
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

        if !NCVideoAVPlayerPictureInPictureManager.shared.isActive {
            stop()
            NCVideoAVPlayerPictureInPictureManager.shared.resetIfInactive()
        } else {
            cleanupObservers()
        }

        Task { @MainActor in
            NCVideoAVPlayerPresenter.clearCurrent(self)
        }

        dismiss(animated: false) {
            NotificationCenter.default.post(
                name: .ncMediaVLCViewerClose,
                object: nil
            )
        }
    }

    // MARK: - Swipe Navigation

    /// Configures swipe gestures for page navigation and close behavior.
    private func configureSwipeGestures() {
        let previousGesture = UISwipeGestureRecognizer(
            target: self,
            action: #selector(handleSwipe(_:))
        )
        previousGesture.direction = .right
        previousGesture.delegate = self
        view.addGestureRecognizer(previousGesture)

        let nextGesture = UISwipeGestureRecognizer(
            target: self,
            action: #selector(handleSwipe(_:))
        )
        nextGesture.direction = .left
        nextGesture.delegate = self
        view.addGestureRecognizer(nextGesture)

        let closeGesture = UISwipeGestureRecognizer(
            target: self,
            action: #selector(handleSwipe(_:))
        )
        closeGesture.direction = .down
        closeGesture.delegate = self
        view.addGestureRecognizer(closeGesture)
    }

    /// Handles page navigation and close swipe gestures.
    ///
    /// - Parameter gesture: Source swipe gesture recognizer.
    @objc
    private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
        guard gesture.state == .ended else {
            return
        }

        switch gesture.direction {
        case .left:
            guard canGoNext else {
                return
            }

            onNext?()

        case .right:
            guard canGoPrevious else {
                return
            }

            onPrevious?()

        case .down:
            close()

        default:
            break
        }
    }

    // MARK: - Gesture Handling

    /// Configures a single tap gesture to toggle AVPlayer playback controls.
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

    /// Handles single taps by toggling AVPlayer playback controls.
    ///
    /// - Parameter gesture: Source tap gesture recognizer.
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

    // MARK: - Playback

    /// Prepares AVPlayer playback without starting it automatically.
    private func start() {
        guard preparedURL != url else {
            updatePlayPauseButton()
            updateProgressControls()
            updateSeekingState()
            return
        }

        preparedURL = url

        let item = AVPlayerItem(asset: makeAsset())

        player.replaceCurrentItem(with: item)
        playerViewController.player = player

        configureObservers()
        configurePictureInPicture()
        updatePlayPauseButton()
        updateProgressControls()
        updateSeekingState()

        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: .debug,
            message: "VIDEO AVPlayer UIKit prepared without autoplay ocId \(metadata.ocId), url \(url.absoluteString)",
            consoleOnly: true
        )
    }

    /// Stops AVPlayer playback and releases resources.
    private func stop() {
        preparedURL = nil
        player.pause()
        cleanupObservers()
        player.replaceCurrentItem(with: nil)
        updatePlayPauseButton()
        updateProgressControls()
    }

    /// Creates the AVFoundation asset for the current URL.
    private func makeAsset() -> AVURLAsset {
        guard let userAgent,
              !userAgent.isEmpty,
              !url.isFileURL else {
            return AVURLAsset(url: url)
        }

        return AVURLAsset(
            url: url,
            options: [
                "AVURLAssetHTTPHeaderFieldsKey": [
                    "User-Agent": userAgent
                ]
            ]
        )
    }

    /// Configures the embedded AVPlayerViewController.
    private func configurePlayerViewController() {
        playerViewController.player = player
        playerViewController.showsPlaybackControls = false
        playerViewController.view.backgroundColor = .black
        playerViewController.view.translatesAutoresizingMaskIntoConstraints = false

        addChild(playerViewController)
        playerContainerView.addSubview(playerViewController.view)

        NSLayoutConstraint.activate([
            playerViewController.view.leadingAnchor.constraint(equalTo: playerContainerView.leadingAnchor),
            playerViewController.view.trailingAnchor.constraint(equalTo: playerContainerView.trailingAnchor),
            playerViewController.view.topAnchor.constraint(equalTo: playerContainerView.topAnchor),
            playerViewController.view.bottomAnchor.constraint(equalTo: playerContainerView.bottomAnchor)
        ])

        playerViewController.didMove(toParent: self)
    }

    /// Configures Picture in Picture ownership through the shared manager.
    private func configurePictureInPicture() {
        NCVideoAVPlayerPictureInPictureManager.shared.configure(
            player: player,
            window: view.window,
            sourceView: playerContainerView,
            allowsPictureInPicture: true
        )

        controlsView.onPictureInPictureTap = {
            NCVideoAVPlayerPictureInPictureManager.shared.toggle()
        }

        controlsView.setPictureInPictureVisible(
            AVPictureInPictureController.isPictureInPictureSupported()
        )
    }

    /// Updates Picture in Picture layout without changing playback state.
    private func updatePictureInPictureLayout() {
        NCVideoAVPlayerPictureInPictureManager.shared.configure(
            player: player,
            window: view.window,
            sourceView: playerContainerView,
            allowsPictureInPicture: true
        )

        NCVideoAVPlayerPictureInPictureManager.shared.updateLayoutIfNeeded()
    }

    /// Configures AVPlayer observers.
    private func configureObservers() {
        cleanupObservers()

        itemStatusObservation = player.currentItem?.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            Task { @MainActor in
                self?.handleCurrentItemStatusChange()
            }
        }

        timeControlStatusObservation = player.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            Task { @MainActor in
                self?.updatePlayPauseButton()
            }
        }

        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC)),
            queue: .main
        ) { [weak self] _ in
            guard let self,
                  !self.isScrubbing else {
                return
            }

            self.updateProgressControls()
        }

        if let currentItem = player.currentItem {
            playbackEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: currentItem,
                queue: .main
            ) { [weak self] _ in
                self?.handlePlaybackEnded()
            }
        }
    }

    /// Releases AVPlayer observers owned by this controller.
    private func cleanupObservers() {
        itemStatusObservation?.invalidate()
        timeControlStatusObservation?.invalidate()

        itemStatusObservation = nil
        timeControlStatusObservation = nil

        if let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
            self.timeObserverToken = nil
        }

        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
            self.playbackEndObserver = nil
        }
    }

    /// Handles AVPlayer item status changes.
    private func handleCurrentItemStatusChange() {
        updateProgressControls()
        updatePlayPauseButton()
        updateSeekingState()

        guard player.currentItem?.status == .readyToPlay else {
            return
        }

        if !controlsVisible,
           !NCVideoAVPlayerPictureInPictureManager.shared.isActive {
            showControls(animated: false)
            scheduleControlsHide()
        }
    }

    /// Handles playback reaching the end.
    private func handlePlaybackEnded() {
        updatePlayPauseButton()
        updateProgressControls()
        showControls(animated: true)
    }

    // MARK: - Helpers

    /// Updates the shared controls top actions reference using the real navigation bar.
    private func updateControlsNavigationBar() {
        controlsView.setTopActionsNavigationBar(navigationController?.navigationBar)
    }

    /// Returns whether a point is inside one of the visible controls areas.
    ///
    /// - Parameter location: Point in this controller's root view coordinate space.
    /// - Returns: True when the point is inside center or bottom controls.
    internal func controlsHitFramesContain(_ location: CGPoint) -> Bool {
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
                message: "VIDEO AVPlayer audio session error: \(error.localizedDescription)",
                consoleOnly: true
            )
        }
    }

    /// Updates the shared controls play/pause state.
    internal func updatePlayPauseButton() {
        controlsView.updatePlayPauseButton(
            isPlaying: player.timeControlStatus == .playing
        )
    }

    /// Updates the shared controls progress state.
    internal func updateProgressControls() {
        let currentTime = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0

        guard currentTime.isFinite,
              duration.isFinite,
              duration > 0 else {
            controlsView.updateProgress(
                progress: 0,
                elapsedText: "0:00",
                remainingText: "−0:00"
            )
            return
        }

        let progress = Float(max(0, min(1, currentTime / duration)))
        let remainingTime = max(0, duration - currentTime)

        controlsView.updateProgress(
            progress: progress,
            elapsedText: Self.formatTime(currentTime),
            remainingText: "−\(Self.formatTime(remainingTime))"
        )
    }

    /// Updates whether seek controls are enabled.
    internal func updateSeekingState() {
        controlsView.setSeekingEnabled(
            player.currentItem?.duration.seconds.isFinite == true
        )
    }

    internal static func formatTime(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60

        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Gesture Delegate

extension NCVideoAVPlayerViewController: UIGestureRecognizerDelegate {

    /// Allows tap gestures to coexist with AVPlayer's view and UIKit controls.
    ///
    /// - Parameters:
    ///   - gestureRecognizer: Gesture recognizer asking for simultaneous recognition.
    ///   - otherGestureRecognizer: Other gesture recognizer involved in the decision.
    /// - Returns: True to avoid AVPlayer/touch handling from suppressing viewer gestures.
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
