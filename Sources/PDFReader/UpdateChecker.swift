import SwiftUI

/// Finds newer releases on GitHub and installs them by replacing the app bundle.
/// The new bundle is swapped in while the app runs; it takes effect on the next launch.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    static let releasesPage = URL(string: "https://github.com/Gremza/pdf-reader-free/releases/latest")!
    private static let latestRelease = URL(string: "https://api.github.com/repos/Gremza/pdf-reader-free/releases/latest")!
    private static let assetName = "PDF-Reader.zip"

    @Published var checkAutomatically: Bool {
        didSet { UserDefaults.standard.set(checkAutomatically, forKey: "checkForUpdates") }
    }
    @Published var installAutomatically: Bool {
        didSet { UserDefaults.standard.set(installAutomatically, forKey: "installUpdatesAutomatically") }
    }
    @Published private(set) var isBusy = false

    /// Set by "Restart Now"; the app opens itself again once it has quit.
    private var relaunchOnQuit = false
    /// A version already installed in place, waiting for a restart.
    private var installedVersion: String?
    private var timer: Timer?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Only a real .app can replace itself; `swift build` binaries open the download page instead.
    private var canInstall: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["checkForUpdates": true, "installUpdatesAutomatically": false])
        checkAutomatically = defaults.bool(forKey: "checkForUpdates")
        installAutomatically = defaults.bool(forKey: "installUpdatesAutomatically")
    }

    // MARK: Checking

    /// Checks shortly after launch and then once a day, while automatic checks are on.
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.checkInBackground()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { UpdateChecker.shared.checkInBackground() }
        }
    }

    private func checkInBackground() {
        guard checkAutomatically, !isBusy, installedVersion == nil else { return }
        Task { await check(manual: false) }
    }

    /// "Check for Updates…": unlike the automatic check, it also reports "up to date" and errors.
    func checkNow() {
        guard !isBusy else { return }
        Task { await check(manual: true) }
    }

    private func check(manual: Bool) async {
        isBusy = true
        defer { isBusy = false }
        let release: Release
        do {
            release = try await fetchLatestRelease()
        } catch {
            if manual { showAlert("Can't check for updates", error.localizedDescription) }
            return
        }

        if let installedVersion, !Self.isNewer(release.version, than: installedVersion) {
            if manual { askToRestart(version: installedVersion) }
            return
        }
        guard Self.isNewer(release.version, than: currentVersion) else {
            if manual { showAlert("PDF Gremza is up to date", "Version \(currentVersion) is the newest version.") }
            return
        }

        guard canInstall, let asset = release.asset else {
            if askToDownload(release) { NSWorkspace.shared.open(Self.releasesPage) }
            return
        }
        if installAutomatically && !manual {
            if await install(release, from: asset) { askToRestart(version: release.version) }
        } else if askToInstall(release) {
            if await install(release, from: asset) { restart() }
        }
    }

    private struct Release {
        let version: String
        let asset: URL?
    }

    private func fetchLatestRelease() async throws -> Release {
        var request = URLRequest(url: Self.latestRelease)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { throw UpdateError("GitHub sent an unexpected answer.") }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let asset = assets.first { $0["name"] as? String == Self.assetName }
        return Release(
            version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
            asset: (asset?["browser_download_url"] as? String).flatMap(URL.init(string:))
        )
    }

    /// Compares dotted versions number by number, so "1.10" is newer than "1.9" and "1.2" equals "1.2.0".
    nonisolated static func isNewer(_ version: String, than other: String) -> Bool {
        let parts = { (text: String) in text.split(separator: ".").map { Int($0) ?? 0 } }
        let (a, b) = (parts(version), parts(other))
        for index in 0..<max(a.count, b.count) {
            let (x, y) = (index < a.count ? a[index] : 0, index < b.count ? b[index] : 0)
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Installing

    /// Downloads the zip, checks the app inside and swaps it in for the running bundle.
    private func install(_ release: Release, from asset: URL) async -> Bool {
        let appURL = Bundle.main.bundleURL
        let bundleID = Bundle.main.bundleIdentifier
        do {
            try await Task.detached {
                let (zip, _) = try await URLSession.shared.download(from: asset)
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent("PDF Gremza Update \(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: folder) }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path])
                try? FileManager.default.removeItem(at: zip)

                let contents = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                guard let newApp = contents.first(where: { $0.pathExtension == "app" }),
                      let bundle = Bundle(url: newApp),
                      bundle.bundleIdentifier == bundleID,
                      let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                      !UpdateChecker.isNewer(version, than: release.version), !UpdateChecker.isNewer(release.version, than: version)
                else { throw UpdateError("The download doesn't contain the expected version of PDF Gremza.") }
                _ = try FileManager.default.replaceItemAt(appURL, withItemAt: newApp)
            }.value
            installedVersion = release.version
            return true
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "The update can't be installed"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "Open Download Page")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(Self.releasesPage) }
            return false
        }
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError("The download couldn't be unpacked.") }
    }

    /// Quits through the usual unsaved-changes check; the app reopens only if it really quits.
    private func restart() {
        relaunchOnQuit = true
        NSApp.terminate(nil)
        // Still running: the user kept their unsaved changes
        relaunchOnQuit = false
    }

    /// Called from `applicationWillTerminate`.
    func relaunchIfNeeded() {
        guard relaunchOnQuit else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; open \"$2\"",
            "sh", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path,
        ]
        try? process.run()
    }

    // MARK: Alerts

    private func askToInstall(_ release: Release) -> Bool {
        let alert = NSAlert()
        alert.messageText = "A new version of PDF Gremza is available"
        alert.informativeText = "PDF Gremza \(release.version) is available. You have \(currentVersion). Would you like to install it now?"
        alert.addButton(withTitle: "Install and Restart")
        alert.addButton(withTitle: "Later")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func askToDownload(_ release: Release) -> Bool {
        let alert = NSAlert()
        alert.messageText = "A new version of PDF Gremza is available"
        alert.informativeText = "PDF Gremza \(release.version) is available. You have \(currentVersion)."
        alert.addButton(withTitle: "Open Download Page")
        alert.addButton(withTitle: "Later")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func askToRestart(version: String) {
        let alert = NSAlert()
        alert.messageText = "PDF Gremza \(version) is ready"
        alert.informativeText = "The update will be used after you restart PDF Gremza."
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { restart() }
    }

    private func showAlert(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// "Check for Updates…" and the update settings, in the app menu below "About PDF Gremza".
struct UpdateMenuItems: View {
    @ObservedObject var updater: UpdateChecker

    var body: some View {
        Button(updater.isBusy ? "Checking for Updates…" : "Check for Updates…", action: updater.checkNow)
            .disabled(updater.isBusy)
        Toggle("Check for Updates Automatically", isOn: $updater.checkAutomatically)
        Toggle("Install Updates Automatically", isOn: $updater.installAutomatically)
            .disabled(!updater.checkAutomatically)
    }
}
