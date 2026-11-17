import SwiftUI
import Observation

struct SDKVersion: Comparable, Hashable, Codable, CustomStringConvertible {
    var major: Int, minor: Int, patch: Int
    static let target = SDKVersion(major: 27, minor: 1, patch: 0)
    static let trial27 = SDKVersion(major: 27, minor: 0, patch: 0)
    static let trialLatest = SDKVersion(major: 27, minor: 2, patch: 1)

    static func < (a: SDKVersion, b: SDKVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
    var description: String { patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)" }
    var triple: [NSNumber] { [major, minor, patch].map { NSNumber(value: $0) } }
}

struct InstalledApp: Identifiable, Hashable {
    let id: String
    let name: String
    let signer: String
    let storeSigned: Bool
    let sdk: SDKVersion
    let container: String

    init(_ r: FDAppRecord) {
        container = r.containerUUID
        id = r.bundleID
        name = r.name
        signer = r.signer
        storeSigned = r.storeSigned
        sdk = SDKVersion(major: r.sdkMajor, minor: r.sdkMinor, patch: r.sdkPatch)
    }
}

enum AppFilter: String, CaseIterable, Identifiable {
    case all = "All", legacy = "Legacy SDK", forced = "Enabled", native = "Up to date"
    var title: LocalizedStringKey { LocalizedStringKey(rawValue) }
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .legacy: "clock.arrow.circlepath"
        case .forced: "bolt.fill"
        case .native: "checkmark.seal"
        }
    }
}

enum AppStatus {
    case native        // built with >= target SDK by its developer
    case forced        // we forced it and it's still forced
    case drifted       // we forced it but an update/rebuild reset it
    case legacy        // old SDK, not forced

    var label: LocalizedStringKey {
        switch self {
        case .native: "Native"
        case .forced: "Forced"
        case .drifted: "Re-apply needed"
        case .legacy: "Legacy SDK"
        }
    }
    var tint: Color {
        switch self {
        case .native: .secondary
        case .forced: .green
        case .drifted: .orange
        case .legacy: .blue
        }
    }
}

@MainActor
@Observable
final class AppCatalog {
    var apps: [InstalledApp] = []
    var loading = false
    var applying = false
    var errorMessage: String?
    var resultMessage: String?
    var storePath: String?
    var engineLog = ""
    var icons: [String: UIImage] = [:]

    /// What the user wants enabled (UI toggles).
    var selection: Set<String> = []
    /// Apps we have forced, as persisted after a successful apply.
    private(set) var forced: Set<String>
    /// Original SDK of each app before we touched it.
    private(set) var originals: [String: SDKVersion]
    /// The version last written by this app; old installs default to 27.1.
    private(set) var appliedTargets: [String: SDKVersion]
    /// Per-app version selected for the next write.
    private(set) var trialTargets: [String: SDKVersion]

    private let defaults = UserDefaults.standard

    init() {
        forced = Set(defaults.stringArray(forKey: "forced") ?? [])
        if let data = defaults.data(forKey: "originals"),
           let decoded = try? JSONDecoder().decode([String: SDKVersion].self, from: data) {
            originals = decoded
        } else {
            originals = [:]
        }
        appliedTargets = (defaults.data(forKey: "appliedTargets")
            .flatMap { try? JSONDecoder().decode([String: SDKVersion].self, from: $0) }) ?? [:]
        trialTargets = (defaults.data(forKey: "trialTargets")
            .flatMap { try? JSONDecoder().decode([String: SDKVersion].self, from: $0) }) ?? [:]
        selection = forced
    }

    func status(of app: InstalledApp) -> AppStatus {
        if forced.contains(app.id) || originals[app.id] != nil {
            return app.sdk == (appliedTargets[app.id] ?? .target) ? .forced : .drifted
        }
        return app.sdk >= .target ? .native : .legacy
    }

    func canToggle(_ app: InstalledApp) -> Bool {
        status(of: app) != .native
    }

    func apps(for filter: AppFilter, search: String) -> [InstalledApp] {
        apps.filter { app in
            let s = status(of: app)
            let passes: Bool = switch filter {
            case .all: true
            case .legacy: s == .legacy || s == .drifted
            case .forced: s == .forced || s == .drifted
            case .native: s == .native
            }
            guard passes else { return false }
            guard !search.isEmpty else { return true }
            return app.name.localizedCaseInsensitiveContains(search) || app.id.localizedCaseInsensitiveContains(search)
        }
    }

    func count(_ filter: AppFilter) -> Int { apps(for: filter, search: "").count }

    func desiredSDK(for app: InstalledApp) -> SDKVersion {
        trialTargets[app.id] ?? .target
    }

    func setTrialTarget(_ version: SDKVersion?, for app: InstalledApp) {
        guard !applying && !loading && canToggle(app) else { return }
        guard version == nil || version == .trial27 || version == .trialLatest else { return }
        trialTargets[app.id] = version
        selection.insert(app.id)
        persist()
    }

    /// bundleID -> desired SDK for every record that has to change.
    var pendingChanges: [String: SDKVersion] {
        var changes: [String: SDKVersion] = [:]
        for app in apps {
            if selection.contains(app.id) {
                let desired = desiredSDK(for: app)
                if app.sdk != desired && canToggle(app) { changes[app.id] = desired }
            } else if let original = originals[app.id], app.sdk != original {
                changes[app.id] = original
            }
        }
        return changes
    }

    func binding(for app: InstalledApp) -> Binding<Bool> {
        Binding(
            get: { self.selection.contains(app.id) },
            set: { on in
                guard !self.applying && !self.loading else { return }
                if on { self.selection.insert(app.id) } else { self.selection.remove(app.id) }
            })
    }

