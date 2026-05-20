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
    private weak var navigationBar: UINavigationBar?
    private var navigationBarConstraints: [NSLayoutConstraint] = []
    private var centerXConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?

    init() {
        let effect: UIVisualEffect

        if #available(iOS 26.0, *) {
            let glassEffect = UIGlassEffect()
            glassEffect.isInteractive = false
            effect = glassEffect
        } else {
            effect = UIBlurEffect(style: .systemChromeMaterial)
        }

        super.init(effect: effect)

        configureView()
        configureLabels()
        configureStackView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        layer.cornerRadius = bounds.height / 2
    }

    /// Attaches the floating title view to the provided navigation bar.
    ///
    /// The title is installed as a navigation bar subview and can then align itself
    /// against the real visible bar button containers.
    ///
    /// - Parameters:
    ///   - navigationBar: Navigation bar that owns the floating title view.
    ///   - widthMultiplier: Maximum title width relative to the navigation bar width.
    ///   - verticalOffset: Vertical adjustment applied to the navigation bar top edge.
    func attach(
        to navigationBar: UINavigationBar,
        widthMultiplier: CGFloat = 0.36,
        verticalOffset: CGFloat = 0
    ) {
        if self.navigationBar !== navigationBar || superview !== navigationBar {
            navigationBarConstraints.forEach { $0.isActive = false }
            navigationBarConstraints.removeAll()
            removeFromSuperview()
            navigationBar.addSubview(self)

            let centerXConstraint = centerXAnchor.constraint(equalTo: navigationBar.centerXAnchor)
            let heightConstraint = heightAnchor.constraint(equalToConstant: navigationItemHeight(in: navigationBar))
            self.centerXConstraint = centerXConstraint
            self.heightConstraint = heightConstraint

            navigationBarConstraints = [
                centerXConstraint,
                topAnchor.constraint(equalTo: navigationBar.topAnchor, constant: verticalOffset),
                heightConstraint,
                widthAnchor.constraint(lessThanOrEqualTo: navigationBar.widthAnchor, multiplier: widthMultiplier)
            ]
            NSLayoutConstraint.activate(navigationBarConstraints)
            self.navigationBar = navigationBar
        }

        navigationBar.bringSubviewToFront(self)
        updateNavigationItemHeight()
        updateHorizontalAlignment()
    }

    /// Resets the horizontal title position to the navigation bar center.
    func updateHorizontalAlignment() {
        centerXConstraint?.constant = 0
    }

    /// Updates the title height using the visible navigation item height.
    func updateNavigationItemHeight() {
        guard let navigationBar else {
            return
        }

        heightConstraint?.constant = navigationItemHeight(in: navigationBar)
    }

    /// Returns the best visible navigation item height for the provided navigation bar.
    ///
    /// - Parameter navigationBar: Navigation bar containing the title and bar button items.
    /// - Returns: Height used by visible navigation items, falling back to `44` points.
    private func navigationItemHeight(in navigationBar: UINavigationBar) -> CGFloat {
        let heights = navigationBar.subviews.flatMap { subview in
            navigationItemHeights(
                from: subview,
                in: navigationBar
            )
        }

        return heights.max() ?? navigationBar.bounds.height
    }

    /// Recursively collects visible navigation item heights from the navigation bar hierarchy.
    ///
    /// - Parameters:
    ///   - view: Current hierarchy node.
    ///   - navigationBar: Navigation bar used as coordinate target.
    /// - Returns: Visible item heights in navigation bar coordinates.
    private func navigationItemHeights(
        from view: UIView,
        in navigationBar: UINavigationBar
    ) -> [CGFloat] {
        guard view !== self,
              !view.isDescendant(of: self),
              !view.isHidden,
              view.alpha > 0.01,
              view.bounds.width > 0,
              view.bounds.height > 0 else {
            return []
        }

        let frame = view.convert(view.bounds, to: navigationBar)
        let isVisibleNavigationFrame = frame.minY >= -1 &&
            frame.maxY <= navigationBar.bounds.height + 1 &&
            frame.height > 20 &&
            frame.width > 20 &&
            frame.width < navigationBar.bounds.width * 0.6

        let childHeights = view.subviews.flatMap { subview in
            navigationItemHeights(
                from: subview,
                in: navigationBar
            )
        }

        if isVisibleNavigationFrame {
            return childHeights + [frame.height]
        }

        return childHeights
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
        layer.cornerRadius = 22
        layer.cornerCurve = .continuous
        backgroundColor = .clear
        if #available(iOS 26.0, *) {
            contentView.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.32)
        } else {
            contentView.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.78)
        }
        contentView.layoutMargins = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
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
        stackView.distribution = .equalCentering
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
