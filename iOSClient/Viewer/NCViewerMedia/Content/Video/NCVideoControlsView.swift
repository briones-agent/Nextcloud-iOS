// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit

// MARK: - Video Controls View Delegate

/// Receives user actions from the shared video controls view.
///
/// The controls view is playback-engine agnostic.
/// AVFoundation and VLC controllers translate these callbacks into their own player APIs.
protocol NCVideoControlsViewDelegate: AnyObject {
    func videoControlsDidTapSeekBackward(_ controlsView: NCVideoControlsView)
    func videoControlsDidTapPlayPause(_ controlsView: NCVideoControlsView)
    func videoControlsDidTapSeekForward(_ controlsView: NCVideoControlsView)
    func videoControlsDidBeginScrubbing(_ controlsView: NCVideoControlsView)
    func videoControls(_ controlsView: NCVideoControlsView, didScrubTo progress: Float)
    func videoControlsDidEndScrubbing(_ controlsView: NCVideoControlsView, progress: Float)
}

// MARK: - Video Controls View

/// Shared UIKit wrapper used by video engines.
///
/// AVPlayer and VLC still receive a regular `UIView`, while the visual controls are rendered
/// by SwiftUI through an embedded hosting controller. This keeps playback integration stable
/// and makes the custom UI easy to preview and iterate.
final class NCVideoControlsView: UIView {

    // MARK: - Public

    weak var delegate: NCVideoControlsViewDelegate?
    var onPictureInPictureTap: (() -> Void)?

    // MARK: - Hit Test Proxies

    let centerControlsView = UIView()
    let bottomControlsView = UIView()
    let topActionsView = UIView()

    // MARK: - Layout Constants

    fileprivate static let centerControlsWidth: CGFloat = 220
    fileprivate static let centerControlsHeight: CGFloat = 76
    fileprivate static let bottomControlsHeight: CGFloat = 64
    fileprivate static let bottomControlsHorizontalInset: CGFloat = 28
    fileprivate static let bottomControlsBottomInset: CGFloat = 18
    fileprivate static let topActionsHeight: CGFloat = 52
    fileprivate static let topActionsHorizontalInset: CGFloat = 28
    fileprivate static let topActionsButtonSize: CGFloat = 44

    // MARK: - State

    private var state = NCVideoControlsState()
    private var topActionsTopConstraint: NSLayoutConstraint?
    private weak var navigationBar: UINavigationBar?

