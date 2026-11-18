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
    case all = "All", legacy = "Legacy SDK", forced = "Enabled", native = "Up to date", compatibility = "Compatibility"
    var title: LocalizedStringKey { LocalizedStringKey(rawValue) }
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .legacy: "clock.arrow.circlepath"
        case .forced: "bolt.fill"
        case .native: "checkmark.seal"
        case .compatibility: "shield.lefthalf.filled"
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
    private var originalContainers: [String: String]
    /// Overrides that may have reached the live cache before verification completed.
    private var unverifiedOverrides: [String: SDKVersion]
    /// The version last written by this app; old installs default to 27.1.
    private(set) var appliedTargets: [String: SDKVersion]
    /// Per-app version selected for the next write.
    private(set) var trialTargets: [String: SDKVersion]
    /// A restored app must not be forced again by bulk selection or after relaunch.
    private(set) var compatibilityProtected: Set<String>

    @ObservationIgnored private var iconTask: Task<Void, Never>?
    private var didLoad = false

    private let defaults = UserDefaults.standard

    init() {
        forced = Set(defaults.stringArray(forKey: "forced") ?? [])
        if let data = defaults.data(forKey: "originals"),
           let decoded = try? JSONDecoder().decode([String: SDKVersion].self, from: data) {
            originals = decoded
        } else {
            originals = [:]
        }
        originalContainers = defaults.dictionary(forKey: "originalContainers") as? [String: String] ?? [:]
        unverifiedOverrides = (defaults.data(forKey: "unverifiedOverrides")
            .flatMap { try? JSONDecoder().decode([String: SDKVersion].self, from: $0) }) ?? [:]
        appliedTargets = (defaults.data(forKey: "appliedTargets")
            .flatMap { try? JSONDecoder().decode([String: SDKVersion].self, from: $0) }) ?? [:]
        trialTargets = (defaults.data(forKey: "trialTargets")
            .flatMap { try? JSONDecoder().decode([String: SDKVersion].self, from: $0) }) ?? [:]
        compatibilityProtected = Set(defaults.stringArray(forKey: "compatibilityProtected") ?? [])
        selection = forced.subtracting(compatibilityProtected)
    }

    func status(of app: InstalledApp) -> AppStatus {
        if forced.contains(app.id) || originals[app.id] != nil {
            return app.sdk == (appliedTargets[app.id] ?? .target) ? .forced : .drifted
        }
        return app.sdk >= .target ? .native : .legacy
    }

    func canToggle(_ app: InstalledApp) -> Bool {
        app.id != Bundle.main.bundleIdentifier && !compatibilityProtected.contains(app.id) && status(of: app) != .native
    }

    func apps(for filter: AppFilter, search: String) -> [InstalledApp] {
        apps.filter { app in
            let s = status(of: app)
            let passes: Bool = switch filter {
            case .all: true
            case .legacy: s == .legacy || s == .drifted
            case .forced: s == .forced || s == .drifted
            case .native: s == .native
            case .compatibility: compatibilityProtected.contains(app.id)
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
            if selection.contains(app.id) && !compatibilityProtected.contains(app.id) && app.id != Bundle.main.bundleIdentifier {
                let desired = desiredSDK(for: app)
                if app.sdk != desired && canToggle(app) { changes[app.id] = desired }
            } else if let original = originals[app.id], app.sdk != original,
                      originalContainers[app.id] == nil || originalContainers[app.id] == app.container {
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
                if on {
                    guard self.canToggle(app) else { return }
                    self.selection.insert(app.id)
                } else if self.originals[app.id] != nil {
                    self.restoreOriginal(for: app)
                } else {
                    self.selection.remove(app.id)
                }
            })
    }

    func selectAllLegacy() {
        guard !applying && !loading else { return }
        for app in apps where canToggle(app) && (status(of: app) == .legacy || status(of: app) == .drifted) {
            selection.insert(app.id)
        }
    }

    func deselectAll() {
        guard !applying && !loading else { return }
        for app in apps where originals[app.id] != nil { restoreOriginal(for: app) }
        selection.removeAll()
    }

    func restoreOriginal(for app: InstalledApp) {
        guard !applying && !loading, originals[app.id] != nil else { return }
        selection.remove(app.id)
        compatibilityProtected.insert(app.id)
        trialTargets[app.id] = nil
        persist()
    }

    func removeCompatibilityProtection(for app: InstalledApp) {
        guard !applying && !loading else { return }
        compatibilityProtected.remove(app.id)
        // Removing protection does not stage another SDK write.
        persist()
    }

    func recoverOriginal(for app: InstalledApp) async {
        guard !applying && !loading else { return }
        loading = true
        errorMessage = nil
        resultMessage = nil
        defer { loading = false }
        let id = app.id
        let container = app.container
        let (result, recoveryLog): (Result<([NSNumber], [InstalledApp]), Error>, String) = await Task.detached {
            let engine = FDEngine.shared
            let triple: [NSNumber]
            do {
                triple = try engine.recoverSDK(forBundleID: id, expectedContainer: container)
            } catch { return (.failure(error), engine.lastLog) }
            let log = engine.lastLog
            do {
                let list = try engine.loadApps()
                    .filter { !($0.signer.isEmpty && $0.bundleID.hasPrefix("com.apple.")) }
                    .map(InstalledApp.init)
                return (.success((triple, list)), log)
            }
            catch { return (.failure(error), engine.lastLog) }
        }.value
        engineLog = recoveryLog
        switch result {
        case .success(let (triple, list)):
            guard triple.count == 3, triple.allSatisfy({ (0...99).contains($0.intValue) }),
                  triple[0].intValue > 0 else {
                errorMessage = String(localized: "Executable SDK is missing or ambiguous. No SDK was changed.")
                return
            }
            guard let installed = list.first(where: { $0.id == id }) else {
                errorMessage = String(localized: "Installed app not found. Reload and try again.")
                return
            }
            guard installed.container == container else {
                errorMessage = String(localized: "The app was updated during recovery. Reload and try again.")
                return
            }
            apps = list
            originals[id] = SDKVersion(major: triple[0].intValue, minor: triple[1].intValue, patch: triple[2].intValue)
            originalContainers[id] = container
            unverifiedOverrides[id] = nil
            selection.remove(id)
            compatibilityProtected.insert(id)
            trialTargets[id] = nil
            reconcile()
            resultMessage = originals[id] == nil
                ? String(localized: "The recorded SDK already matches the installed app. Compatibility protection is enabled; no cache write is needed.")
                : String(localized: "Compiled SDK recovered. Tap Apply to restore it, then restart the phone.")
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
        Compatibility protection: \(compatibilityProtected.contains(app.id))
        """
    }

    func loadIfNeeded() async {
        guard !didLoad else { return }
        await reload()
    }

    private func scheduleIcons() {
        iconTask?.cancel()
        iconTask = Task { [weak self] in
            guard let self else { return }
            await self.loadIcons()
        }
    }

    func reload() async {
        guard !loading && !applying else { return }
        loading = true
        errorMessage = nil
        defer { loading = false }
        let (result, log, path): (Result<[InstalledApp], Error>, String, String?) = await Task.detached {
            let engine = FDEngine.shared
            do {
                let list = try engine.loadApps()
                    .filter { !($0.signer.isEmpty && $0.bundleID.hasPrefix("com.apple.")) }
                    .map(InstalledApp.init)
                return (.success(list), engine.lastLog, engine.storePath)
            } catch {
                return (.failure(error), engine.lastLog, engine.storePath)
            }
        }.value
        engineLog = log
        storePath = path
        switch result {
        case .success(let list):
            apps = list
            didLoad = true
            reconcile()
            scheduleIcons()
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    /// Reconcile against the current installation before offering any further writes.
    private func reconcile() {
        let byID = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        let tracked = forced.union(originals.keys).union(unverifiedOverrides.keys)
        for id in tracked {
            guard let app = byID[id] else {
                clearTracking(for: id)
                continue
            }
            let forcedVersion = appliedTargets[id] ?? .target
            let wasForced = forced.contains(id)
            let replaced = originalContainers[id].map { $0 != app.container } ?? false
            if replaced {
                clearTracking(for: id)
                selection.remove(id)
                continue
            }
            let attempted = unverifiedOverrides.removeValue(forKey: id)
            if let attempted, app.sdk == attempted {
                // The write reached the cache before the app could verify it.
                forced.insert(id)
                appliedTargets[id] = attempted
                if !compatibilityProtected.contains(id) { selection.insert(id) }
            } else if (wasForced || attempted != nil), app.sdk != originals[id],
                      !wasForced || app.sdk != forcedVersion {
                // The cache now contains an SDK that this installation did not write.
                // Discard the old restore point rather than replacing the current SDK.
                clearTracking(for: id)
                selection.remove(id)
                continue
            }
            if originals[id] != nil && originalContainers[id] == nil {
                // Earlier versions did not save the installation identifier.
                originalContainers[id] = app.container
            }
        }
        trialTargets = trialTargets.filter { byID[$0.key] != nil }
        // A previous write may have succeeded before the process was killed or its
        // readback failed. A fresh read is enough to finish an already-restored app.
        for id in compatibilityProtected {
            if let app = byID[id], let original = originals[id], app.sdk == original {
                clearTracking(for: id)
            }
        }
        selection = selection.filter { byID[$0] != nil }.subtracting(compatibilityProtected)
        persist()
    }

    func apply() async {
        guard !applying && !loading else { return }
        let changes = pendingChanges
        guard !changes.isEmpty else { return }
        var requestedSelection = selection.subtracting(compatibilityProtected)
        if let selfID = Bundle.main.bundleIdentifier { requestedSelection.remove(selfID) }
        applying = true
        errorMessage = nil
        resultMessage = nil
        defer { applying = false }
        // Save restore points before writing, including if the process is interrupted.
        var expectedSDKs: [String: [NSNumber]] = [:]
        var expectedContainers: [String: String] = [:]
        for app in apps {
            guard let version = changes[app.id] else { continue }
            expectedSDKs[app.id] = app.sdk.triple
            expectedContainers[app.id] = app.container
            guard requestedSelection.contains(app.id) else { continue }
            if originals[app.id] == nil { originals[app.id] = app.sdk }
            originalContainers[app.id] = app.container
            unverifiedOverrides[app.id] = version
        }
        persist()
        let payload = changes.mapValues { $0.triple }
        let observedSDKs = expectedSDKs
        let observedContainers = expectedContainers
        let (result, writeLog): (Result<(String, [InstalledApp]), Error>, String) = await Task.detached {
            let engine = FDEngine.shared
            let summary: String
            do {
                summary = try engine.applyVersions(payload, expectedSDKs: observedSDKs,
                                                   expectedContainers: observedContainers, dryRun: false)
            }
            catch { return (.failure(error), engine.lastLog) }
            let log = engine.lastLog
            do {
                let verified = try engine.loadApps()
                    .filter { !($0.signer.isEmpty && $0.bundleID.hasPrefix("com.apple.")) }
                    .map(InstalledApp.init)
                return (.success((summary, verified)), log)
            } catch { return (.failure(error), log) }
        }.value
        engineLog = writeLog
        switch result {
        case .success(let (summary, verified)):
            apps = verified
            let byID = Dictionary(uniqueKeysWithValues: verified.map { ($0.id, $0) })
            var failed: [String] = []
            for (id, version) in changes {
                guard let verifiedApp = byID[id], verifiedApp.sdk == version,
                      verifiedApp.container == observedContainers[id] else {
                    failed.append(id)
                    continue // Keep the original and pending selection for retry.
                }
                if requestedSelection.contains(id) {
                    forced.insert(id)
                    appliedTargets[id] = version
                    unverifiedOverrides[id] = nil
                } else {
                    clearTracking(for: id)
                }
            }
            reconcile()
            if failed.isEmpty {
                resultMessage = summary + "\n" + String(localized: "Restart the iPhone Duo so apps reload the new interface.")
            } else {
                errorMessage = String(localized: "SDK verification failed. Restore points were kept. Reload and try again.") + "\n" + failed.sorted().joined(separator: "\n")
            }
            scheduleIcons()
        case .failure(let error):
            errorMessage = error.localizedDescription
            // Do not reload here: it would clear the error or reinterpret a partial write.
        }
    }

    private func clearTracking(for id: String) {
        originals[id] = nil
        originalContainers[id] = nil
        unverifiedOverrides[id] = nil
        forced.remove(id)
        appliedTargets[id] = nil
        trialTargets[id] = nil
    }

    private func persist() {
        defaults.set(Array(forced), forKey: "forced")
        defaults.set(try? JSONEncoder().encode(originals), forKey: "originals")
        defaults.set(originalContainers, forKey: "originalContainers")
        defaults.set(try? JSONEncoder().encode(unverifiedOverrides), forKey: "unverifiedOverrides")
        defaults.set(try? JSONEncoder().encode(appliedTargets), forKey: "appliedTargets")
        defaults.set(try? JSONEncoder().encode(trialTargets), forKey: "trialTargets")
        defaults.set(Array(compatibilityProtected).sorted(), forKey: "compatibilityProtected")
    }
}
