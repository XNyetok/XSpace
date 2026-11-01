import AppKit

/// What the start page asks for, for its profile's shortcuts (see MainWindowController.editShortcuts).
enum ShortcutEdit: Equatable {
    /// A new shortcut; its dialog starts with `suggestion` (the page behind the start page).
    case add(suggestion: Shortcut?)
    case change(Shortcut)
    case remove(Shortcut)
}

/// A pane's start page: while the pane has no page yet, and after Beranda. Laid out like a browser's
/// new tab page: the profile's name where a browser shows its logo, a search box, and the profile's
/// shortcuts. Nothing is loaded until something is opened from it.
@MainActor
final class StartPageView: NSView {
    private static let maximumWidth: CGFloat = 560
    private static let nameSpacing: CGFloat = 24
    private static let tilesSpacing: CGFloat = 28

    /// The search box's field. It gets the keyboard focus when the pane does.
    var field: NSTextField { box.field }
    /// Called with the typed text when Return is pressed.
    var onSubmit: ((String) -> Void)?
    /// A shortcut was clicked.
    var onOpen: ((URL) -> Void)?
    /// Adding, changing or removing a shortcut.
    var onEdit: ((ShortcutEdit) -> Void)?
    /// What a new shortcut starts with: the page behind the start page, if any.
    var suggestion: Shortcut?

