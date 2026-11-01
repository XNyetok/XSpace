import AppKit
import WebKit

// MARK: - Persisted state (state.json)

struct PaneState: Codable, Equatable {
    var url: String
}

/// A shortcut on a profile's start page: a website that opens with one click.
struct Shortcut: Codable, Equatable {
    /// At most this many per profile, as in browsers: two rows of five.
    static let limit = 10

    var title: String
    var url: String

    /// The name of a shortcut without one: the site's host, without "www.".
    static func defaultTitle(for url: URL) -> String {
        let host = url.host ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

extension Shortcut {
    /// A shortcut as typed in its dialog: the address of a website (not search terms) and a name,
    /// the site's if none is typed. Nil without such an address.
    init?(name: String, address: String) {
        guard let url = PaneView.address(address), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(title: name.isEmpty ? Shortcut.defaultTitle(for: url) : name, url: url.absoluteString)
    }
}

struct ProfileState: Codable, Equatable {
    /// Also the identifier of the profile's WKWebsiteDataStore.
    var id: UUID
    var name: String
    var colorIndex: Int
    /// The page of the profile's pane; nil until one is opened, and until then the pane shows its
    /// start page (an address field).
    var url: String?
    /// The shortcuts on the profile's start page, in order.
    var shortcuts: [Shortcut] = []
    /// The profile's panes as XSpace 0.5.0 knows them; only written for 0.5.0 (see
    /// AppStateData.encodedForDisk).
    var panes: [PaneState] = []
    /// Pane widths in 0.5.0 (nil = equal widths), like `panes`.
    var splitRatios: [Double]? = nil
}

extension ProfileState {
    /// Up to 0.5.0 a profile had panes (AI Studio | Sheets) and no page of its own: it keeps the
    /// page of its first pane. An empty address (what 0.5.0 gets for a profile without a page)
    /// is no page. Shortcuts that cannot be read are left out, not the profile.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        colorIndex = try c.decode(Int.self, forKey: .colorIndex)
        panes = try c.decodeIfPresent([PaneState].self, forKey: .panes) ?? []
        splitRatios = try c.decodeIfPresent([Double].self, forKey: .splitRatios)
        let page = try c.decodeIfPresent(String.self, forKey: .url) ?? panes.first?.url
        url = page?.isEmpty == false ? page : nil
        shortcuts = (try? c.decodeIfPresent([Shortcut].self, forKey: .shortcuts)) ?? []
    }
}

/// When a profile that is not on screen gets frozen: its web views are destroyed so their
/// memory is returned, and pages reload when the profile is shown again (logins persist).
/// A profile that is on screen is never frozen automatically.
enum HibernatePolicy: String, Codable, CaseIterable {
    case after15Minutes
    case immediately
    case memoryPressureOnly
    case never

    /// Menu title (UI language: Indonesian).
    var title: String {
        switch self {
        case .after15Minutes: return "Setelah 15 menit tidak dilihat"
        case .immediately: return "Langsung saat disembunyikan"
        case .memoryPressureOnly: return "Hanya saat RAM menipis"
        case .never: return "Jangan pernah"
        }
    }

    /// How long a profile must be hidden before it is frozen; nil = not time based.
    var idleSeconds: TimeInterval? {
        switch self {
        case .after15Minutes: return 15 * 60
        case .immediately: return 0
        case .memoryPressureOnly, .never: return nil
        }
    }

    /// Every policy except `.never` also freezes hidden profiles when macOS reports memory pressure.
    var respondsToMemoryPressure: Bool { self != .never }
}

struct AppStateData: Codable {
    /// 3: one page per profile, shown in a grid layout. Older files are read too: 1 (0.5.0, with
    /// panes per profile and the Fokus/Semua mode) and 2 (never released, with workspaces, which
    /// are ignored). Each profile keeps the page of its first pane.
    static let currentVersion = 3

