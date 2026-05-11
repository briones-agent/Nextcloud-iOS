// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit
import NextcloudKit

// MARK: - VLC Audio Track

struct NCVideoVLCAudioTrack: Identifiable, Equatable {
    let id: Int32
    let name: String
}

// MARK: - VLC Subtitle Track

struct NCVideoVLCSubtitleTrack: Identifiable, Equatable {
    let id: Int32
    let name: String
}

// MARK: - VLC Video Viewer Content View

/// Displays the singleton VLC player with SwiftUI controls.
///
/// The VLC drawable is hosted by a stable UIKit `UIImageView`, matching the
/// legacy media viewer behavior. SwiftUI is only used for the controls overlay.
struct NCVideoVLCViewerContentView: View {
    @ObservedObject var controller: NCVideoVLCPlayerController

    let displayFileName: String

    var body: some View {
        ZStack {
            NCVideoVLCUIKitContainer(controller: controller)
                .ignoresSafeArea()

            if !controller.isControlsVisible {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        controller.showControls()
                    }
            }

            if controller.isControlsVisible {
                NCVideoVLCControlsView(
                    controller: controller,
                    displayFileName: displayFileName,
                    onBackgroundTap: {
                        controller.toggleControls()
                    }
                )
                .transition(.opacity)
            }
        }
        .background(Color.black)
        .animation(.easeInOut(duration: 0.18), value: controller.isControlsVisible)
    }
}

// MARK: - VLC UIKit Container

/// SwiftUI wrapper around a UIKit-only VLC render controller.
///
/// The wrapped UIKit controller owns a stable `UIImageView` used as VLC drawable.
/// This mirrors the legacy media viewer approach and avoids aggressive drawable
/// rebinds during rotation.
struct NCVideoVLCUIKitContainer: UIViewControllerRepresentable {
    let controller: NCVideoVLCPlayerController

    func makeUIViewController(context: Context) -> NCVideoVLCContainerViewController {
        let viewController = NCVideoVLCContainerViewController()
        viewController.controller = controller

        return viewController
    }

    func updateUIViewController(
        _ viewController: NCVideoVLCContainerViewController,
        context: Context
    ) {
        viewController.controller = controller
        viewController.attachDrawableIfNeeded()
    }

    static func dismantleUIViewController(
        _ viewController: NCVideoVLCContainerViewController,
        coordinator: Coordinator
    ) {
        // Do not stop VLC here.
        // Do not detach the drawable here.
        // SwiftUI can dismantle this wrapper during rotation/layout rebuilds
        // while playback is still valid.
        viewController.controller = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator { }
}

// MARK: - VLC Container View Controller

/// UIKit-only controller used as the VLC drawable host.
///
/// This follows the legacy viewer model:
/// - a stable UIKit controller
/// - a stable `UIImageView` drawable
/// - no drawable detach during rotation
/// - no player reload during rotation
final class NCVideoVLCContainerViewController: UIViewController {
    weak var controller: NCVideoVLCPlayerController?

    private let imageVideoContainer = UIImageView()
    private var didAttachDrawable = false

    override func loadView() {
        let rootView = UIView()
        rootView.backgroundColor = .black
        rootView.clipsToBounds = true
        rootView.isOpaque = true

        imageVideoContainer.backgroundColor = .black
        imageVideoContainer.contentMode = .scaleAspectFit
        imageVideoContainer.clipsToBounds = true
        imageVideoContainer.isOpaque = true
        imageVideoContainer.translatesAutoresizingMaskIntoConstraints = false

        rootView.addSubview(imageVideoContainer)

        NSLayoutConstraint.activate([
            imageVideoContainer.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            imageVideoContainer.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            imageVideoContainer.topAnchor.constraint(equalTo: rootView.topAnchor),
            imageVideoContainer.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])

        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .black
        imageVideoContainer.backgroundColor = .black
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        attachDrawableIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // Rotation should only update UIKit layout.
        // Do not detach, force-rebind, or reload VLC here.
        attachDrawableIfNeeded()
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
            self?.attachDrawableIfNeeded()
        })
    }

    /// Attaches the stable drawable image view to VLC if needed.
    ///
    /// This intentionally avoids `drawable = nil` and avoids force rebinds.
    /// The old media viewer used the same stable-view approach.
    func attachDrawableIfNeeded() {
        guard imageVideoContainer.window != nil,
              imageVideoContainer.bounds.width > 0,
              imageVideoContainer.bounds.height > 0 else {
            return
        }

        guard let controller else {
            return
        }

        if didAttachDrawable,
           controller.isDrawableAttached(to: imageVideoContainer) {
            return
        }

        controller.attachDrawableIfNeeded(imageVideoContainer)
        didAttachDrawable = true
    }
}
