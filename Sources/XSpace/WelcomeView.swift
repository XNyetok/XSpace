import AppKit

/// The welcome screen, while there are no profiles (the first start): choose a layout, and XSpace
/// makes a profile for each of its panes (see AppStateData.start). Nothing loads before that.
@MainActor
final class WelcomeView: NSView {
    private static let cardsPerRow = 4
    private static let cardSpacing: CGFloat = 12

    /// Called with the layout that was chosen.
    var onChoose: ((GridPreset) -> Void)?
    /// The layouts to choose from: the fixed ones, in menu order.
    private(set) var cards: [LayoutCard] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        let title = Self.label("Selamat datang di XSpace", size: 26, weight: .bold)
        let subtitle = Self.label("Banyak profil browser yang terpisah, dalam satu jendela.", size: 14,
                                  color: .secondaryLabelColor)
        let prompt = Self.label("Pilih tata letak untuk memulai", size: 13, weight: .semibold)

        cards = GridPreset.allCases.filter { $0.slotCount != nil }.map { preset in
            let card = LayoutCard(preset: preset)
            card.target = self
            card.action = #selector(choose(_:))
            return card
        }
        let rows: [NSView] = stride(from: 0, to: cards.count, by: Self.cardsPerRow).map { start in
            let row = NSStackView(views: Array(cards[start..<min(start + Self.cardsPerRow, cards.count)]))
            row.spacing = Self.cardSpacing
            return row
        }
        let grid = NSStackView(views: rows)
        grid.orientation = .vertical
        grid.alignment = .centerX
        grid.spacing = Self.cardSpacing

        let gridWidth = CGFloat(Self.cardsPerRow) * LayoutCard.size.width + CGFloat(Self.cardsPerRow - 1) * Self.cardSpacing
        let footer = NSTextField(wrappingLabelWithString: "Setiap pane adalah satu profil, dengan login, cookie, dan "
                                 + "data situs sendiri yang terpisah total dari profil lain. Tata letak, nama, dan "
                                 + "warna profil bisa diubah kapan saja.")
        footer.font = .systemFont(ofSize: 12)
        footer.textColor = .secondaryLabelColor
        footer.alignment = .center
        footer.preferredMaxLayoutWidth = gridWidth

        let stack = NSStackView(views: [icon, title, subtitle, prompt, grid, footer])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.setCustomSpacing(12, after: icon)
        stack.setCustomSpacing(22, after: subtitle)
        stack.setCustomSpacing(12, after: prompt)
        stack.setCustomSpacing(18, after: grid)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let middle = stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -10)
        middle.priority = .defaultHigh
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 52),
            icon.heightAnchor.constraint(equalToConstant: 52),
            footer.widthAnchor.constraint(equalToConstant: gridWidth),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            middle,
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func choose(_ sender: LayoutCard) {
        onChoose?(sender.preset)
    }

    private static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                              color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        return label
    }
}

/// A layout on the welcome screen: its picture, with every pane in the color of the profile it
/// gets, and its name. The whole card is one button.
@MainActor
final class LayoutCard: NSButton {
    static let size = NSSize(width: 128, height: 96)
    private static let cornerRadius: CGFloat = 12

    let preset: GridPreset
    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    init(preset: GridPreset) {
        self.preset = preset
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        title = ""
        isBordered = false
        setButtonType(.momentaryPushIn)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.borderWidth = 1

        let picture = NSImageView(image: preset.picture(size: NSSize(width: 72, height: 46)))
        let name = NSTextField(labelWithString: preset.title)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        picture.setAccessibilityElement(false)
        name.setAccessibilityElement(false)
        let stack = NSStackView(views: [picture, name])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        let profiles = preset.slotCount ?? 1
        setAccessibilityLabel("\(preset.title), \(profiles) profil")
        toolTip = "Mulai dengan \(profiles) profil"
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// A click on the picture or the name is a click on the card.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden || !frame.contains(point) ? nil : self
    }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let accent = NSColor.controlAccentColor
        let fill = isHighlighted ? accent.withAlphaComponent(0.16)
            : isHovered ? accent.withAlphaComponent(0.07) : NSColor.controlBackgroundColor
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = (isHovered || isHighlighted ? accent : NSColor.separatorColor).cgColor
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()
    }
}
