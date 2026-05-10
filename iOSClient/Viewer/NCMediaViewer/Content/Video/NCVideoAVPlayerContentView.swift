// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AVKit
import NextcloudKit

// MARK: - AVFoundation Video Player Content View

/// SwiftUI wrapper around `AVPlayerViewController`.
///
/// This view is used when AVFoundation can play the video URL.
/// It provides native playback controls and Picture in Picture support where available.
///
/// Picture in Picture requires the app target to enable:
/// `Background Modes` -> `Audio, AirPlay, and Picture in Picture`.
struct NCVideoAVPlayerContentView: UIViewControllerRepresentable {
    let player: AVPlayer
    let allowsPictureInPicture: Bool
    let shouldAutoPlay: Bool

    init(
        player: AVPlayer,
        allowsPictureInPicture: Bool = true,
        shouldAutoPlay: Bool = true
    ) {
        self.player = player
        self.allowsPictureInPicture = allowsPictureInPicture
        self.shouldAutoPlay = shouldAutoPlay
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()

        controller.player = player
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = allowsPictureInPicture
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        controller.requiresLinearPlayback = false
        controller.videoGravity = .resizeAspect
        controller.view.backgroundColor = .black
        controller.delegate = context.coordinator

        context.coordinator.playIfNeeded(
            player: player,
            shouldAutoPlay: shouldAutoPlay
        )

        return controller
    }

    func updateUIViewController(
        _ controller: AVPlayerViewController,
        context: Context
    ) {
        if controller.player !== player {
            controller.player = player
            context.coordinator.resetAutoplay()
        }

        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = allowsPictureInPicture
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        controller.requiresLinearPlayback = false
        controller.videoGravity = .resizeAspect
        controller.view.backgroundColor = .black
        controller.delegate = context.coordinator

        context.coordinator.playIfNeeded(
            player: player,
            shouldAutoPlay: shouldAutoPlay
        )
    }

    static func dismantleUIViewController(
        _ controller: AVPlayerViewController,
        coordinator: Coordinator
    ) {
        controller.player?.pause()
        controller.delegate = nil
        controller.player = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        private var didAutoplay = false

        func resetAutoplay() {
            didAutoplay = false
        }

        func playIfNeeded(
            player: AVPlayer,
            shouldAutoPlay: Bool
        ) {
            guard shouldAutoPlay,
                  !didAutoplay else {
                return
            }

            didAutoplay = true

            DispatchQueue.main.async {
                player.play()

                nkLog(
                    tag: NCGlobal.shared.logTagViewer,
                    emoji: .debug,
                    message: "VIDEO AVPlayer autoplay",
                    consoleOnly: true
                )
            }
        }

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
    }
}
