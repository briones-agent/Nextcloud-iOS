// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit

// MARK: - Viewer Transition Source

/// Describes the visual source used to animate the media viewer presentation.
///
/// The transition starts from the thumbnail currently visible in the source UI
/// and expands it to the final image frame inside the fullscreen viewer.
struct NCViewerTransitionSource {

    /// Image currently visible in the source cell.
    let image: UIImage

    /// Thumbnail frame converted to window coordinates.
    let sourceFrame: CGRect

    /// Corner radius used by the source thumbnail.
    let cornerRadius: CGFloat

    /// Creates a media viewer transition source.
    ///
    /// - Parameters:
    ///   - image: Image currently visible in the source cell.
    ///   - sourceFrame: Thumbnail frame converted to window coordinates.
    ///   - cornerRadius: Corner radius used by the source thumbnail.
    init(
        image: UIImage,
        sourceFrame: CGRect,
        cornerRadius: CGFloat = 0
    ) {
        self.image = image
        self.sourceFrame = sourceFrame
        self.cornerRadius = cornerRadius
    }
}

// MARK: - Viewer Appearance

enum NCViewerBackgroundStyle {
    /// Uses the current system appearance.
    case system
    /// Always uses black, useful for image/video viewers.
    case black
    /// Always uses white, useful for document-like viewers.
    case white
    /// Uses a custom UIKit color.
    case custom(UIColor)
}

extension UIColor {

    /// Returns the background color for a viewer background style.
    ///
    /// - Parameter style: Viewer background style.
    /// - Returns: Resolved UIKit background color.
    static func ncViewerBackground(_ style: NCViewerBackgroundStyle = .system) -> UIColor {
        switch style {
        case .system:
            return .systemBackground

        case .black:
            return .black

        case .white:
            return .white

        case .custom(let color):
            return color
        }
    }
}

extension Color {
    /// Returns the background color for a viewer background style.
    ///
    /// - Parameter style: Viewer background style.
    /// - Returns: Resolved SwiftUI background color.
    static func ncViewerBackground(_ style: NCViewerBackgroundStyle = .system) -> Color {
        Color(uiColor: .ncViewerBackground(style))
    }
}