    var version = AppStateData.currentVersion
    /// One entry per profile, that is per data store, in toolbar order.
    var profiles: [ProfileState] = []
    var layout: GridPreset = .automatic
    /// The profile in each slot of each fixed layout, by layout ("oneAndThree": four slots; nil =
    /// an empty slot). Every layout remembers its profiles.
    var layoutSlots: [String: [UUID?]] = [:]
    /// The sizes of each layout: the ratios of its splits, depth first (see sizesKey).
    var layoutSizes: [String: [[Double]]] = [:]
    /// The layout that Ctrl-Cmd-G returns to from the single-profile layout.
    var previousLayout: GridPreset?
    /// The active profile: the one the single-profile layout shows. Also the profile 0.5.0 opens.
    var selectedProfileID: UUID?
    /// Written for 0.5.0: whether it shows all profiles (Semua) or the selected one (Fokus).
    var showAll = false
    var hibernatePolicy: HibernatePolicy = .after15Minutes
    /// Data stores whose deletion has not completed yet (retried at launch).
    var pendingDeletion: [UUID] = []

    init() {}

    private enum LegacyKeys: String, CodingKey { case autoHibernate }

    /// Lenient decoding: missing keys (older versions) fall back to defaults, and the layouts are
    /// made to fit the profiles (see normalizeLayout). A file without a layout gets the
    /// single-profile layout, or the automatic one if 0.5.0 showed all profiles.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        profiles = try c.decodeIfPresent([ProfileState].self, forKey: .profiles) ?? []
        selectedProfileID = try c.decodeIfPresent(UUID.self, forKey: .selectedProfileID)
        showAll = try c.decodeIfPresent(Bool.self, forKey: .showAll) ?? false
        pendingDeletion = try c.decodeIfPresent([UUID].self, forKey: .pendingDeletion) ?? []
        let savedLayout = try? c.decodeIfPresent(GridPreset.self, forKey: .layout)
        layout = savedLayout ?? (showAll ? GridPreset.automatic : GridPreset.single)
        layoutSlots = (try? c.decodeIfPresent([String: [UUID?]].self, forKey: .layoutSlots)) ?? [:]
        layoutSizes = (try? c.decodeIfPresent([String: [[Double]]].self, forKey: .layoutSizes)) ?? [:]
        previousLayout = try? c.decodeIfPresent(GridPreset.self, forKey: .previousLayout)
        if let raw = try? c.decodeIfPresent(String.self, forKey: .hibernatePolicy),
           let policy = HibernatePolicy(rawValue: raw) {
            hibernatePolicy = policy
        } else {
            // v0.1 stored a boolean "autoHibernate" toggle.
            var legacyAuto = false
            if let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
               let value = try? legacy.decodeIfPresent(Bool.self, forKey: .autoHibernate) {
                legacyAuto = value
            }
            hibernatePolicy = legacyAuto ? .immediately : .after15Minutes
        }
        normalizeLayout()
    }

    // MARK: The layout

    /// The profile in each slot of the current layout, in reading order (nil = an empty slot).
    /// The automatic layout shows every profile, in toolbar order.
    var shownProfiles: [UUID?] {
        guard let count = layout.slotCount else { return profiles.map(\.id) }
        let slots = layoutSlots[layout.rawValue] ?? []
        return (0..<count).map { $0 < slots.count ? slots[$0] : nil }
    }

    func isShown(_ id: UUID) -> Bool {
        shownProfiles.contains(id)
    }

    /// The arrangement of the current layout.
    var tree: GridNode {
        layout.tree(slots: shownProfiles.count)
    }

    /// Where the current layout's sizes are kept: the automatic layout differs with the number
    /// of profiles.
    var sizesKey: String {
        layout == .automatic ? "\(layout.rawValue)-\(profiles.count)" : layout.rawValue
    }

    /// Whether the panes of the current layout have other sizes than its own, which are equal.
    var hasCustomSizes: Bool {
        Grid.hasCustomSizes(layoutSizes[sizesKey], in: tree)
    }