    private lazy var hostingController = UIHostingController(
        rootView: makeRootView()
    )

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureLayout()
        updateHostedView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayout()
        updateHostedView()
    }

    // MARK: - Public Updates

    /// Updates the play/pause icon.
    ///
    /// - Parameter isPlaying: True when playback is currently active.
    func updatePlayPauseButton(isPlaying: Bool) {
        state.isPlaying = isPlaying
        updateHostedView()
    }

    /// Updates slider and time labels.
    ///
    /// - Parameters:
    ///   - progress: Normalized playback progress between 0 and 1.
    ///   - elapsedText: Formatted elapsed time.
    ///   - remainingText: Formatted remaining time.
    func updateProgress(
        progress: Float,
        elapsedText: String,
        remainingText: String
    ) {
        state.progress = max(0, min(1, progress))
        state.elapsedText = elapsedText
        state.remainingText = remainingText
        updateHostedView()
    }

    /// Enables or disables seeking controls.
    ///
    /// - Parameter isEnabled: True when the current engine supports seeking.
    func setSeekingEnabled(_ isEnabled: Bool) {
        state.isSeekingEnabled = isEnabled
        updateHostedView()
    }

    /// Shows or hides the Picture in Picture action.
    ///
    /// - Parameter isVisible: True when the current playback engine supports Picture in Picture.
    func setPictureInPictureVisible(_ isVisible: Bool) {
        state.isPictureInPictureVisible = isVisible
        updateHostedView()
    }

    /// Updates the navigation bar reference used by the top actions area.
    ///
    /// The controls view converts the real navigation bar frame into its own coordinate space
    /// so top actions remain aligned below the actual viewer chrome across iPhone, iPad,
    /// rotation, and compact/regular layouts.
    ///
    /// - Parameter navigationBar: Navigation bar used as vertical reference for top actions.
    func setTopActionsNavigationBar(_ navigationBar: UINavigationBar?) {
        self.navigationBar = navigationBar
        updateTopActionsPosition()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateTopActionsPosition()
    }

    // MARK: - Configuration

    private func configureLayout() {
        backgroundColor = .clear
        translatesAutoresizingMaskIntoConstraints = false

        configureHostingView()
        configureHitTestProxyViews()
    }

    private func configureHostingView() {
        let hostingView = hostingController.view!
        hostingView.backgroundColor = .clear
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func configureHitTestProxyViews() {
        [centerControlsView, bottomControlsView, topActionsView].forEach { proxyView in
            proxyView.backgroundColor = .clear
            proxyView.isUserInteractionEnabled = false
            proxyView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(proxyView)
        }

        let topActionsTopConstraint = topActionsView.topAnchor.constraint(equalTo: topAnchor)
        self.topActionsTopConstraint = topActionsTopConstraint

        NSLayoutConstraint.activate([
            centerControlsView.centerXAnchor.constraint(equalTo: centerXAnchor),
            centerControlsView.centerYAnchor.constraint(equalTo: centerYAnchor),
            centerControlsView.widthAnchor.constraint(equalToConstant: Self.centerControlsWidth),
            centerControlsView.heightAnchor.constraint(equalToConstant: Self.centerControlsHeight),

            bottomControlsView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.bottomControlsHorizontalInset),
            bottomControlsView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.bottomControlsHorizontalInset),
            bottomControlsView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -Self.bottomControlsBottomInset),
            bottomControlsView.heightAnchor.constraint(equalToConstant: Self.bottomControlsHeight),

            topActionsView.leadingAnchor.constraint(equalTo: leadingAnchor),
            topActionsView.trailingAnchor.constraint(equalTo: trailingAnchor),
            topActionsTopConstraint,
            topActionsView.heightAnchor.constraint(equalToConstant: Self.topActionsHeight)
        ])
    }

    private func updateTopActionsPosition() {
        guard let topActionsTopConstraint else {
            return
        }

        let topOffset: CGFloat

        if let navigationBar {
            let navigationFrame = navigationBar.convert(
                navigationBar.bounds,
                to: self
            )
            topOffset = navigationFrame.maxY
        } else {
            topOffset = safeAreaInsets.top
        }

        guard state.topActionsTopOffset != topOffset else {
            return
        }

        state.topActionsTopOffset = topOffset
        topActionsTopConstraint.constant = topOffset
        updateHostedView()
    }

    private func updateHostedView() {
        hostingController.rootView = makeRootView()
    }

    private func makeRootView() -> NCVideoControlsSwiftUIView {
        NCVideoControlsSwiftUIView(
            state: state,
            onSeekBackward: { [weak self] in
                guard let self else {
                    return
                }
                delegate?.videoControlsDidTapSeekBackward(self)
            },
            onPlayPause: { [weak self] in
                guard let self else {
                    return
                }
                delegate?.videoControlsDidTapPlayPause(self)
            },
            onSeekForward: { [weak self] in
                guard let self else {
                    return
                }
                delegate?.videoControlsDidTapSeekForward(self)
            },
            onScrubBegan: { [weak self] in
                guard let self else {
                    return
                }
                delegate?.videoControlsDidBeginScrubbing(self)
            },
            onScrubChanged: { [weak self] progress in
                guard let self else {
                    return
                }
                state.progress = progress
                updateHostedView()
                delegate?.videoControls(self, didScrubTo: progress)
            },
            onScrubEnded: { [weak self] progress in
                guard let self else {
                    return
                }
                state.progress = progress
                updateHostedView()
                delegate?.videoControlsDidEndScrubbing(self, progress: progress)
            },
            onPictureInPicture: { [weak self] in
                self?.onPictureInPictureTap?()
            }
        )
    }
}

// MARK: - SwiftUI State

private struct NCVideoControlsState: Equatable {
    var isPlaying = false
    var progress: Float = 0
    var elapsedText = "0:00"
    var remainingText = "−0:00"
    var isSeekingEnabled = true
    var isPictureInPictureVisible = false
    var topActionsTopOffset: CGFloat = 0
}

// MARK: - SwiftUI Controls

private struct NCVideoControlsSwiftUIView: View {
    let state: NCVideoControlsState
    let onSeekBackward: () -> Void
    let onPlayPause: () -> Void
    let onSeekForward: () -> Void
    let onScrubBegan: () -> Void
    let onScrubChanged: (Float) -> Void
    let onScrubEnded: (Float) -> Void
    let onPictureInPicture: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                centerControls
                    .position(
                        x: proxy.size.width / 2,
                        y: proxy.size.height / 2
                    )

