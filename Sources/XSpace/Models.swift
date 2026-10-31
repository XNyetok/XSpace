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
    var panes: [PaneState]
    /// Relative pane widths (nil = equal widths).
    var splitRatios: [Double]? = nil
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
    var version = 1
    var profiles: [ProfileState] = []
    var selectedProfileID: UUID?
    var showAll = false
    var hibernatePolicy: HibernatePolicy = .after15Minutes
    /// Data stores whose deletion has not completed yet (retried at launch).
    var pendingDeletion: [UUID] = []

    init() {}

    private enum LegacyKeys: String, CodingKey { case autoHibernate }

    /// Lenient decoding: missing keys (older versions) fall back to defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        profiles = try c.decodeIfPresent([ProfileState].self, forKey: .profiles) ?? []
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
        if let raw = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(AppStateData.self, from: raw) {
            data = decoded
        } else {
            data = AppStateData()
        }
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let raw = try? encoder.encode(data) else { return }
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

    /// Permanently deletes a profile's data store. WebKit refuses while the store is still in
    /// use, so this retries; if it still fails, the store is deleted at the next launch.
    func removeDataStore(_ id: UUID) async {
        for delay in [1.0, 3.0, 6.0] {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: id)
                data.pendingDeletion.removeAll { $0 == id }
                save()
                return
            } catch {
                NSLog("XSpace: could not delete data store %@ (%@), retrying", id.uuidString, error.localizedDescription)
            }
        }
    }
}