    /// The panes of the current layout get its own sizes back; the other layouts keep theirs.
    mutating func resetSizes() {
        layoutSizes[sizesKey] = nil
    }

    /// Fits the layouts to the profiles: unknown and repeated profiles leave their slot empty. A
    /// fixed layout without any profile is filled, and the single-profile layout shows the active
    /// profile, so the window shows something whenever there are profiles.
    mutating func normalizeLayout() {
        let known = Set(profiles.map(\.id))
        for (key, slots) in layoutSlots {
            var seen = Set<UUID>()
            layoutSlots[key] = slots.map { id in
                guard let id, known.contains(id), seen.insert(id).inserted else { return nil }
                return id
            }
        }
        if let selected = selectedProfileID, !known.contains(selected) { selectedProfileID = nil }
        if previousLayout == .single { previousLayout = nil }
        guard let count = layout.slotCount, let first = profiles.first else { return }
        if layout == .single {
            let shown: UUID = selectedProfileID ?? (layoutSlots[layout.rawValue]?.first ?? nil) ?? first.id
            layoutSlots[layout.rawValue] = [shown]
        } else if !shownProfiles.contains(where: { $0 != nil }) {
            layoutSlots[layout.rawValue] = Grid.filling(count, shown: [], profiles: profiles.map(\.id),
                                                        active: selectedProfileID)
        }
    }

    /// Switches the layout. A fixed layout shows the profiles it showed last time, or the first
    /// time those shown so far and then the others (see Grid.filling). The single-profile layout
    /// shows the active profile.
    mutating func switchLayout(to preset: GridPreset, active: UUID?) {
        guard preset != layout else { return }
        let shown = shownProfiles
        if preset == .single { previousLayout = layout }
        layout = preset
        if let active { selectedProfileID = active }
        guard let count = preset.slotCount else { return }
        if preset == .single {
            if let profile = active ?? shown.compactMap({ $0 }).first ?? profiles.first?.id {
                layoutSlots[preset.rawValue] = [profile]
            }
        } else if !shownProfiles.contains(where: { $0 != nil }) {
            layoutSlots[preset.rawValue] = Grid.filling(count, shown: shown, profiles: profiles.map(\.id), active: active)
        }
    }

    /// Shows a profile in `slot`: if it is shown in another slot, the two trade places; otherwise
    /// it takes the place of the profile there, which is then hidden. It becomes the active profile.
    mutating func show(_ id: UUID, inSlot slot: Int) {
        var shown = shownProfiles
        guard shown.indices.contains(slot), profiles.contains(where: { $0.id == id }) else { return }
        if let current = shown.firstIndex(of: id) {
            shown.swapAt(current, slot)
        } else {
            shown[slot] = id
        }
        setShown(shown)
        selectedProfileID = id
    }

    /// The profiles in two slots trade places.
    mutating func swapSlots(_ a: Int, _ b: Int) {
        var shown = shownProfiles
        guard a != b, shown.indices.contains(a), shown.indices.contains(b) else { return }
        shown.swapAt(a, b)
        setShown(shown)
    }

    private mutating func setShown(_ shown: [UUID?]) {
        if layout == .automatic {
            // The automatic layout shows the profiles in toolbar order, so that order changes.
            profiles = shown.compactMap { id in profiles.first { $0.id == id } }
        } else {
            layoutSlots[layout.rawValue] = shown
        }
    }

    // MARK: Profiles

    /// The first start, from the welcome screen: the layout, with a new profile in each of its
    /// slots (one profile for the automatic layout). The profiles have no page yet, so nothing
    /// loads until an address is typed; the first one becomes the active profile.
    mutating func start(with preset: GridPreset) {
        guard profiles.isEmpty else { return }
        layout = preset
        previousLayout = nil
        for index in 0..<(preset.slotCount ?? 1) {
            addProfile(name: "Akun \(index + 1)", colorIndex: index, inSlot: index)
        }
        selectedProfileID = profiles.first?.id
    }