                bottomControls
                    .frame(height: NCVideoControlsView.bottomControlsHeight)
                    .padding(.horizontal, NCVideoControlsView.bottomControlsHorizontalInset)
                    .position(
                        x: proxy.size.width / 2,
                        y: proxy.size.height - proxy.safeAreaInsets.bottom - NCVideoControlsView.bottomControlsBottomInset - (NCVideoControlsView.bottomControlsHeight / 2)
                    )

                if state.isPictureInPictureVisible {
                    topActions
                        .frame(height: NCVideoControlsView.topActionsHeight)
                        .position(
                            x: NCVideoControlsView.topActionsHorizontalInset + (NCVideoControlsView.topActionsButtonSize / 2),
                            y: state.topActionsTopOffset + (NCVideoControlsView.topActionsHeight / 2)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.clear)
    }

    private var centerControls: some View {
        HStack(spacing: 28) {
            circleButton(
                systemName: "gobackward.10",
                size: 44,
                pointSize: 22,
                isEnabled: state.isSeekingEnabled,
                action: onSeekBackward
            )

            circleButton(
                systemName: state.isPlaying ? "pause.fill" : "play.fill",
                size: 62,
                pointSize: 36,
                isEnabled: true,
                action: onPlayPause
            )

            circleButton(
                systemName: "goforward.10",
                size: 44,
                pointSize: 22,
                isEnabled: state.isSeekingEnabled,
                action: onSeekForward
            )
        }
        .frame(
            width: NCVideoControlsView.centerControlsWidth,
            height: NCVideoControlsView.centerControlsHeight
        )
    }

    private var bottomControls: some View {
        HStack(spacing: 10) {
            timeLabel(state.elapsedText)
                .frame(width: 54)

            Slider(
                value: Binding(
                    get: { Double(state.progress) },
                    set: { onScrubChanged(Float($0)) }
                ),
                in: 0...1,
                onEditingChanged: { isEditing in
                    if isEditing {
                        onScrubBegan()
                    } else {
                        onScrubEnded(state.progress)
                    }
                }
            )
            .disabled(!state.isSeekingEnabled)
            .tint(.black.opacity(0.38))
            .opacity(state.isSeekingEnabled ? 1 : 0.45)

            timeLabel(state.remainingText)
                .frame(width: 58)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white.opacity(0.92))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.16), radius: 18, x: 0, y: 5)
    }

    private var topActions: some View {
        Button(action: onPictureInPicture) {
            Image(systemName: "pip.enter")
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(.black)
                .frame(
                    width: NCVideoControlsView.topActionsButtonSize,
                    height: NCVideoControlsView.topActionsButtonSize
                )
                .background(.white.opacity(0.92))
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.16), radius: 14, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }

    private func circleButton(
        systemName: String,
        size: CGFloat,
        pointSize: CGFloat,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: pointSize, weight: .regular))
                .foregroundStyle(.black.opacity(isEnabled ? 1 : 0.45))
                .frame(width: size, height: size)
                .background(.white.opacity(0.92))
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.16), radius: 14, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private func timeLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .medium, design: .rounded).monospacedDigit())
            .foregroundStyle(.black.opacity(0.72))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }
}

// MARK: - Preview

#Preview("Video Controls") {
    NCVideoControlsPreviewView()
        .frame(width: 393, height: 852)
        .background(Color.black)
        .ignoresSafeArea()
}

private struct NCVideoControlsPreviewView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let containerView = UIView()
        containerView.backgroundColor = .black

        let controlsView = NCVideoControlsView()
        controlsView.translatesAutoresizingMaskIntoConstraints = false
        controlsView.setPictureInPictureVisible(true)
        controlsView.updatePlayPauseButton(isPlaying: true)
        controlsView.updateProgress(
            progress: 0.42,
            elapsedText: "1:24",
            remainingText: "−2:31"
        )

        containerView.addSubview(controlsView)

        NSLayoutConstraint.activate([
            controlsView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            controlsView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            controlsView.topAnchor.constraint(equalTo: containerView.topAnchor),
            controlsView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])

        return containerView
    }

    func updateUIView(
        _ uiView: UIView,
        context: Context
    ) { }
}
