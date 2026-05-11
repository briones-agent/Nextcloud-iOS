// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit

// MARK: - VLC Controls View

/// SwiftUI controls overlay for VLC playback.
///
/// This view does not own the VLC player. It only sends control commands to the
/// singleton VLC playback controller.
struct NCVideoVLCControlsView: View {
    @ObservedObject var controller: NCVideoVLCPlayerController

    let displayFileName: String
    let onBackgroundTap: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    .black.opacity(0.55),
                    .clear,
                    .black.opacity(0.7)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture {
                    onBackgroundTap()
                }

            VStack {
                topBar

                Spacer()

                centerControls

                Spacer()

                bottomControls
            }
            .padding(.horizontal, 18)
            .padding(.top, topPadding)
            .padding(.bottom, bottomPadding)
            .foregroundStyle(.white)
        }
    }

    // MARK: - Sections

    private var topBar: some View {
        HStack(spacing: 12) {
            Text(displayFileName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            subtitleTrackButton
            audioTrackButton
        }
        .foregroundStyle(.white.opacity(0.95))
    }

    private var subtitleTrackButton: some View {
        Menu {
            if controller.subtitleTracks.isEmpty {
                Button("No subtitles") { }
                    .disabled(true)
            } else {
                ForEach(controller.subtitleTracks) { track in
                    Button {
                        controller.selectSubtitleTrack(index: track.id)
                    } label: {
                        HStack {
                            Text(track.name)

                            if track.id == controller.currentSubtitleTrackIndex {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "captions.bubble.fill")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.55))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var audioTrackButton: some View {
        Menu {
            if controller.audioTracks.isEmpty {
                Button("No audio tracks") { }
                    .disabled(true)
            } else {
                ForEach(controller.audioTracks) { track in
                    Button {
                        controller.selectAudioTrack(index: track.id)
                    } label: {
                        HStack {
                            Text(track.name)

                            if track.id == controller.currentAudioTrackIndex {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.55))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var centerControls: some View {
        HStack(spacing: 36) {
            Button {
                controller.skip(by: -15)
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 36, weight: .regular))
            }
            .buttonStyle(.plain)

            Button {
                controller.togglePlayback()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 72, weight: .regular))
            }
            .buttonStyle(.plain)

            Button {
                controller.skip(by: 15)
            } label: {
                Image(systemName: "goforward.15")
                    .font(.system(size: 36, weight: .regular))
            }
            .buttonStyle(.plain)
        }
        .shadow(radius: 4)
    }

    private var bottomControls: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { controller.currentTime },
                    set: { controller.currentTime = $0 }
                ),
                in: 0...max(controller.duration, 1),
                onEditingChanged: { isEditing in
                    controller.showControls()

                    if !isEditing {
                        controller.seek(to: controller.currentTime)
                    }
                }
            )
            .disabled(controller.duration <= 0)

            HStack {
                Text(formatTime(controller.currentTime))

                Spacer()

                Text(formatTime(controller.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.75))
        }
    }

    // MARK: - Helpers

    /// Top padding used to keep VLC controls below the navigation bar.
    private var topPadding: CGFloat {
        let windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }

        let window = windowScene?.windows.first { $0.isKeyWindow }
        let safeTop = window?.safeAreaInsets.top ?? 0

        return safeTop + 64
    }

    private var bottomPadding: CGFloat {
        let windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }

        let window = windowScene?.windows.first { $0.isKeyWindow }
        let safeBottom = window?.safeAreaInsets.bottom ?? 0

        return max(safeBottom + 8, 24)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite,
              seconds >= 0 else {
            return "00:00"
        }

        let totalSeconds = Int(seconds.rounded())
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60

        return String(
            format: "%02d:%02d",
            minutes,
            remainingSeconds
        )
    }
}
