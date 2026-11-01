import AppKit

/// A pane's start page, while its profile has no page yet. Laid out like a browser's new tab page:
/// the profile's name where a browser shows its logo, and a search box below it. Nothing is loaded
/// until something is typed there or in the pane's address field.
@MainActor
final class StartPageView: NSView {
    /// The search box's field. It gets the keyboard focus when the pane does.
    var field: NSTextField { box.field }
    /// Called with the typed text when Return is pressed.
    var onSubmit: ((String) -> Void)?

    private let name = NSTextField(labelWithString: "")
    private let box = SearchBox()
    private var middle: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        name.font = .systemFont(ofSize: 36, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        box.field.target = self
        box.field.action = #selector(submitted(_:))

        let stack = NSStackView(views: [name, box])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // As wide as fits, up to 560 pt; a little above the middle, as in a browser.
        let width = box.widthAnchor.constraint(equalToConstant: 560)
        width.priority = .defaultHigh
        let middle = stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -24)
        middle.priority = .defaultHigh
        self.middle = middle
        NSLayoutConstraint.activate([
            width,
            box.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
            name.widthAnchor.constraint(lessThanOrEqualTo: box.widthAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            middle,
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows the profile's name, in its color.
    func show(_ profile: Profile) {
        name.stringValue = profile.name
        name.textColor = profile.color
        field.setAccessibilityLabel("Alamat untuk profil \(profile.name)")
    }

    // The background is the layer's: drawing it would also paint outside the view (views do not
    // clip their drawing to their bounds), over the pane's toolbar.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }

    override func layout() {
        // In a low pane only the search box, which matters most, in the middle.
        let low = bounds.height < 150
        name.isHidden = low
        middle?.constant = low ? 0 : -24
        super.layout()
    }

    /// A click anywhere on the page goes to the search box, and makes this pane the one you are in.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
    }

    @objc private func submitted(_ sender: NSTextField) {
        onSubmit?(sender.stringValue)
    }
}

/// The search box of the start page, as on a browser's new tab page: a rounded box with a
/// magnifying glass and a borderless field. Its edge shows the accent color while you type in it.
@MainActor
final class SearchBox: NSView {
    static let height: CGFloat = 46

    let field = SearchBoxField()
    private var isHovered = false {
        didSet { needsDisplay = true }
    }
    private var isEditing = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 16)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.sendsActionOnEndEditing = false
        field.placeholderString = PaneView.addressPlaceholder
        field.translatesAutoresizingMaskIntoConstraints = false
        field.onEditingChange = { [weak self] editing in self?.isEditing = editing }

        addSubview(icon)
        addSubview(field)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        // A light tint of the text color, a little stronger under the mouse.
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let tint = (dark ? 0.08 : 0.05) + (isHovered && !isEditing ? 0.04 : 0)
        layer.cornerRadius = Self.height / 2
        layer.backgroundColor = (dark ? NSColor.white : NSColor.black).withAlphaComponent(tint).cgColor
        layer.borderWidth = isEditing ? 2 : 0
        layer.borderColor = NSColor.controlAccentColor.cgColor
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// A click on the magnifying glass or the edge goes to the field.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }
}

/// The field of the search box. It tells when you start and stop typing in it (it has the keyboard
/// focus), since a borderless field draws no focus ring that fits the box.
@MainActor
final class SearchBoxField: NSTextField {
    var onEditingChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onEditingChange?(true) }
        return became
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        // After Return the field keeps the focus (and edits again).
        onEditingChange?(currentEditor() != nil)
    }
}
