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
    let navigationBar: UINavigationBar?

    init(
        player: AVPlayer,
        allowsPictureInPicture: Bool = true,
        shouldAutoPlay: Bool = false,
        navigationBar: UINavigationBar? = nil
    ) {
        self.player = player
        self.allowsPictureInPicture = allowsPictureInPicture
        self.shouldAutoPlay = shouldAutoPlay
        self.navigationBar = navigationBar
    }

    func makeUIViewController(context: Context) -> NCVideoAVPlayerViewController {
        let controller = NCVideoAVPlayerViewController(
            player: player,
            allowsPictureInPicture: allowsPictureInPicture,
            shouldAutoPlay: shouldAutoPlay,
            navigationBar: navigationBar
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
            shouldAutoPlay: shouldAutoPlay,
            navigationBar: navigationBar
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

    internal var player: AVPlayer
    private var allowsPictureInPicture: Bool
    private var shouldAutoPlay: Bool
    private weak var navigationBar: UINavigationBar?

    // MARK: - Views

    private let playerViewController = AVPlayerViewController()
    internal let controlsView = NCVideoControlsView()
    internal let pictureInPicturePlayerLayer = AVPlayerLayer()

    // MARK: - State

    private var timeObserver: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var playbackEndObserver: NSObjectProtocol?
    internal var pictureInPictureController: AVPictureInPictureController?
    internal var controlsHideTimer: Timer?
    internal var isScrubbing = false
    internal var controlsVisible = false
    private var didAutoplay = false

    private static var autoplayedPlayerIDs = Set<ObjectIdentifier>()

    // MARK: - Init

    init(
        player: AVPlayer,
        allowsPictureInPicture: Bool,
        shouldAutoPlay: Bool,
        navigationBar: UINavigationBar?
    ) {
        self.player = player
        self.allowsPictureInPicture = allowsPictureInPicture
        self.shouldAutoPlay = shouldAutoPlay
        self.navigationBar = navigationBar

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

        pictureInPicturePlayerLayer.frame = view.bounds
        playerViewController.view.frame = view.bounds
        updateControlsNavigationBar()
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
        shouldAutoPlay: Bool,
        navigationBar: UINavigationBar?
    ) {
        let playerChanged = self.player !== player

        self.allowsPictureInPicture = allowsPictureInPicture
        self.shouldAutoPlay = shouldAutoPlay
        self.navigationBar = navigationBar

        if playerChanged {
            cleanupObservers()
            didAutoplay = false
            self.player = player
            playerViewController.player = player
            pictureInPicturePlayerLayer.player = player
            pictureInPictureController = nil
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
        pictureInPictureController?.delegate = nil
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

        pictureInPicturePlayerLayer.player = player
        pictureInPicturePlayerLayer.videoGravity = .resizeAspect

        if pictureInPicturePlayerLayer.superlayer == nil {
            view.layer.addSublayer(pictureInPicturePlayerLayer)
        }

        configurePictureInPictureController()

        if playerViewController.parent == nil {
            addChild(playerViewController)
            view.addSubview(playerViewController.view)
            playerViewController.view.frame = view.bounds
            playerViewController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            playerViewController.didMove(toParent: self)
        }
    }

    private func configurePictureInPictureController() {
        guard allowsPictureInPicture,
              AVPictureInPictureController.isPictureInPictureSupported() else {
            pictureInPictureController?.delegate = nil
            pictureInPictureController = nil
            controlsView.setPictureInPictureVisible(false)
            return
        }

        if pictureInPictureController == nil || pictureInPicturePlayerLayer.player !== player {
            pictureInPictureController = AVPictureInPictureController(playerLayer: pictureInPicturePlayerLayer)
            pictureInPictureController?.delegate = self
        }

        controlsView.setPictureInPictureVisible(pictureInPictureController != nil)
    }

    private func configureControlsView() {
        controlsView.delegate = self
        controlsView.onPictureInPictureTap = { [weak self] in
            self?.togglePictureInPicture()
        }
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

        updateControlsNavigationBar()
    }

    private func updateControlsNavigationBar() {
        controlsView.setTopActionsNavigationBar(navigationBar)
    }

    private func togglePictureInPicture() {
        guard let pictureInPictureController,
              AVPictureInPictureController.isPictureInPictureSupported() else {
            return
        }

        if pictureInPictureController.isPictureInPictureActive {
            pictureInPictureController.stopPictureInPicture()
        } else {
            pictureInPictureController.startPictureInPicture()
        }
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
}

// MARK: - AVPlayerViewController Delegate

extension NCVideoAVPlayerViewController: AVPlayerViewControllerDelegate, AVPictureInPictureControllerDelegate {
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

    func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: .debug,
            message: "VIDEO PiP controller will start",
            consoleOnly: true
        )
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: .debug,
            message: "VIDEO PiP controller did start",
            consoleOnly: true
        )
    }

    func pictureInPictureControllerWillStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: .debug,
            message: "VIDEO PiP controller will stop",
            consoleOnly: true
        )
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: .debug,
            message: "VIDEO PiP controller did stop",
            consoleOnly: true
        )
    }
}
