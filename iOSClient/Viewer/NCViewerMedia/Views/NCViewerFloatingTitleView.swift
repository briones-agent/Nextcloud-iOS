// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit

/// Floating title view used by media viewer controllers.
///
/// The view is independent from `UINavigationItem.titleView`, so it can be reused
/// by the main media viewer, AVPlayer fullscreen controller, and VLC fullscreen controller.
final class NCViewerFloatingTitleView: UIVisualEffectView {
    private let primaryLabel = UILabel()
    private let secondaryLabel = UILabel()
    private let stackView = UIStackView()

    override init(effect: UIVisualEffect? = UIBlurEffect(style: .systemChromeMaterial)) {
        super.init(effect: effect)

        configureView()
        configureLabels()
        configureStackView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Updates the visible title content.
    ///
    /// - Parameters:
    ///   - primaryText: Main title text displayed on the first line.
    ///   - secondaryText: Optional subtitle text displayed on the second line.
    func update(primaryText: String?, secondaryText: String?) {
        let normalizedPrimaryText = primaryText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSecondaryText = secondaryText?.trimmingCharacters(in: .whitespacesAndNewlines)

        primaryLabel.text = normalizedPrimaryText
        secondaryLabel.text = normalizedSecondaryText
        secondaryLabel.isHidden = normalizedSecondaryText?.isEmpty ?? true
        isHidden = normalizedPrimaryText?.isEmpty ?? true

        accessibilityLabel = [normalizedPrimaryText, normalizedSecondaryText]
            .compactMap { text in
                guard let text, !text.isEmpty else { return nil }
                return text
            }
            .joined(separator: ", ")
    }

    /// Configures the visual container.
    private func configureView() {
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        backgroundColor = .clear
        contentView.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.78)
        contentView.layoutMargins = UIEdgeInsets(top: 5, left: 16, bottom: 5, right: 16)
        isAccessibilityElement = true
    }

    /// Configures the primary and secondary labels.
    private func configureLabels() {
        primaryLabel.font = .preferredFont(forTextStyle: .subheadline)
        primaryLabel.textColor = NCBrandColor.shared.textColor
        primaryLabel.textAlignment = .center
        primaryLabel.adjustsFontForContentSizeCategory = true
        primaryLabel.lineBreakMode = .byTruncatingMiddle
        primaryLabel.numberOfLines = 1

        secondaryLabel.font = .preferredFont(forTextStyle: .caption2)
        secondaryLabel.textColor = NCBrandColor.shared.textColor.withAlphaComponent(0.85)
        secondaryLabel.textAlignment = .center
        secondaryLabel.adjustsFontForContentSizeCategory = true
        secondaryLabel.lineBreakMode = .byTruncatingTail
        secondaryLabel.numberOfLines = 1
    }

    /// Configures the vertical label stack.
    private func configureStackView() {
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.alignment = .center
        stackView.distribution = .fill
        stackView.spacing = 0

        stackView.addArrangedSubview(primaryLabel)
        stackView.addArrangedSubview(secondaryLabel)
        contentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor)
        ])
    }
}
