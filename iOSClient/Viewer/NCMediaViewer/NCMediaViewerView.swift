// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit

// MARK: - Media Viewer View

/// Main SwiftUI media viewer.
///
/// This view owns the `NCMediaViewerModel` as a `StateObject`.
/// Paging is handled by `NCMediaViewerPagingView`, which is backed by
/// `UICollectionView` to support large virtualized media lists.
///
/// When a `viewerTransitionSource` is provided, the viewer performs an opening
/// thumbnail-to-fullscreen animation before revealing the real paging content.
struct NCMediaViewerView: View {

    // MARK: - State

    @StateObject private var model: NCMediaViewerModel

    @State private var isOpeningAnimationRunning = false
    @State private var isOpeningAnimationCompleted: Bool

    // MARK: - Transition

    private let viewerTransitionSource: NCViewerTransitionSource?

    // MARK: - Constants

    private let openingAnimationDuration: TimeInterval = 0.28

    // MARK: - Init

    /// Creates the media viewer view.
    ///
    /// - Parameters:
    ///   - model: Media viewer model containing page state and loading logic.
    ///   - viewerTransitionSource: Optional thumbnail source used for the opening animation.
    init(
        model: NCMediaViewerModel,
        viewerTransitionSource: NCViewerTransitionSource? = nil
    ) {
        _model = StateObject(wrappedValue: model)
        self.viewerTransitionSource = viewerTransitionSource
        self._isOpeningAnimationCompleted = State(initialValue: viewerTransitionSource == nil)
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                    .ignoresSafeArea()

                NCMediaViewerPagingView(model: model)
                    .opacity(isOpeningAnimationCompleted ? 1 : 0)
                    .ignoresSafeArea()

                if let viewerTransitionSource, !isOpeningAnimationCompleted {
                    openingTransitionView(
                        viewerTransitionSource: viewerTransitionSource,
                        containerSize: proxy.size
                    )
                }
            }
            .background(Color.black)
            .ignoresSafeArea()
            .statusBarHidden(true)
            .task {
                await model.loadSelectedPageIfNeeded()
                startOpeningAnimationIfNeeded()
            }
        }
    }

    // MARK: - Opening Transition

    @ViewBuilder
    private func openingTransitionView(
        viewerTransitionSource: NCViewerTransitionSource,
        containerSize: CGSize
    ) -> some View {
        let destinationFrame = aspectFitFrame(
            imageSize: viewerTransitionSource.image.size,
            containerSize: containerSize
        )

        let currentFrame = isOpeningAnimationRunning
            ? destinationFrame
            : viewerTransitionSource.sourceFrame

        let currentCornerRadius = isOpeningAnimationRunning
            ? 0
            : viewerTransitionSource.cornerRadius

        Image(uiImage: viewerTransitionSource.image)
            .resizable()
            .scaledToFill()
            .frame(
                width: currentFrame.width,
                height: currentFrame.height
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: currentCornerRadius,
                    style: .continuous
                )
            )
            .position(
                x: currentFrame.midX,
                y: currentFrame.midY
            )
            .ignoresSafeArea()
    }

    /// Starts the opening animation when a transition source is available.
    private func startOpeningAnimationIfNeeded() {
        guard viewerTransitionSource != nil else {
            isOpeningAnimationCompleted = true
            return
        }

        guard !isOpeningAnimationRunning,
              !isOpeningAnimationCompleted else {
            return
        }

        withAnimation(.easeInOut(duration: openingAnimationDuration)) {
            isOpeningAnimationRunning = true
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(openingAnimationDuration))
            isOpeningAnimationCompleted = true
        }
    }

    /// Computes the aspect-fit frame for an image inside the viewer container.
    ///
    /// - Parameters:
    ///   - imageSize: Source image size.
    ///   - containerSize: Fullscreen container size.
    /// - Returns: Aspect-fit destination frame.
    private func aspectFitFrame(
        imageSize: CGSize,
        containerSize: CGSize
    ) -> CGRect {
        guard imageSize.width > 0,
              imageSize.height > 0,
              containerSize.width > 0,
              containerSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }

        let widthRatio = containerSize.width / imageSize.width
        let heightRatio = containerSize.height / imageSize.height
        let ratio = min(widthRatio, heightRatio)

        let fittedSize = CGSize(
            width: imageSize.width * ratio,
            height: imageSize.height * ratio
        )

        return CGRect(
            x: (containerSize.width - fittedSize.width) * 0.5,
            y: (containerSize.height - fittedSize.height) * 0.5,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }
}