    func selectAllLegacy() {
        guard !applying && !loading else { return }
        for app in apps where status(of: app) == .legacy || status(of: app) == .drifted { selection.insert(app.id) }
    }

    func deselectAll() {
        guard !applying && !loading else { return }
        selection.removeAll()
    }

    func restoreOriginal(for app: InstalledApp) {
        guard !applying && !loading, originals[app.id] != nil else { return }
        selection.remove(app.id)
    }

    func recoverOriginal(for app: InstalledApp) async {
        guard !applying && !loading else { return }
        loading = true
        errorMessage = nil
        defer { loading = false }
        let id = app.id
        let result: Result<[NSNumber], Error> = await Task.detached {
            do { return .success(try FDEngine.shared.recoverSDK(forBundleID: id)) }
            catch { return .failure(error) }
        }.value
        engineLog = FDEngine.shared.lastLog
        switch result {
        case .success(let triple):
            guard triple.count == 3 else { return }
            originals[id] = SDKVersion(major: triple[0].intValue, minor: triple[1].intValue, patch: triple[2].intValue)
            selection.remove(id)
            persist()
            resultMessage = String(localized: "Compiled SDK recovered. Tap Apply to restore it, then restart the phone.")
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    func diagnosticReport(for app: InstalledApp) -> String {
        """
        Force Duo recovery test
        iOS: \(UIDevice.current.systemVersion)
        App: \(app.name)
        Bundle: \(app.id)
        Recorded SDK: \(app.sdk)
        Saved original SDK: \(originals[app.id]?.description ?? "unavailable")
        Last applied SDK: \(appliedTargets[app.id]?.description ?? (forced.contains(app.id) ? SDKVersion.target.description : "none"))
        Selected: \(selection.contains(app.id))
        Pending SDK: \(pendingChanges[app.id]?.description ?? "none")
        """
    }

    func reload() async {
        guard !loading && !applying else { return }
        loading = true
        errorMessage = nil
        defer { loading = false }
        let result: Result<[InstalledApp], Error> = await Task.detached {
            do {
                return .success(try FDEngine.shared.loadApps()
                    .filter { !($0.signer.isEmpty && $0.bundleID.hasPrefix("com.apple.")) }
                    .map(InstalledApp.init))
            } catch {
                return .failure(error)
            }
        }.value
        engineLog = FDEngine.shared.lastLog
        storePath = FDEngine.shared.storePath
        switch result {
        case .success(let list):
            apps = list
            reconcile()
            await loadIcons()
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    /// Drop bookkeeping for apps that vanished, and adopt new originals after updates.
    private func reconcile() {
        let byID = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        for (id, _) in originals where byID[id] == nil { originals[id] = nil }
        forced = forced.filter { byID[$0] != nil }
        appliedTargets = appliedTargets.filter { byID[$0.key] != nil }
        trialTargets = trialTargets.filter { byID[$0.key] != nil }
        for id in forced {
            if let app = byID[id], app.sdk != (appliedTargets[id] ?? .target), app.sdk < .trial27 {
                // The app was updated or rebuilt; its new recorded SDK is the restore point.
                originals[id] = app.sdk
            }
        }
        selection = selection.filter { byID[$0] != nil }
        persist()
    }

    func apply() async {
        guard !applying && !loading else { return }
        let changes = pendingChanges
        guard !changes.isEmpty else { return }
        let requestedSelection = selection
        applying = true
        errorMessage = nil
        resultMessage = nil
        defer { applying = false }
        // Save restore points before writing, including if the process is interrupted.
        for app in apps where changes[app.id] != nil && requestedSelection.contains(app.id) && originals[app.id] == nil {
            originals[app.id] = app.sdk
        }
        persist()
        let payload = changes.mapValues { $0.triple }
        let result: Result<(String, [InstalledApp]), Error> = await Task.detached {
            do {
                let summary = try FDEngine.shared.applyVersions(payload, dryRun: false)
                let verified = try FDEngine.shared.loadApps()
                    .filter { !($0.signer.isEmpty && $0.bundleID.hasPrefix("com.apple.")) }
                    .map(InstalledApp.init)
                return .success((summary, verified))
            } catch { return .failure(error) }
        }.value
        engineLog = FDEngine.shared.lastLog
        switch result {
        case .success(let (summary, verified)):
            apps = verified
            let byID = Dictionary(uniqueKeysWithValues: verified.map { ($0.id, $0) })
            var failed: [String] = []
            for (id, version) in changes {
                guard byID[id]?.sdk == version else {
                    failed.append(id)
                    continue // Keep the original and pending selection for retry.
                }
                if requestedSelection.contains(id) {
                    forced.insert(id)
                    appliedTargets[id] = version
                } else {
                    originals[id] = nil
                    forced.remove(id)
                    appliedTargets[id] = nil
                    trialTargets[id] = nil
                }
            }
            persist()
            if failed.isEmpty {
                resultMessage = summary + "\n" + String(localized: "Restart the iPhone Duo so apps reload the new interface.")
            } else {
                errorMessage = String(localized: "SDK verification failed. Restore points were kept. Reload and try again.") + "\n" + failed.sorted().joined(separator: "\n")
            }
            await loadIcons()
        case .failure(let error):
            errorMessage = error.localizedDescription
            // Do not reload here: it would clear the error or reinterpret a partial write.
        }
    }

    private func persist() {
        defaults.set(Array(forced), forKey: "forced")
        defaults.set(try? JSONEncoder().encode(originals), forKey: "originals")
        defaults.set(try? JSONEncoder().encode(appliedTargets), forKey: "appliedTargets")
        defaults.set(try? JSONEncoder().encode(trialTargets), forKey: "trialTargets")
    }
}
