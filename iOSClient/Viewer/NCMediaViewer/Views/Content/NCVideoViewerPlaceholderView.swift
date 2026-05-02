// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

// MARK: - Video Viewer Placeholder View

/// Temporary video page.
///
/// The real implementation will select AVPlayer when possible and VLC otherwise.
struct NCVideoViewerPlaceholderView: View {

    // MARK: - Properties

    let metadata: tableMetadata
    let localURL: URL

    // MARK: - Body

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.circle")
                .font(.system(size: 64, weight: .regular))

            Text("Video")
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
