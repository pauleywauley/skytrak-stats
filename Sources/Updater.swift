import Cocoa

enum Installer {
    static let appName = "SkyTrak Stats.app"

    /// Waits for this process to exit, puts the new app in place, then opens it.
    private static let swapScript = """
    pid="$1"; new="$2"; target="$3"
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 150 ]; do sleep 0.1; i=$((i+1)); done
    backup="$target.previous"
    rm -rf "$backup"
    [ -e "$target" ] && mv "$target" "$backup"
    if mv "$new" "$target" 2>/dev/null || ditto "$new" "$target"; then
      rm -rf "$backup"
    elif [ -e "$backup" ]; then
      mv "$backup" "$target"
    fi
    xattr -dr com.apple.quarantine "$target" 2>/dev/null
    open "$target"
    """

    static func replaceAndRelaunch(newApp: String, target: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", swapScript, "swap", String(getpid()), newApp, target]
        try process.run()
    }

    /// The downloaded file installs itself the first time it is opened.
    /// Returns true when this copy is about to quit in favor of the installed one.
    static func installIfNeeded() -> Bool {
        let files = FileManager.default
        #if DEV
        guard let testFolder = ProcessInfo.processInfo.environment["SKYTRAK_STATS_APPS"] else { return false }
        let folders = [testFolder]
        #else
        let folders = ["/Applications", NSHomeDirectory() + "/Applications"]
        #endif
        let current = Bundle.main.bundlePath
        if folders.contains(where: { current.hasPrefix($0 + "/") }) { return false }

        for folder in folders {
            try? files.createDirectory(atPath: folder, withIntermediateDirectories: true)
            guard files.isWritableFile(atPath: folder) else { continue }
            do {
                let work = files.temporaryDirectory.appendingPathComponent("SkyTrakStatsInstall-\(UUID().uuidString)")
                try files.createDirectory(at: work, withIntermediateDirectories: true)
                let copy = work.appendingPathComponent(appName).path
                try files.copyItem(atPath: current, toPath: copy)
                try replaceAndRelaunch(newApp: copy, target: folder + "/" + appName)
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return true
            } catch {
                continue
            }
        }
        return false
    }
}

/// Finds new releases on GitHub and installs them when asked.
final class Updater {
    struct State: Encodable {
        var phase: String   // checking, upToDate, available, offline, downloading, installing, failed
        var current: String
        var latest: String?
        var message: String?
    }

    static let repository = "pauleywauley/skytrak-stats"
    static let assetName = "SkyTrakStats.zip"

    var onChange: ((State) -> Void)?
    private(set) var state: State
    private var assetURL: URL?

    init() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        state = State(phase: "checking", current: version)
    }

    private func set(_ phase: String, latest: String? = nil, message: String? = nil) {
        DispatchQueue.main.async { [self] in
            state.phase = phase
            if let latest = latest { state.latest = latest }
            state.message = message
            onChange?(state)
        }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let parts = { (s: String) in s.split(separator: ".").map { Int($0) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    func check() {
        guard state.phase != "downloading", state.phase != "installing" else { return }
        set("checking")
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Updater.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SkyTrakStats", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [self] data, response, _ in
            guard let http = response as? HTTPURLResponse else { return set("offline") }
            guard http.statusCode == 200, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                return set(http.statusCode == 404 ? "upToDate" : "offline")
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let assets = json["assets"] as? [[String: Any]] ?? []
            let link = assets.first { $0["name"] as? String == Updater.assetName }?["browser_download_url"] as? String
            let allowed = "https://github.com/\(Updater.repository)/releases/download/"
            guard Updater.isNewer(latest, than: state.current), let link = link, link.hasPrefix(allowed) else {
                return set("upToDate", latest: latest)
            }
            assetURL = URL(string: link)
            set("available", latest: latest)
        }.resume()
    }

    func install() {
        guard state.phase == "available", let url = assetURL else { return }
        set("downloading")
        URLSession.shared.downloadTask(with: url) { [self] location, response, error in
            guard let location = location, (response as? HTTPURLResponse)?.statusCode == 200 else {
                return set("failed", message: error?.localizedDescription ?? "The download didn't finish.")
            }
            do {
                let app = try unpack(location)
                DispatchQueue.main.async { [self] in
                    set("installing")
                    do {
                        try Installer.replaceAndRelaunch(newApp: app, target: Bundle.main.bundlePath)
                        NSApp.terminate(nil)
                    } catch {
                        set("failed", message: error.localizedDescription)
                    }
                }
            } catch {
                set("failed", message: error.localizedDescription)
            }
        }.resume()
    }

    private struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw UpdateError("\(tool) failed") }
    }

    /// Unzips the download and confirms it really is a newer build of this app.
    private func unpack(_ download: URL) throws -> String {
        let files = FileManager.default
        let work = files.temporaryDirectory.appendingPathComponent("SkyTrakStatsUpdate-\(UUID().uuidString)")
        try files.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent("update.zip")
        try files.moveItem(at: download, to: zip)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])

        let app = work.appendingPathComponent(Installer.appName)
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              let version = info["CFBundleShortVersionString"] as? String,
              Updater.isNewer(version, than: state.current) else {
            throw UpdateError("The download wasn't a valid update.")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        return app.path
    }
}
