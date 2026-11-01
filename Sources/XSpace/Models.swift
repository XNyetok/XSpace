import AppKit
import WebKit

// MARK: - Persisted state (state.json)

struct PaneState: Codable, Equatable {
    var url: String
}

struct ProfileState: Codable, Equatable {
    /// Also the identifier of the profile's WKWebsiteDataStore.
    var id: UUID
    var name: String
    var colorIndex: Int
    /// The profile's panes as 0.5.0 shows them. Since workspaces, the panes shown are in the
    /// workspaces; these are only written for 0.5.0 (see AppStateData.encodedForDisk).
    var panes: [PaneState]
    /// Relative pane widths (nil = equal widths), like `panes`.
    var splitRatios: [Double]? = nil
}

extension ProfileState {
    /// `panes` is only a copy for 0.5.0, so a profile without it can still be read.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        colorIndex = try c.decode(Int.self, forKey: .colorIndex)
        panes = try c.decodeIfPresent([PaneState].self, forKey: .panes) ?? []
        splitRatios = try c.decodeIfPresent([Double].self, forKey: .splitRatios)
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
    /// 2 added workspaces. A file without them (version 1, or a version 2 file saved again by
    /// 0.5.0, which keeps the number but drops what it does not know) gets them when it is read.
    static let currentVersion = 2

    var version = AppStateData.currentVersion
    /// One entry per profile, that is per data store.
    var profiles: [ProfileState] = []
    /// What the window shows, in toolbar order.
    var workspaces: [WorkspaceState] = []
    var selectedWorkspaceID: UUID?
    /// The profile 0.5.0 opens with; written for 0.5.0 (see encodedForDisk).
    var selectedProfileID: UUID?
    var showAll = false
    var hibernatePolicy: HibernatePolicy = .after15Minutes
    /// Data stores whose deletion has not completed yet (retried at launch).
    var pendingDeletion: [UUID] = []

    init() {}

    private enum LegacyKeys: String, CodingKey { case autoHibernate }

    /// Lenient decoding: missing keys (older versions) fall back to defaults, and the workspaces
    /// are made to fit the profiles (see normalizeWorkspaces). Workspaces that cannot be read are
    /// rebuilt from the profiles' panes, so the rest of the state is not lost with them.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        profiles = try c.decodeIfPresent([ProfileState].self, forKey: .profiles) ?? []
        workspaces = (try? c.decodeIfPresent([WorkspaceState].self, forKey: .workspaces)) ?? []
        selectedWorkspaceID = try? c.decodeIfPresent(UUID.self, forKey: .selectedWorkspaceID)
        selectedProfileID = try c.decodeIfPresent(UUID.self, forKey: .selectedProfileID)
        showAll = try c.decodeIfPresent(Bool.self, forKey: .showAll) ?? false
        pendingDeletion = try c.decodeIfPresent([UUID].self, forKey: .pendingDeletion) ?? []
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
        normalizeWorkspaces()
    }

    /// Makes the workspaces fit the profiles (see WorkspaceState.normalized) and selects one:
    /// the one saved, else the one showing the profile 0.5.0 had selected, else the first.
    mutating func normalizeWorkspaces() {
        workspaces = WorkspaceState.normalized(workspaces, profiles: profiles)
        guard !workspaces.contains(where: { $0.id == selectedWorkspaceID }) else { return }
        let showingSelectedProfile = selectedProfileID.flatMap { id in
            workspaces.first { $0.root.contains(profile: id) }
        }
        selectedWorkspaceID = (showingSelectedProfile ?? workspaces.first)?.id
    }

    /// state.json as written to disk: the current format, plus each profile's panes and the
    /// selected profile in the fields 0.5.0 reads, so going back to 0.5.0 keeps every profile.
    func encodedForDisk() throws -> Data {
        var written = self
        written.version = Self.currentVersion
        written.profiles = WorkspaceState.legacyProfiles(profiles, from: workspaces)
        let selected = workspaces.first { $0.id == selectedWorkspaceID } ?? workspaces.first
        if let profileID = selected?.root.panes.first?.profileID {
            written.selectedProfileID = profileID
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(written)
    }

    /// Adds a profile with the default panes in a workspace of its own, and selects that workspace.
    @discardableResult
    mutating func addProfile(name: String, colorIndex: Int) -> (profile: ProfileState, workspace: WorkspaceState) {
        let profile = ProfileState(id: UUID(), name: name, colorIndex: colorIndex,
                                   panes: Defaults.paneURLs.map { PaneState(url: $0) })
        let workspace = WorkspaceState(defaultFor: profile.id)
        profiles.append(profile)
        workspaces.append(workspace)
        selectedWorkspaceID = workspace.id
        return (profile, workspace)
    }

    /// Removes a profile and its panes from every workspace; a workspace left without panes is
    /// removed too. The profile's data store is queued for deletion (see StateStore.removeDataStore).
    mutating func removeProfile(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        workspaces = workspaces.compactMap { workspace in
            guard let root = workspace.root.removingPanes(where: { $0.profileID == id }) else { return nil }
            var kept = workspace
            kept.root = root
            return kept
        }
        if !workspaces.contains(where: { $0.id == selectedWorkspaceID }) {
            selectedWorkspaceID = workspaces.first?.id
        }
        pendingDeletion.append(id)
    }
}

enum Defaults {
    /// Panes of every new profile: Google AI Studio | Google Sheets.
    static let paneURLs = [
        "https://aistudio.google.com/",
        "https://docs.google.com/spreadsheets/",
    ]
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
/// created once per profile and shared by all of its panes and popups.
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

    func updateWorkspace(_ id: UUID, _ change: (inout WorkspaceState) -> Void) {
        guard let index = data.workspaces.firstIndex(where: { $0.id == id }) else { return }
        change(&data.workspaces[index])
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
