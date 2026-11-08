import Cocoa
import WebKit

/// Clicking this panel must not take focus away from SkyTrak.
final class StatsWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class StatsWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class AppController: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    private let displayKey = "displayName", clubKey = "selectedClub", fillKey = "fillScreen"
    private let clearedKey = "mapClearedAt", modeKey = "mapMode"
    private let defaults = UserDefaults.standard
    private var window: StatsWindow?
    private var windowFillsScreen = false
    private var webView: StatsWebView!
    private lazy var engine = Engine(selectedClub: defaults.string(forKey: clubKey))
    private let updater = Updater()
    private var pageReady = false
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ note: Notification) {
        if Installer.installIfNeeded() { return }
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Watching SkyTrak for new shots")
        buildMenu()

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "app")
        webView = StatsWebView(frame: .zero, configuration: config)
        webView.isHidden = true
        placeWindow()

        let page = Bundle.main.url(forResource: "index", withExtension: "html")!
        webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())

        engine.onSend = { [weak self] message in self?.deliver(message) }
        updater.onChange = { [weak self] _ in self?.sendUpdateState() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.placeWindow() }
        Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in self?.updater.check() }
        #if DEV
        runDevHooks()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu() {
        let menu = NSMenu(), item = NSMenuItem()
        menu.addItem(item)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit SkyTrak Stats", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu
        NSApp.mainMenu = menu
    }

    // MARK: Window placement

    private var screensLeftToRight: [NSScreen] { NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX } }

    private func targetScreen() -> NSScreen? {
        let screens = screensLeftToRight
        if let name = defaults.string(forKey: displayKey), let saved = screens.first(where: { $0.localizedName == name }) {
            return saved
        }
        return screens.last
    }

    /// With two or more displays the app fills the right-most one by default. On a
    /// single display it starts as a window so it can't cover SkyTrak unasked.
    private var wantsFill: Bool { defaults.object(forKey: fillKey) as? Bool ?? (NSScreen.screens.count > 1) }

    private func placeWindow() {
        guard let screen = targetScreen() else { return }
        let fills = wantsFill
        #if DEV
        if let size = devSize { return showDevWindow(size) }
        #endif
        if window == nil || windowFillsScreen != fills {
            let style: NSWindow.StyleMask = fills
                ? [.borderless, .nonactivatingPanel]
                : [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel]
            install(StatsWindow(contentRect: screen.visibleFrame, styleMask: style, backing: .buffered, defer: false))
            windowFillsScreen = fills
        }
        // Above the menu bar, so a filled display shows nothing but the stats.
        window?.level = fills ? NSWindow.Level(Int(CGWindowLevelForKey(.mainMenuWindow)) + 1) : .normal
        if fills {
            window?.setFrame(screen.frame, display: true)
        } else {
            let area = screen.visibleFrame
            window?.setFrame(area.insetBy(dx: area.width * 0.08, dy: area.height * 0.08), display: true)
        }
        window?.orderFrontRegardless()
    }

    private func install(_ next: StatsWindow) {
        next.title = "SkyTrak Stats"
        next.isReleasedWhenClosed = false
        next.hidesOnDeactivate = false
        next.backgroundColor = .black
        next.acceptsMouseMovedEvents = true
        next.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let previous = window
        previous?.contentView = nil
        next.contentView = webView
        window = next
        previous?.close()
    }

    private func moveToNextDisplay() {
        let screens = screensLeftToRight
        guard screens.count > 1, let current = targetScreen(), let i = screens.firstIndex(of: current) else { return }
        defaults.set(screens[(i + 1) % screens.count].localizedName, forKey: displayKey)
        placeWindow()
    }

    // MARK: Page bridge

    private func deliver(_ message: String) {
        guard pageReady else { return }
        webView.evaluateJavaScript("receive(\(message))", completionHandler: nil)
    }

    private func sendPrefs() {
        let prefs: [String: Any] = [
            "club": defaults.string(forKey: clubKey) ?? NSNull(),
            "mapClearedAt": defaults.double(forKey: clearedKey),
            "mapMode": defaults.string(forKey: modeKey) ?? "shape",
            "fill": wantsFill,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: prefs),
              let text = String(data: body, encoding: .utf8) else { return }
        deliver("{\"type\":\"prefs\",\"data\":\(text)}")
    }

    private func sendUpdateState() {
        guard let body = try? JSONEncoder().encode(updater.state),
              let text = String(data: body, encoding: .utf8) else { return }
        deliver("{\"type\":\"update\",\"data\":\(text)}")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "ready":
            pageReady = true
            webView.isHidden = false
            sendPrefs()
            engine.start()
            sendUpdateState()
            updater.check()
        case "selectClub":
            let club = body["club"] as? String
            defaults.set(club, forKey: clubKey)
            engine.selectClub(club)
        case "setShotClub":
            if let id = body["id"] as? String, let club = body["club"] as? String { engine.setClub(id: id, club: club) }
        case "install": updater.install()
        case "check": updater.check()
        case "clearMap": defaults.set(body["time"] as? Double ?? 0, forKey: clearedKey)
        case "mapMode": defaults.set(body["mode"] as? String, forKey: modeKey)
        case "toggleFill":
            defaults.set(!wantsFill, forKey: fillKey)
            placeWindow()
            sendPrefs()
        case "nextDisplay": moveToNextDisplay()
        case "quit": NSApp.terminate(nil)
        default: break
        }
    }

    // MARK: Test hooks (development builds only)

    #if DEV
    private var devSize: NSSize? {
        guard let text = devArgument("--size") else { return nil }
        let parts = text.split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? NSSize(width: parts[0], height: parts[1]) : nil
    }

    private func devArgument(_ name: String) -> String? {
        CommandLine.arguments.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
    }

    private func showDevWindow(_ size: NSSize) {
        if window == nil {
            install(StatsWindow(contentRect: NSRect(origin: NSPoint(x: -6000, y: -6000), size: size),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false))
        }
        window?.orderFrontRegardless()
    }

    private func devClick(_ point: NSPoint) {
        guard let w = window else { return }
        let height = w.frame.height
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: NSPoint(x: point.x, y: height - point.y), modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { w.sendEvent(e) }
        }
    }

    private func runDevHooks() {
        if CommandLine.arguments.contains("--update-now") {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                if self?.updater.state.phase == "available" { self?.updater.install() }
            }
        }
        let delay = Double(devArgument("--delay") ?? "3") ?? 3
        if let click = devArgument("--click") {
            let xy = click.split(separator: ",").compactMap { Double($0) }
            let clickDelay = Double(devArgument("--click-delay") ?? "") ?? delay - 1
            DispatchQueue.main.asyncAfter(deadline: .now() + clickDelay) { [weak self] in
                self?.devClick(NSPoint(x: xy[0], y: xy[1]))
            }
        }
        guard let output = devArgument("--snapshot") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            let capture = {
                self.webView.takeSnapshot(with: nil) { image, _ in
                    if let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                       let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: output))
                    }
                    NSApp.terminate(nil)
                }
            }
            if let js = self.devArgument("--js") {
                self.webView.evaluateJavaScript(js) { _, _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: capture)
                }
            } else {
                capture()
            }
        }
    }
    #endif
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
