// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import AVKit
import NextcloudKit
import UIKit

/// Stable Picture in Picture manager for AVPlayer-based video playback.
///
/// This object owns the AVPlayerLayer used as Picture in Picture source and keeps it
/// outside the lifecycle of SwiftUI page views and UIViewControllerRepresentable updates.
/// The goal is to prevent PiP from being invalidated during rotation, paging, or SwiftUI
/// controller rebuilds.
@MainActor
final class NCVideoAVPlayerPictureInPictureManager: NSObject {

    // MARK: - Shared

    static let shared = NCVideoAVPlayerPictureInPictureManager()

    // MARK: - Callbacks

    var onWillStart: (() -> Void)?
    var onDidStart: (() -> Void)?
    var onWillStop: (() -> Void)?
    var onDidStop: (() -> Void)?
    var onFailedToStart: ((Error) -> Void)?

    // MARK: - State

    private let playerLayer = AVPlayerLayer()
    private let hostView = UIView()

    private weak var window: UIWindow?
    private weak var sourceView: UIView?
    private weak var player: AVPlayer?

    private var pictureInPictureController: AVPictureInPictureController?

    var isActive: Bool {
        pictureInPictureController?.isPictureInPictureActive == true
    }

    var isPossible: Bool {
        pictureInPictureController != nil
    }

    // MARK: - Init

    private override init() {
        super.init()
        playerLayer.videoGravity = .resizeAspect
        configureHostView()
    }

    // MARK: - Configuration

    /// Configures the stable PiP source for the current inline player.
    ///
    /// - Parameters:
    ///   - player: AVPlayer used by the inline AVPlayerViewController.
    ///   - window: Window that owns the media viewer hierarchy.
    ///   - sourceView: Inline video view used only to size the hidden PiP source host.
    ///   - allowsPictureInPicture: Whether the current playback context allows PiP.
    func configure(
        player: AVPlayer,
        window: UIWindow?,
        sourceView: UIView?,
        allowsPictureInPicture: Bool
    ) {
        guard allowsPictureInPicture,
              AVPictureInPictureController.isPictureInPictureSupported(),
              let window,
              let sourceView else {
            resetIfInactive()
            return
        }

        self.window = window
        self.sourceView = sourceView

        if self.player !== player {
            self.player = player

            if !isActive {
                playerLayer.player = player
                pictureInPictureController?.delegate = nil
                pictureInPictureController = nil
            }
        }

        updateHostViewFrame()
        configureControllerIfNeeded()
    }

    /// Updates the host view frame from the current source view.
    ///
    /// This should be called during layout while PiP is not active.
    func updateLayoutIfNeeded() {
        guard !isActive else {
            return
        }

        updateHostViewFrame()
    }

    // MARK: - Actions

    /// Starts Picture in Picture if available.
    func start() {
        guard let pictureInPictureController,
              AVPictureInPictureController.isPictureInPictureSupported(),
              !pictureInPictureController.isPictureInPictureActive else {
            return
        }

        pictureInPictureController.startPictureInPicture()
    }

    /// Stops Picture in Picture if active.
    func stop() {
        guard let pictureInPictureController,
              pictureInPictureController.isPictureInPictureActive else {
            return
        }

        pictureInPictureController.stopPictureInPicture()
    }

    /// Toggles Picture in Picture if available.
    func toggle() {
        if isActive {
            stop()
        } else {
            start()
        }
    }

    /// Clears manager resources when PiP is not active.
    func resetIfInactive() {
        guard !isActive else {
            return
        }

        pictureInPictureController?.delegate = nil
        pictureInPictureController = nil
        playerLayer.player = nil
        player = nil
        sourceView = nil
        window = nil
        removeHostView()
    }

    // MARK: - Host View

    private func configureHostView() {
        hostView.backgroundColor = .clear
        hostView.isUserInteractionEnabled = false
        hostView.clipsToBounds = true
    }

    private func updateHostViewFrame() {
        guard let window,
              let sourceView else {
            return
        }

        if hostView.superview !== window {
            hostView.removeFromSuperview()
            window.insertSubview(hostView, at: 0)
        }

        hostView.frame = sourceView.convert(sourceView.bounds, to: window)

        if playerLayer.superlayer !== hostView.layer {
            playerLayer.removeFromSuperlayer()
            hostView.layer.addSublayer(playerLayer)
        }

        playerLayer.frame = hostView.bounds
    }

    private func removeHostView() {
        playerLayer.removeFromSuperlayer()
        hostView.removeFromSuperview()
    }

    private func configureControllerIfNeeded() {
        guard pictureInPictureController == nil else {
            return
        }

        guard let controller = AVPictureInPictureController(playerLayer: playerLayer) else {
            pictureInPictureController = nil
            return
        }

        controller.delegate = self
        pictureInPictureController = controller
    }
}

// MARK: - Picture in Picture Delegate

extension NCVideoAVPlayerPictureInPictureManager: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: .debug,
            message: "VIDEO PiP manager will start",
            consoleOnly: true
        )
        onWillStart?()
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: .debug,
            message: "VIDEO PiP manager did start",
            consoleOnly: true
        )
        onDidStart?()
    }

    func pictureInPictureControllerWillStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: .debug,
            message: "VIDEO PiP manager will stop",
            consoleOnly: true
        )
        onWillStop?()
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: .debug,
            message: "VIDEO PiP manager did stop",
            consoleOnly: true
        )
        onDidStop?()
        resetIfInactive()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        nkLog(
            tag: NCGlobal.shared.logTagViewer,
            emoji: .error,
            message: "VIDEO PiP manager failed to start: \(error.localizedDescription)",
            consoleOnly: true
        )
        onFailedToStart?(error)
        resetIfInactive()
    }
}
