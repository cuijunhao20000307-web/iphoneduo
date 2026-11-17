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
    var fail = false, ignoreWrite = false
    func recoverSDK(forBundleID id: String) throws -> [NSNumber] { [26, 0, 0] }
    func loadApps() throws -> [FDAppRecord] { [record] }
    func applyVersions(_ payload: [String: [NSNumber]], dryRun: Bool) throws -> String {
        Thread.sleep(forTimeInterval: 0.1)
        if fail { throw NSError(domain: "test-write", code: 1) }
        if !ignoreWrite, let v = payload[record.bundleID] {
            record.sdkMajor = v[0].intValue
            record.sdkMinor = v[1].intValue
            record.sdkPatch = v[2].intValue
        }
        return "written"
    }
}
extension AppCatalog { func loadIcons() async {} }

@main struct RecoveryTests {
    @MainActor static func fresh() -> AppCatalog {
        for key in ["forced", "originals", "appliedTargets", "trialTargets"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        FDEngine.shared.record = FDAppRecord()
        FDEngine.shared.fail = false
        FDEngine.shared.ignoreWrite = false
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
    }
}
