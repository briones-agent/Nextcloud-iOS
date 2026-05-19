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
/// It owns one stable drawable view, one VLCMediaPlayer, and one shared controls view.
final class NCVideoVLCViewController: UIViewController {

    // MARK: - Input

    private var metadata: tableMetadata
    private var url: URL
    private var previewURL: URL?
    private var userAgent: String?
    private weak var contextMenuController: NCMainTabBarController?

    // MARK: - Paging Callbacks

    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var canGoPrevious = false
    var canGoNext = false

    // MARK: - Views

    internal let drawableView = UIView()
    private let previewImageView = UIImageView()
    internal let controlsView = NCVideoControlsView()

    // MARK: - VLC

    internal let mediaPlayer = VLCMediaPlayer()

    internal var progressTimer: Timer?
    internal var controlsHideTimer: Timer?
    internal var controlsVisible = false
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
        previewURL: URL?,
        userAgent: String?,
        contextMenuController: NCMainTabBarController?
    ) {
        self.metadata = metadata
        self.url = url
        self.previewURL = previewURL
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

        previewImageView.backgroundColor = .black
        previewImageView.contentMode = .scaleAspectFit
        previewImageView.clipsToBounds = true
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        updatePreviewImage()

        controlsView.delegate = self
        controlsView.alpha = 0
        controlsView.isHidden = true
        controlsView.translatesAutoresizingMaskIntoConstraints = false

        rootView.addSubview(drawableView)
        rootView.addSubview(previewImageView)
        rootView.addSubview(controlsView)

        NSLayoutConstraint.activate([
            drawableView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            drawableView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            drawableView.topAnchor.constraint(equalTo: rootView.topAnchor),
            drawableView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            previewImageView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            previewImageView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            previewImageView.topAnchor.constraint(equalTo: rootView.topAnchor),
            previewImageView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            controlsView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            controlsView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            controlsView.topAnchor.constraint(equalTo: rootView.topAnchor),
            controlsView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])

        controlsView.setTopActionsNavigationBar(navigationController?.navigationBar)

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
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        attachDrawable()
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
            self?.attachDrawable()
            self?.updateControlsNavigationBar()
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
    ///   - previewURL: Optional local preview image URL shown until VLC starts rendering.
    ///   - userAgent: Optional HTTP User-Agent.
    func update(
        metadata: tableMetadata,
        url: URL,
        previewURL: URL?,
        userAgent: String?,
        contextMenuController: NCMainTabBarController?
    ) {
        let urlChanged = self.url != url

        if urlChanged {
            stop()
        }

        self.metadata = metadata
        self.url = url
        self.previewURL = previewURL
        self.userAgent = userAgent
        self.contextMenuController = contextMenuController
        updatePreviewImage()

        updateTitle()
        refreshMoreMenu()

        if urlChanged {
            start()
        }

        updatePlayPauseButton()
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

    /// Configures UIKit swipe gestures for media navigation and viewer closing.
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

        let swipeDown = UISwipeGestureRecognizer(
            target: self,
            action: #selector(handleCloseSwipe(_:))
        )
        swipeDown.direction = .down
        swipeDown.delegate = self

        view.addGestureRecognizer(swipeLeft)
        view.addGestureRecognizer(swipeRight)
        view.addGestureRecognizer(swipeDown)
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
            guard !controlsHitFramesContain(location) else {
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
    /// Left moves to the next media item when available.
    /// Right moves to the previous media item when available.
    /// The controller itself does not know the media list; it only forwards the intent
    /// through callbacks owned by the presenter/viewer layer.
    ///
    /// - Parameter gesture: Source swipe gesture recognizer.
    @objc
    private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
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

        default:
            break
        }
    }

    /// Handles downward swipe gestures by closing the VLC viewer.
    ///
    /// - Parameter gesture: Source swipe gesture recognizer.
    @objc
    private func handleCloseSwipe(_ gesture: UISwipeGestureRecognizer) {
        close()
    }

    // MARK: - Playback

    /// Prepares VLC playback without starting it automatically.
    private func start() {
        attachDrawable()
        showPreviewImage()

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
        showControls(animated: false)

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
        showPreviewImage()
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
        if mediaPlayer.isPlaying {
            hidePreviewImage()
        }
    }

    // MARK: - Helpers

    /// Updates the fullscreen preview image shown before VLC starts rendering video.
    private func updatePreviewImage() {
        guard let previewURL,
              previewURL.isFileURL else {
            previewImageView.image = nil
            previewImageView.isHidden = true
            return
        }

        previewImageView.image = UIImage(contentsOfFile: previewURL.path)
        previewImageView.isHidden = previewImageView.image == nil
        previewImageView.alpha = 1
    }

    /// Shows the preview image while VLC prepares the first rendered frame.
    private func showPreviewImage() {
        guard previewImageView.image != nil else {
            previewImageView.isHidden = true
            return
        }

        previewImageView.layer.removeAllAnimations()
        previewImageView.alpha = 1
        previewImageView.isHidden = false
    }

    /// Hides the preview image after VLC starts rendering playback.
    private func hidePreviewImage() {
        guard !previewImageView.isHidden else {
            return
        }

        UIView.animate(
            withDuration: 0.25,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseInOut]
        ) {
            self.previewImageView.alpha = 0
        } completion: { [weak self] _ in
            self?.previewImageView.isHidden = true
        }
    }

    /// Updates the shared controls top actions reference using the real navigation bar.
    private func updateControlsNavigationBar() {
        controlsView.setTopActionsNavigationBar(navigationController?.navigationBar)
    }

    /// Returns whether a point is inside one of the visible controls areas.
    ///
    /// - Parameter location: Point in this controller's root view coordinate space.
    /// - Returns: True when the point is inside top action, center, or bottom controls.
    private func controlsHitFramesContain(_ location: CGPoint) -> Bool {
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

        if controlsHitFramesContain(location) {
            return false
        }

        return true
    }
}
