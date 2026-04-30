// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit

// MARK: - Preview Image View

/// Displays a local preview image.
///
/// This view only decodes and renders a local image file.
/// It does not know anything about metadata, downloads, or database state.
struct NCPreviewImageView: View {

    // MARK: - Properties

    let fileURL: URL

    // MARK: - State

    @State private var image: UIImage?

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .task(id: fileURL) {
            await loadImage()
        }
        .onChange(of: fileURL) {
            image = nil
        }
    }

    // MARK: - Private

    /// Loads the preview image from disk.
    private func loadImage() async {
        guard image == nil else {
            return
        }

        image = UIImage(contentsOfFile: fileURL.path)
    }
}
