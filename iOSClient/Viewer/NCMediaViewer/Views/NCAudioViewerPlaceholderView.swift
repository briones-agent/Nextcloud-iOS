// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

// MARK: - Audio Viewer Placeholder View

/// Temporary audio page.
///
/// The real implementation will use an audio player with metadata, artwork,
/// duration, progress, and playback controls.
struct NCAudioViewerPlaceholderView: View {

    // MARK: - Properties

    let metadata: tableMetadata
    let localURL: URL

    // MARK: - Body

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 72, weight: .regular))

            Text("Audio")
                .font(.headline)

            Text(displayFileName)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.65))
        }
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .padding()
    }

    // MARK: - Private

    private var displayFileName: String {
        if !metadata.fileNameView.isEmpty {
            return metadata.fileNameView
        }

        return metadata.fileName
    }
}
