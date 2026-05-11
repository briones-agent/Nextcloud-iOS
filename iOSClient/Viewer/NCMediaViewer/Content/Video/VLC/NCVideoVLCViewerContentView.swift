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
/// This view does not own playback. It only renders the VLC drawable and controls.
struct NCVideoVLCViewerContentView: View {
    @ObservedObject var controller: NCVideoVLCPlayerController

    let displayFileName: String

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            NCVideoVLCRenderView(controller: controller)
                .ignoresSafeArea()
                .zIndex(0)

            if !controller.isControlsVisible {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .zIndex(1)
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
                .zIndex(2)
            }
        }
        .background(Color.black)
        .animation(.easeInOut(duration: 0.18), value: controller.isControlsVisible)
    }
}

// MARK: - VLC Render View

/// UIKit render surface used by the shared VLC playback controller.
///
/// This view only provides a drawable surface for VLC.
/// It does not own playback, does not stop playback, and does not detach the
/// drawable during dismantle because SwiftUI can dismantle views during rotation.
struct NCVideoVLCRenderView: UIViewRepresentable {
    let controller: NCVideoVLCPlayerController

    func makeUIView(context: Context) -> NCVideoVLCDrawableView {
        let view = NCVideoVLCDrawableView()
        view.backgroundColor = .black
        view.clipsToBounds = true

        view.onDrawableReady = { [weak controller] drawableView, force in
            controller?.attachDrawable(
                drawableView,
                force: force
            )
        }

        controller.attachDrawable(
            view,
            force: true
        )

        return view
    }

    func updateUIView(
        _ view: NCVideoVLCDrawableView,
        context: Context
    ) {
        controller.attachDrawable(
            view,
            force: false
        )

        DispatchQueue.main.async { [weak controller, weak view] in
            guard let view else {
                return
            }

            controller?.attachDrawable(
                view,
                force: false
            )
        }
    }

    static func dismantleUIView(
        _ view: NCVideoVLCDrawableView,
        coordinator: Coordinator
    ) {
        // Do not stop VLC here.
        // Do not detach the drawable here.
        // SwiftUI can call dismantle during rotation/layout rebuilds while
        // playback is still valid.
        view.onDrawableReady = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator { }
}

// MARK: - VLC Drawable View

/// UIView used as VLC drawable target.
///
/// VLC can keep playing audio while losing its video surface after rotation.
/// This view requests a forced drawable rebind only when entering a window or
/// when its drawable size actually changes.
final class NCVideoVLCDrawableView: UIView {
    var onDrawableReady: ((_ view: NCVideoVLCDrawableView, _ force: Bool) -> Void)?

    private var lastDrawableSize: CGSize = .zero

    override func didMoveToWindow() {
        super.didMoveToWindow()

        guard window != nil else {
            return
        }

        requestDrawableAttach(force: true)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        guard bounds.width > 0,
              bounds.height > 0 else {
            return
        }

        let currentSize = bounds.size

        if currentSize != lastDrawableSize {
            lastDrawableSize = currentSize
            requestDrawableAttach(force: true)
        } else {
            requestDrawableAttach(force: false)
        }
    }

    /// Requests VLC drawable attachment immediately and once again after layout settles.
    ///
    /// Rotation can create a valid view before VLC is ready to render into it.
    /// Repeating the attach request gives VLC another chance to bind the video output
    /// to the final drawable surface.
    private func requestDrawableAttach(force: Bool) {
        onDrawableReady?(self, force)

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.window != nil,
                  self.bounds.width > 0,
                  self.bounds.height > 0 else {
                return
            }

            self.onDrawableReady?(self, force)
        }

        guard force else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self,
                  self.window != nil,
                  self.bounds.width > 0,
                  self.bounds.height > 0 else {
                return
            }

            self.onDrawableReady?(self, true)
        }
    }
}
