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

    // MARK: - Views

    private let drawableView = UIView()

    // MARK: - VLC

    private let mediaPlayer = VLCMediaPlayer()

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

        NSLayoutConstraint.activate([
            drawableView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            drawableView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            drawableView.topAnchor.constraint(equalTo: rootView.topAnchor),
            drawableView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])

        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .black

        configureNavigationItem()
        configureAudioSession()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        start()
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
//        mediaPlayer.play()

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