    /// Adds a profile without a page: its pane shows the start page. A fixed layout shows it in
    /// its first empty slot, otherwise in `slot` (the pane you are in); the automatic layout shows
    /// every profile anyway. It becomes the active profile.
    @discardableResult
    mutating func addProfile(name: String, colorIndex: Int, inSlot slot: Int) -> ProfileState {
        let profile = ProfileState(id: UUID(), name: name, colorIndex: colorIndex, url: nil)
        profiles.append(profile)
        if layout.slotCount != nil {
            var shown = shownProfiles
            shown[shown.firstIndex(of: nil) ?? min(max(slot, 0), shown.count - 1)] = profile.id
            setShown(shown)
        }
        selectedProfileID = profile.id
        return profile
    }

    /// Removes a profile. In the current layout, a profile that is not shown takes its slot if
    /// there is one. Its data store is queued for deletion (see StateStore.removeDataStore).
    mutating func removeProfile(_ id: UUID) {
        let slot = shownProfiles.firstIndex(of: id)
        profiles.removeAll { $0.id == id }
        for (key, slots) in layoutSlots {
            layoutSlots[key] = slots.map { $0 == id ? nil : $0 }
        }
        if let slot, layout.slotCount != nil {
            var shown = shownProfiles
            if let hidden = profiles.first(where: { !shown.contains($0.id) }) {
                shown[slot] = hidden.id
                setShown(shown)
            }
        }
        if selectedProfileID == id {
            selectedProfileID = shownProfiles.compactMap { $0 }.first ?? profiles.first?.id
        }
        pendingDeletion.append(id)
    }

    // MARK: Shortcuts

    /// Adds a shortcut to a profile's start page, or with `everywhere` to every profile's. A profile
    /// that has a shortcut to the same address already, or `Shortcut.limit` of them, stays as it is.
    mutating func addShortcut(_ shortcut: Shortcut, to id: UUID, everywhere: Bool = false) {
        for index in profiles.indices where everywhere || profiles[index].id == id {
            let shortcuts = profiles[index].shortcuts
            guard shortcuts.count < Shortcut.limit, !shortcuts.contains(where: { $0.url == shortcut.url }) else { continue }
            profiles[index].shortcuts.append(shortcut)
        }
    }

    /// Replaces a shortcut of a profile (the first one equal to `old`) in its place.
    mutating func replaceShortcut(_ old: Shortcut, of id: UUID, with new: Shortcut) {
        guard let index = profiles.firstIndex(where: { $0.id == id }),
              let position = profiles[index].shortcuts.firstIndex(of: old) else { return }
        profiles[index].shortcuts[position] = new
    }

    /// Removes a shortcut from a profile (the first one equal to `shortcut`); the other profiles keep
    /// theirs.
    mutating func removeShortcut(_ shortcut: Shortcut, from id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }),
              let position = profiles[index].shortcuts.firstIndex(of: shortcut) else { return }
        profiles[index].shortcuts.remove(at: position)
    }

    /// state.json as written to disk: the current format, plus what 0.5.0 reads, so going back to
    /// 0.5.0 keeps every profile: each with one pane (an empty one for a profile without a page),
    /// the active one selected, and Semua unless a single profile is shown.
    func encodedForDisk() throws -> Data {
        var written = self
        written.version = Self.currentVersion
        written.profiles = profiles.map { profile in
            var copy = profile
            copy.panes = [PaneState(url: profile.url ?? "")]
            copy.splitRatios = nil
            return copy
        }
        written.showAll = layout != .single
        written.selectedProfileID = selectedProfileID ?? shownProfiles.compactMap { $0 }.first
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(written)
    }
}

enum Palette {
    static let colors: [NSColor] = [
        .systemBlue, .systemGreen, .systemOrange, .systemPink, .systemPurple,
        .systemTeal, .systemRed, .systemIndigo, .systemBrown, .systemYellow,
    ]

