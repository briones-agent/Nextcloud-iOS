// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AVKit
import NextcloudKit

// MARK: - AVFoundation Video Player Content View

/// SwiftUI wrapper around `AVPlayerViewController`.
///
/// This view renders a controller-owned `AVPlayer`.
/// It does not own or stop playback resources, because SwiftUI can dismantle
/// and recreate the view controller during rotation or layout rebuilds.
struct NCVideoAVPlayerContentView: UIViewControllerRepresentable {
    let player: AVPlayer
    let allowsPictureInPicture: Bool
    let shouldAutoPlay: Bool

    init(
        player: AVPlayer,
        allowsPictureInPicture: Bool = true,
        shouldAutoPlay: Bool = false
    ) {
        self.player = player
        self.allowsPictureInPicture = allowsPictureInPicture
        self.shouldAutoPlay = shouldAutoPlay
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()

        configure(
            controller,
            context: context
        )

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

        configure(
            controller,
            context: context
        )

        context.coordinator.playIfNeeded(
            player: player,
            shouldAutoPlay: shouldAutoPlay
        )
    }

    static func dismantleUIViewController(
        _ controller: AVPlayerViewController,
        coordinator: Coordinator
    ) {
        // Do not pause or clear the player here.
        // SwiftUI can dismantle this controller during rotation while playback is still valid.
        controller.delegate = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Private

    private func configure(
        _ controller: AVPlayerViewController,
        context: Context
    ) {
        controller.player = player
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = allowsPictureInPicture
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        controller.requiresLinearPlayback = false
        controller.videoGravity = .resizeAspect
        controller.view.backgroundColor = .black
        controller.delegate = context.coordinator
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        private static var autoplayedPlayerIDs = Set<ObjectIdentifier>()
        private var didAutoplay = false

        func resetAutoplay() {
            didAutoplay = false
        }

        func playIfNeeded(
            player: AVPlayer,
            shouldAutoPlay: Bool
        ) {
            let playerIdentifier = ObjectIdentifier(player)

            guard shouldAutoPlay,
                  !didAutoplay,
                  !Self.autoplayedPlayerIDs.contains(playerIdentifier) else {
                return
            }

            didAutoplay = true
            Self.autoplayedPlayerIDs.insert(playerIdentifier)

            DispatchQueue.main.async {
                guard player.timeControlStatus != .playing else {
                    return
                }

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