    private let name = NSTextField(labelWithString: "")
    private let box = SearchBox()
    private let grid = ShortcutGrid()
    private var middle: NSLayoutConstraint?
    private var gridHeight: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        name.font = .systemFont(ofSize: 36, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        box.field.target = self
        box.field.action = #selector(submitted(_:))

        let stack = NSStackView(views: [name, box, grid])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Self.nameSpacing
        stack.setCustomSpacing(Self.tilesSpacing, after: box)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // As wide as fits, up to 560 pt; a little above the middle, as in a browser.
        let width = box.widthAnchor.constraint(equalToConstant: Self.maximumWidth)
        width.priority = .defaultHigh
        let middle = stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -24)
        middle.priority = .defaultHigh
        self.middle = middle
        let gridHeight = grid.heightAnchor.constraint(equalToConstant: 0)
        self.gridHeight = gridHeight
        NSLayoutConstraint.activate([
            width,
            box.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
            name.widthAnchor.constraint(lessThanOrEqualTo: box.widthAnchor),
            grid.widthAnchor.constraint(equalTo: box.widthAnchor),
            gridHeight,
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

    /// Shows the shortcuts. Editable: their menus change or remove them, and while there is room a
    /// last tile adds one.
    func show(shortcuts: [Shortcut], editable: Bool) {
        var tiles = shortcuts.map { shortcut in
            let tile = ShortcutTile(shortcut: shortcut, editable: editable)
            tile.onClick = { [weak self] in
                if let url = URL(string: shortcut.url) { self?.onOpen?(url) }
            }
            tile.onChange = { [weak self] in self?.onEdit?(.change(shortcut)) }
            tile.onRemove = { [weak self] in self?.onEdit?(.remove(shortcut)) }
            return tile
        }
        if editable && shortcuts.count < Shortcut.limit {
            let add = ShortcutTile(shortcut: nil, editable: false)
            add.onClick = { [weak self] in
                guard let self else { return }
                self.onEdit?(.add(suggestion: self.suggestion))
            }
            tiles.append(add)
        }
        grid.setTiles(tiles)
        needsLayout = true
    }

    // The background is the layer's: drawing it would also paint outside the view (views do not
    // clip their drawing to their bounds), over the pane's toolbar.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }

    /// What fits in the pane: the search box always; then the name and every row of shortcuts. In a
    /// lower pane the name goes first (the toolbar shows it too), then rows of shortcuts.
    override func layout() {
        let available = bounds.height - 16
        let columns = ShortcutGrid.columns(forWidth: min(Self.maximumWidth, bounds.width - 40))
        let nameHeight = name.intrinsicContentSize.height + Self.nameSpacing
        func height(name showsName: Bool, rows: Int) -> CGFloat {
            (showsName ? nameHeight : 0) + SearchBox.height
                + (rows > 0 ? Self.tilesSpacing + CGFloat(rows) * ShortcutGrid.tileSize.height : 0)
        }
        var rows = grid.rowCount(columns: columns)
        let showsName = height(name: true, rows: rows) <= available
        while rows > 0, height(name: showsName, rows: rows) > available { rows -= 1 }
        name.isHidden = !showsName
        grid.isHidden = rows == 0
        grid.visibleRows = rows
        gridHeight?.constant = CGFloat(rows) * ShortcutGrid.tileSize.height
        middle?.constant = showsName ? -24 : 0
        super.layout()
    }

    /// A click anywhere on the page goes to the search box, and makes this pane the one you are in.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
    }

    @objc private func submitted(_ sender: NSTextField) {
        onSubmit?(sender.stringValue)
    }

    // MARK: Hooks for the automated UI test (--selftest-ui)

    var testTileTitles: [String] {
        grid.isHidden ? [] : grid.tiles.filter { !$0.isHidden }.map(\.labelText)
    }

    func testTile(_ title: String) -> ShortcutTile? {
        grid.tiles.first { $0.labelText == title }
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

/// The shortcuts of the start page in rows of up to five, each row centered. Only the rows that fit
/// (`visibleRows`) are shown.
@MainActor
final class ShortcutGrid: NSView {
    static let tileSize = NSSize(width: 112, height: 104)
    private static let maximumColumns = 5

    /// The shortcuts, then the tile that adds one.
    private(set) var tiles: [ShortcutTile] = []
    var visibleRows = 0 {
        didSet { if visibleRows != oldValue { needsLayout = true } }
    }

    static func columns(forWidth width: CGFloat) -> Int {
        max(1, min(maximumColumns, Int(width / tileSize.width)))
    }

    func rowCount(columns: Int) -> Int {
        (tiles.count + columns - 1) / columns
    }

    func setTiles(_ newTiles: [ShortcutTile]) {
        tiles.forEach { $0.removeFromSuperview() }
        tiles = newTiles
        newTiles.forEach { addSubview($0) }
        needsLayout = true
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let columns = Self.columns(forWidth: bounds.width)
        let size = Self.tileSize
        for (index, tile) in tiles.enumerated() {
            let row = index / columns
            let inRow = min(columns, tiles.count - row * columns)
            let left = ((bounds.width - CGFloat(inRow) * size.width) / 2).rounded()
            tile.isHidden = row >= visibleRows
            tile.frame = NSRect(x: left + CGFloat(index % columns) * size.width, y: CGFloat(row) * size.height,
                                width: size.width, height: size.height)
        }
    }
}

/// A shortcut on the start page, as in a browser: a round icon with the first letter of its name,
/// and the name below it. Its menu (right-click, or the ⋯ button under the mouse) changes or removes
/// it. Without a shortcut it is the tile that adds one.
@MainActor
final class ShortcutTile: NSButton {
    private static let iconSize: CGFloat = 48

    var onClick: (() -> Void)?
    var onChange: (() -> Void)?
    var onRemove: (() -> Void)?

    /// The name below the icon.
    var labelText: String { label.stringValue }

    private let icon = NSView()
    private let label = NSTextField(labelWithString: "")
    private let more = NSButton()
    private var isHovered = false {
        didSet {
            needsDisplay = true
            more.isHidden = !isHovered || menu == nil
        }
    }

    /// - Parameter shortcut: nil for the tile that adds a shortcut.
    init(shortcut: Shortcut?, editable: Bool) {
        super.init(frame: NSRect(origin: .zero, size: ShortcutGrid.tileSize))
        title = ""
        isBordered = false
        setButtonType(.momentaryPushIn)
        wantsLayer = true
        layer?.cornerRadius = 10
        target = self
        action = #selector(clicked(_:))

        icon.wantsLayer = true
        icon.layer?.cornerRadius = Self.iconSize / 2
        icon.translatesAutoresizingMaskIntoConstraints = false
        let glyph: NSView
        if let shortcut {
            let letter = NSTextField(labelWithString: shortcut.title.first.map { String($0).uppercased() } ?? "?")
            letter.font = .systemFont(ofSize: 20, weight: .semibold)
            letter.textColor = Self.color(for: shortcut.url)
            glyph = letter
            label.stringValue = shortcut.title
            toolTip = shortcut.url
            setAccessibilityLabel(shortcut.title)
        } else {
            let plus = NSImageView()
            plus.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
            plus.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
            plus.contentTintColor = .labelColor
            glyph = plus
            label.stringValue = "Tambah pintasan"
            setAccessibilityLabel("Tambah pintasan")
        }
        glyph.translatesAutoresizingMaskIntoConstraints = false
        icon.addSubview(glyph)

        label.font = .systemFont(ofSize: 12)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Opsi pintasan")
        more.isBordered = false
        more.imagePosition = .imageOnly
        more.contentTintColor = .secondaryLabelColor
        more.toolTip = "Ubah atau hapus pintasan"
        more.target = self
        more.action = #selector(showMenu(_:))
        more.isHidden = true
        more.translatesAutoresizingMaskIntoConstraints = false

        for view in [icon, label, more] { addSubview(view) }
        for view in [icon, glyph, label] { view.setAccessibilityElement(false) }
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSize),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            glyph.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 8),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -4),
            more.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            more.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            more.widthAnchor.constraint(equalToConstant: 20),
            more.heightAnchor.constraint(equalToConstant: 20),
        ])

        if shortcut != nil && editable {
            let menu = NSMenu()
            let change = NSMenuItem(title: "Ubah Pintasan…", action: #selector(changeShortcut(_:)), keyEquivalent: "")
            let remove = NSMenuItem(title: "Hapus Pintasan", action: #selector(removeShortcut(_:)), keyEquivalent: "")
            change.target = self
            remove.target = self
            menu.addItem(change)
            menu.addItem(remove)
            self.menu = menu
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The same site always gets the same color.
    private static func color(for url: String) -> NSColor {
        let host = URL(string: url)?.host ?? url
        return Palette.color(host.unicodeScalars.reduce(0) { $0 &+ Int($1.value) })
    }

    /// A click on the icon or the name is a click on the tile; the ⋯ button is its own.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        if !more.isHidden, more.frame.contains(local) { return more }
        return self
    }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // The tints of the search box: the icon always, the tile under the mouse.
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let base = dark ? NSColor.white : NSColor.black
        let tint: CGFloat = isHighlighted ? (dark ? 0.12 : 0.08) : isHovered ? (dark ? 0.08 : 0.05) : 0
        layer?.backgroundColor = base.withAlphaComponent(tint).cgColor
        icon.layer?.backgroundColor = base.withAlphaComponent(dark ? 0.12 : 0.06).cgColor
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }

    @objc private func clicked(_ sender: Any?) {
        onClick?()
    }

    @objc private func showMenu(_ sender: NSButton) {
        menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.maxY + 4 : -4), in: sender)
    }

    @objc func changeShortcut(_ sender: Any?) {
        onChange?()
    }

    @objc func removeShortcut(_ sender: Any?) {
        onRemove?()
    }
}