    /// Every index maps to a color, even an odd one from a hand-edited state.json.
    /// (`magnitude` instead of `abs`, which traps on Int.min.)
    static func color(_ index: Int) -> NSColor {
        colors[Int(index.magnitude % UInt(colors.count))]
    }

    static func dot(_ color: NSColor, diameter: CGFloat = 9) -> NSImage {
        NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
    }
}

// MARK: - Runtime profile

/// One profile = one persistent WKWebsiteDataStore, so cookies, localStorage, IndexedDB,
/// cache and service workers are fully separate from every other profile. The store is
/// created once per profile and shared by its pane and its popups.
@MainActor
final class Profile {
    let id: UUID
    var name: String
    var colorIndex: Int
    let store: WKWebsiteDataStore

    init(state: ProfileState) {
        id = state.id
        name = state.name
        colorIndex = state.colorIndex
        store = WKWebsiteDataStore(forIdentifier: state.id)
    }

    var color: NSColor { Palette.color(colorIndex) }
}

// MARK: - State storage

@MainActor
final class StateStore {
    static let shared = StateStore()

    let fileURL: URL
    var data: AppStateData
    private var saveTask: Task<Void, Never>?

    private init() {
        let directory: URL
        if let override = getenv("XSPACE_STATE_DIR"), !String(cString: override).isEmpty {
            // Used by the automated tests so they never touch the real profiles.
            directory = URL(fileURLWithPath: String(cString: override), isDirectory: true)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            directory = support.appendingPathComponent("XSpace", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("state.json")
        data = Self.load(from: fileURL)
    }

    /// Reads state.json. A file that exists but cannot be read (damaged, or not understood) is
    /// moved aside as state-unreadable-<date>.json, so the new state XSpace then starts with does
    /// not overwrite it: the profiles in it, and with them their website data, stay recoverable.
    nonisolated static func load(from fileURL: URL, now: Date = Date()) -> AppStateData {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else { return AppStateData() }
        if let raw = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(AppStateData.self, from: raw) {
            return decoded
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent("state-unreadable-\(formatter.string(from: now)).json")
        do {
            try manager.moveItem(at: fileURL, to: backup)
            NSLog("XSpace: could not read %@; moved it to %@ and started with a new state",
                  fileURL.lastPathComponent, backup.lastPathComponent)
        } catch {
            NSLog("XSpace: could not read %@ or move it aside (%@)", fileURL.lastPathComponent, error.localizedDescription)
        }
        return AppStateData()
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        saveTask?.cancel()
        saveTask = nil
        guard let raw = try? data.encodedForDisk() else { return }
        try? raw.write(to: fileURL, options: .atomic)
    }

    func updateProfile(_ id: UUID, _ change: (inout ProfileState) -> Void) {
        guard let index = data.profiles.firstIndex(where: { $0.id == id }) else { return }
        change(&data.profiles[index])
        scheduleSave()
    }

    /// Removes data stores whose deletion did not finish earlier (for example because they were
    /// still in use). Called at launch, before any profile is loaded.
    func purgePendingDeletions() async {
        guard !data.pendingDeletion.isEmpty else { return }
        WebKitSupport.warmUp()
        let existing = Set(await WKWebsiteDataStore.allDataStoreIdentifiers)
        var remaining: [UUID] = []
        for id in data.pendingDeletion where existing.contains(id) {
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: id)
            } catch {
                remaining.append(id)
            }
        }
        data.pendingDeletion = remaining
        save()
    }

    /// Permanently deletes a profile's data store once WebKit has released it (see
    /// DataStoreRemoval). If that fails, the store stays in `pendingDeletion` and is deleted at
    /// the next launch.
    func removeDataStore(_ removal: DataStoreRemoval) async {
        if let failure = await removal.remove() {
            NSLog("XSpace: could not delete data store %@ (%@); retrying at the next launch",
                  removal.id?.uuidString ?? "?", failure)
            return
        }
        data.pendingDeletion.removeAll { $0 == removal.id }
        save()
    }
}
