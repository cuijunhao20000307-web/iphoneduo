import Foundation
import SwiftUI
import AppKit
typealias UIImage = NSImage
class UIDevice {
    static let current = UIDevice()
    var systemVersion = "test"
}
class FDAppRecord {
    var containerUUID = "test-container"
    var bundleID = "test.game"
    var name = "Game"
    var signer = "test"
    var storeSigned = true
    var sdkMajor = 26, sdkMinor = 0, sdkPatch = 0
}
class FDEngine {
    static let shared = FDEngine()
    var lastLog = "", storePath: String? = nil
    var record = FDAppRecord()
    var extraRecords: [FDAppRecord] = []
    var appliedIDs: Set<String> = []
    var fail = false, ignoreWrite = false, failRead = false, failRecovery = false
    var recoveredSDK: [NSNumber] = [26, 0, 0]
    var loadCount = 0
    var replaceAfterRecovery = false
    var replaceAfterWrite = false
    var failExport = false
    func exportDiagnostics() throws -> String {
        lastLog = "diagnostic export"
        if failExport { throw NSError(domain: "test-export", code: 1) }
        return lastLog
    }
    func recoverSDK(forBundleID id: String, expectedContainer: String) throws -> [NSNumber] {
        if failRecovery { throw NSError(domain: "test-recovery", code: 1) }
        guard id == record.bundleID, expectedContainer == record.containerUUID else {
            throw NSError(domain: "test-installation-changed", code: 2)
        }
        if replaceAfterRecovery { record.containerUUID = "updated-container" }
        return recoveredSDK
    }
    func loadApps() throws -> [FDAppRecord] {
        loadCount += 1
        if failRead { throw NSError(domain: "test-read", code: 1) }
        return [record] + extraRecords
    }
    func applyVersions(_ payload: [String: [NSNumber]], expectedSDKs: [String: [NSNumber]]?,
                       expectedContainers: [String: String]?, dryRun: Bool) throws -> String {
        Thread.sleep(forTimeInterval: 0.1)
        if fail { throw NSError(domain: "test-write", code: 1) }
        let records = Dictionary(uniqueKeysWithValues: ([record] + extraRecords).map { ($0.bundleID, $0) })
        for id in payload.keys {
            guard let app = records[id], expectedContainers?[id] == app.containerUUID,
                  expectedSDKs?[id] == [app.sdkMajor, app.sdkMinor, app.sdkPatch].map({ NSNumber(value: $0) }) else {
                throw NSError(domain: "test-stale-write", code: 1)
            }
        }
        appliedIDs = Set(payload.keys)
        if !ignoreWrite {
            for (id, version) in payload {
                guard let app = records[id] else { continue }
                app.sdkMajor = version[0].intValue
                app.sdkMinor = version[1].intValue
                app.sdkPatch = version[2].intValue
                if replaceAfterWrite { app.containerUUID = "updated-after-write" }
            }
        }
        return "written"
    }
}
@MainActor enum IconTestState { static var delay = false, started = false }
extension AppCatalog {
    func loadIcons() async {
        IconTestState.started = true
        while IconTestState.delay && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

@main struct RecoveryTests {
    @MainActor static func fresh() -> AppCatalog {
        for key in ["forced", "originals", "originalContainers", "recoverySnapshots", "restoreRequests", "unverifiedOverrides", "appliedTargets", "trialTargets", "compatibilityProtected"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        FDEngine.shared.record = FDAppRecord()
        FDEngine.shared.extraRecords = []
        FDEngine.shared.appliedIDs = []
        FDEngine.shared.fail = false
        FDEngine.shared.ignoreWrite = false
        FDEngine.shared.failRead = false
        FDEngine.shared.failRecovery = false
        FDEngine.shared.replaceAfterRecovery = false
        FDEngine.shared.replaceAfterWrite = false
        FDEngine.shared.failExport = false
        FDEngine.shared.recoveredSDK = [26, 0, 0]
        FDEngine.shared.loadCount = 0
        IconTestState.delay = false
        IconTestState.started = false
        let c = AppCatalog()
        c.apps = [InstalledApp(FDEngine.shared.record)]
        return c
    }
    @MainActor static func enable(_ c: AppCatalog) async {
        c.selection.insert("test.game")
        await c.apply()
        assert(c.originals["test.game"]?.major == 26)
        assert(c.apps[0].sdk == .target)
    }
    @MainActor static func main() async {
        var c = fresh()
        await enable(c)
        c.restoreOriginal(for: c.apps[0])
        await c.apply()
        assert(c.apps[0].sdk.major == 26 && c.originals.isEmpty && c.forced.isEmpty)
        print("PASS: verified restore clears tracking")

        c = fresh()
        await enable(c)
        c.restoreOriginal(for: c.apps[0])
        FDEngine.shared.fail = true
        await c.apply()
        assert(c.originals["test.game"]?.major == 26 && c.errorMessage != nil)
        assert(!c.pendingChanges.isEmpty)
        print("PASS: failed restore retains restore point and error")

        c = fresh()
        await enable(c)
        c.restoreOriginal(for: c.apps[0])
        FDEngine.shared.ignoreWrite = true
        await c.apply()
        assert(c.originals["test.game"]?.major == 26 && c.errorMessage != nil)
        assert(c.resultMessage == nil)
        print("PASS: readback mismatch does not report success")

        c = fresh()
        let app = c.apps[0]
        c.selection.insert(app.id)
        let task = Task { await c.apply() }
        while !c.applying { await Task.yield() }
        c.binding(for: app).wrappedValue = false
        c.deselectAll()
        c.setTrialTarget(.trialLatest, for: app)
        assert(c.selection.contains(app.id) && c.desiredSDK(for: app) == .target)
        // Simulate an unexpected direct UI mutation; completion must still use its snapshot.
        c.selection.removeAll()
        await task.value
        assert(c.originals[app.id]?.major == 26 && c.forced.contains(app.id))
        print("PASS: in-flight changes cannot erase original SDK")

        c = fresh()
        c.selection.insert("test.game")
        FDEngine.shared.fail = true
        await c.apply()
        let recovered = AppCatalog()
        assert(recovered.originals["test.game"]?.major == 26 && c.errorMessage != nil)
        print("PASS: original SDK survives write failure and catalog recreation")
        c = fresh()
        FDEngine.shared.record.sdkMajor = 27
        FDEngine.shared.record.sdkMinor = 1
        c.apps = [InstalledApp(FDEngine.shared.record)]
        assert(!c.canToggle(c.apps[0]))
        await c.recoverOriginal(for: c.apps[0])
        assert(c.pendingChanges["test.game"]?.major == 26)
        await c.apply()
        assert(c.apps[0].sdk.major == 26)
        print("PASS: reinstall with no history can restore recovered SDK")

        c = fresh()
        await enable(c)
        c.restoreOriginal(for: c.apps[0])
        await c.apply()
        c.selectAllLegacy()
        c.binding(for: c.apps[0]).wrappedValue = true
        c.setTrialTarget(.trialLatest, for: c.apps[0])
        assert(c.selection.isEmpty && c.pendingChanges.isEmpty)
        let protected = AppCatalog()
        await protected.reload()
        protected.selectAllLegacy()
        assert(protected.selection.isEmpty && protected.compatibilityProtected.contains("test.game"))
        assert(protected.apps(for: .compatibility, search: "").count == 1)
        protected.removeCompatibilityProtection(for: protected.apps[0])
        assert(protected.pendingChanges.isEmpty)
        protected.binding(for: protected.apps[0]).wrappedValue = true
        assert(protected.pendingChanges["test.game"] == .target)
        print("PASS: protection survives relaunch and all enabling paths; explicit removal permits selection")

        c = fresh()
        await c.recoverOriginal(for: c.apps[0])
        assert(c.originals.isEmpty && c.forced.isEmpty && c.pendingChanges.isEmpty)
        assert(c.compatibilityProtected.contains("test.game") && c.resultMessage != nil)
        print("PASS: recovery of an already-original app completes without a cache write")

        c = fresh()
        await enable(c)
        c.restoreOriginal(for: c.apps[0])
        FDEngine.shared.failRead = true
        await c.apply()
        assert(c.errorMessage != nil && c.originals["test.game"]?.major == 26)
        FDEngine.shared.failRead = false
        let resumed = AppCatalog()
        await resumed.reload()
        assert(resumed.originals.isEmpty && resumed.forced.isEmpty && resumed.selection.isEmpty)
        assert(resumed.compatibilityProtected.contains("test.game"))
        print("PASS: completed restore with failed readback reconciles safely after relaunch")

        c = fresh()
        FDEngine.shared.failRecovery = true
        await c.recoverOriginal(for: c.apps[0])
        assert(c.errorMessage != nil && c.originals.isEmpty && c.compatibilityProtected.isEmpty)
        FDEngine.shared.failRecovery = false
        FDEngine.shared.recoveredSDK = [0, 0, 0]
        await c.recoverOriginal(for: c.apps[0])
        assert(c.errorMessage != nil && c.resultMessage == nil && c.pendingChanges.isEmpty)
        print("PASS: unreadable or invalid compiled SDK never stages a guessed restore")

        c = fresh()
        await enable(c)
        c.restoreOriginal(for: c.apps[0])
        FDEngine.shared.record.containerUUID = "new-installation"
        await c.apply()
        assert(c.errorMessage != nil && FDEngine.shared.record.sdkMajor == 27)
        await c.reload()
        assert(c.pendingChanges.isEmpty && c.originals.isEmpty && c.forced.isEmpty)
        assert(c.compatibilityProtected.contains("test.game"))
        print("PASS: a replaced app with the same SDK cannot receive an old restore")

        c = fresh()
        await enable(c)
        c.restoreOriginal(for: c.apps[0])
        FDEngine.shared.record.sdkMinor = 2
        await c.apply()
        assert(c.errorMessage != nil && FDEngine.shared.record.sdkMinor == 2)
        await c.reload()
        assert(c.pendingChanges.isEmpty && c.originals.isEmpty)
        print("PASS: a changed SDK in the same container blocks stale writes and restores")

        c = fresh()
        FDEngine.shared.replaceAfterRecovery = true
        await c.recoverOriginal(for: c.apps[0])
        assert(c.errorMessage != nil && c.originals.isEmpty && c.compatibilityProtected.isEmpty)
        print("PASS: replacing the installation during executable recovery discards the recovered SDK")

        c = fresh()
        c.setTrialTarget(.trialLatest, for: c.apps[0])
        FDEngine.shared.failRead = true
        await c.apply()
        assert(c.forced.isEmpty && c.errorMessage != nil && FDEngine.shared.record.sdkPatch == 1)
        FDEngine.shared.failRead = false
        let interrupted = AppCatalog()
        await interrupted.reload()
        assert(interrupted.forced.contains("test.game") && interrupted.appliedTargets["test.game"] == .trialLatest)
        assert(interrupted.originals["test.game"]?.major == 26 && interrupted.pendingChanges.isEmpty)
        interrupted.restoreOriginal(for: interrupted.apps[0])
        await interrupted.apply()
        assert(interrupted.apps[0].sdk.major == 26)
        print("PASS: a completed non-default override is recoverable after failed readback and relaunch")

        c = fresh()
        c.setTrialTarget(.trial27, for: c.apps[0])
        FDEngine.shared.record.sdkMajor = 27
        FDEngine.shared.record.sdkMinor = 1
        await c.apply()
        await c.reload()
        assert(c.pendingChanges.isEmpty && c.originals.isEmpty && c.selection.isEmpty)
        print("PASS: an external SDK 27.1 change is not mistaken for a previously applied override")

        c = fresh()
        c.setTrialTarget(.trial27, for: c.apps[0])
        FDEngine.shared.replaceAfterWrite = true
        await c.apply()
        assert(c.errorMessage != nil && c.originals.isEmpty && c.selection.isEmpty)
        assert(c.pendingChanges.isEmpty)
        print("PASS: a replacement during readback cannot inherit a pending override")

        c = fresh()
        await enable(c)
        FDEngine.shared.record.sdkMinor = 2
        await c.recoverOriginal(for: c.apps[0])
        assert(c.errorMessage == nil && c.pendingChanges["test.game"]?.major == 26)
        let reopened = AppCatalog()
        await reopened.reload()
        assert(reopened.pendingChanges["test.game"]?.major == 26)
        await reopened.apply()
        assert(reopened.apps[0].sdk.major == 26 && reopened.originals.isEmpty)
        print("PASS: explicit recovery replaces stale override history and survives relaunch")

        c = fresh()
        FDEngine.shared.record.sdkMajor = 27
        FDEngine.shared.record.sdkMinor = 2
        await c.recoverOriginal(for: c.apps[0])
        assert(c.pendingChanges["test.game"]?.major == 26)
        FDEngine.shared.record.sdkMinor = 3
        await c.reload()
        assert(c.pendingChanges.isEmpty && c.originals.isEmpty)
        assert(c.compatibilityProtected.contains("test.game"))
        print("PASS: subsequent SDK changes invalidate the queued executable recovery")

        c = fresh()
        c.setTrialTarget(.trialLatest, for: c.apps[0])
        await c.apply()
        c.restoreOriginal(for: c.apps[0])
        c.removeCompatibilityProtection(for: c.apps[0])
        let pendingRestore = AppCatalog()
        await pendingRestore.reload()
        let pendingApp = pendingRestore.apps[0]
        assert(!pendingRestore.selection.contains(pendingApp.id))
        assert(!pendingRestore.compatibilityProtected.contains(pendingApp.id))
        assert(pendingRestore.hasPendingRestore(for: pendingApp))
        assert(pendingRestore.pendingChanges[pendingApp.id]?.major == 26)
        pendingRestore.binding(for: pendingApp).wrappedValue = true
        assert(pendingRestore.pendingChanges.isEmpty)
        assert(pendingRestore.desiredSDK(for: pendingApp) == .trialLatest)
        let cancelled = AppCatalog()
        await cancelled.reload()
        assert(cancelled.selection.contains(pendingApp.id) && cancelled.pendingChanges.isEmpty)
        print("PASS: removing protection preserves recovery after relaunch; turning back on keeps the applied trial SDK")

        c = fresh()
        FDEngine.shared.record.sdkMajor = 27
        FDEngine.shared.record.sdkMinor = 2
        await c.recoverOriginal(for: c.apps[0])
        UserDefaults.standard.removeObject(forKey: "restoreRequests")
        let migrated = AppCatalog()
        await migrated.reload()
        let migratedApp = migrated.apps[0]
        assert(migrated.hasPendingRestore(for: migratedApp))
        migrated.removeCompatibilityProtection(for: migratedApp)
        migrated.selectAllLegacy()
        assert(migrated.selection.isEmpty && migrated.pendingChanges[migratedApp.id]?.major == 26)
        await migrated.apply()
        assert(migrated.apps[0].sdk.major == 26 && migrated.originals.isEmpty)
        print("PASS: upgrades preserve queued recovery and bulk enable cannot cancel it")

        c = fresh()
        await enable(c)
        let other = FDAppRecord()
        other.bundleID = "test.other"
        other.containerUUID = "other-container"
        FDEngine.shared.extraRecords = [other]
        await c.reload()
        let primaryApp = c.apps[0]
        c.setTrialTarget(.trialLatest, for: c.apps[1])
        FDEngine.shared.failRecovery = true
        await c.restoreAudioBaseline(for: primaryApp)
        assert(c.errorMessage == nil && c.resultMessage != nil)
        assert(FDEngine.shared.appliedIDs == [primaryApp.id] && other.sdkMajor == 26)
        assert(c.apps[0].sdk.major == 26 && c.compatibilityProtected.contains(primaryApp.id))
        assert(c.pendingChanges == [other.bundleID: .trialLatest])
        print("PASS: sound baseline uses the saved SDK and writes only the requested app")

        c = fresh()
        FDEngine.shared.record.sdkMajor = 27
        FDEngine.shared.record.sdkMinor = 1
        await c.reload()
        await c.restoreAudioBaseline(for: c.apps[0])
        assert(FDEngine.shared.appliedIDs == ["test.game"] && c.apps[0].sdk.major == 26)
        assert(c.errorMessage == nil && c.resultMessage != nil)
        print("PASS: sound baseline recovers from the executable if history is unavailable")

        c = fresh()
        await c.restoreAudioBaseline(for: c.apps[0])
        assert(FDEngine.shared.appliedIDs.isEmpty && c.resultMessage != nil && c.errorMessage == nil)
        print("PASS: a baseline already matching the executable needs no write")

        c = fresh()
        c.engineLog = "Cache lock 5 ms."
        await c.exportDiagnostics()
        assert(c.resultMessage != nil && c.errorMessage == nil && c.engineLog == "Cache lock 5 ms.")
        FDEngine.shared.failExport = true
        await c.exportDiagnostics()
        assert(c.resultMessage == nil && c.errorMessage != nil && !c.loading)
        print("PASS: diagnostics surface success and failure without erasing cache lock timing")

        c = fresh()
        IconTestState.delay = true
        await c.loadIfNeeded()
        while !IconTestState.started { await Task.yield() }
        assert(!c.loading && !c.applying && !c.apps.isEmpty)
        await c.loadIfNeeded()
        assert(FDEngine.shared.loadCount == 1)
        c.selection.insert("test.game")
        await c.apply()
        assert(!c.applying && c.apps[0].sdk == .target)
        IconTestState.delay = false
        print("PASS: slow icon downloads do not lock scanning or writing; scene reentry does not rescan")
    }
}
