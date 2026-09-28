// Menu bar app for Ultimate Brain Stimulation.
// Toggles scrolling on/off, edits the same config file that bin/ubs reads, and
// in popup mode shows the feed in a small floating window while Claude works.
import AppKit
import WebKit

let home = FileManager.default.homeDirectoryForCurrentUser.path
let configPath = home + "/.config/ultimate-brain-stimulation/config"
let stateDir = home + "/.cache/ultimate-brain-stimulation"
let sessionsDir = stateDir + "/sessions"
let disabledPath = stateDir + "/disabled"
let pidPath = stateDir + "/scroller.pid"
let currentAppPath = stateDir + "/current_app"
let logPath = stateDir + "/log"
let launchAgentPath = home + "/Library/LaunchAgents/com.bryanfrds.ultimate-brain-stimulation.plist"
// Set by build.sh so the app can call the script that lives in the repo.
let ubsPath = Bundle.main.object(forInfoDictionaryKey: "UBSPath") as? String ?? ""

let apps: [(key: String, label: String, url: String)] = [
    ("instagram", "Instagram Reels", "https://www.instagram.com/reels/"),
    ("tiktok", "TikTok", "https://www.tiktok.com/foryou"),
    ("douyin", "Douyin", "https://www.douyin.com/?recommend=1"),
    ("rotate", "Rotate (new app each prompt)", ""),
]
let secondChoices = [5, 8, 12, 20, 30]

// MARK: - Config file

func readConfig() -> [String: String] {
    guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return [:] }
    var values: [String: String] = [:]
    for line in text.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
        let key = String(trimmed[..<eq])
        var value = String(trimmed[trimmed.index(after: eq)...])
        if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]) }
        values[key] = value.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
    }
    return values
}

// Replace KEY=... in place so comments and other settings survive; append if missing.
func writeConfig(_ key: String, _ value: String) {
    var lines = (try? String(contentsOfFile: configPath, encoding: .utf8))?
        .components(separatedBy: "\n") ?? []
    if let i = lines.firstIndex(where: { $0.hasPrefix(key + "=") }) {
        lines[i] = "\(key)=\(value)"
    } else {
        if lines.last == "" { lines.removeLast() }
        lines.append("\(key)=\(value)")
        lines.append("")
    }
    try? FileManager.default.createDirectory(
        atPath: (configPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? lines.joined(separator: "\n").write(toFile: configPath, atomically: true, encoding: .utf8)
}

func log(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(formatter.string(from: Date())) [menubar] \(message)\n"
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
    }
}

// MARK: - State

var isEnabled: Bool { !FileManager.default.fileExists(atPath: disabledPath) }

var isPopupMode: Bool { (readConfig()["SHOW_IN"] ?? "popup") != "browser" }

var isScrollingInBrowser: Bool {
    guard let text = try? String(contentsOfFile: pidPath, encoding: .utf8),
          let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
    return kill(pid, 0) == 0
}

// A Claude session is busy while its file exists and a hook touched it recently.
func claudeIsWorking() -> Bool {
    let fm = FileManager.default
    let staleMinutes = Double(readConfig()["STALE_MINUTES"] ?? "") ?? 10
    guard let names = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return false }
    return names.contains { name in
        guard let date = (try? fm.attributesOfItem(atPath: sessionsDir + "/" + name))?[.modificationDate] as? Date
        else { return false }
        return Date().timeIntervalSince(date) < staleMinutes * 60
    }
}

func currentApp() -> String {
    let fromState = (try? String(contentsOfFile: currentAppPath, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if apps.contains(where: { $0.key == fromState && !$0.url.isEmpty }) { return fromState }
    let configured = readConfig()["APP"] ?? "instagram"
    return configured == "rotate" ? "instagram" : configured
}

func runUbs(_ args: [String]) {
    guard !ubsPath.isEmpty else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: ubsPath)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
}

// MARK: - Popup

// A panel that floats above other windows without taking focus from them,
// so you can keep typing in your terminal while it plays.
final class FeedPanel: NSPanel {
    override var canBecomeKey: Bool { true }  // still allows typing into it, e.g. to log in
}

final class FeedPopup: NSObject, NSWindowDelegate {
    private var panel: FeedPanel?
    private var webView: WKWebView?
    private var loadedApp: String?
    private var advanceTimer: Timer?
    private(set) var isShown = false
    // Closing the popup by hand keeps it closed until Claude next goes idle.
    private(set) var dismissed = false
    var onClose: (() -> Void)?

    // Where the feed is: URL plus the position of the first video and of any
    // scrolling container. If none of it changes, "next" didn't move the feed.
    private let probeJS = """
    (function () {
      var v = document.querySelector("video");
      var tops = Array.prototype.filter.call(document.querySelectorAll("div"), function (e) {
        return e.scrollTop > 0;
      }).map(function (e) { return Math.round(e.scrollTop); }).join(",");
      return location.href + "|" + (v ? Math.round(v.getBoundingClientRect().top) + ":" + (v.currentSrc || "").slice(-12) : "none") + "|" + tops + "|" + Math.round(scrollY);
    })()
    """
    private let pauseJS = """
    document.querySelectorAll('video').forEach(function (v) {
      if (!v.paused) { v.dataset.ubsPaused = '1'; v.pause(); }
    });
    """
    private let resumeJS = """
    document.querySelectorAll('video').forEach(function (v) {
      if (v.dataset.ubsPaused) { delete v.dataset.ubsPaused; v.play(); }
    });
    """
    private let diagnoseJS = """
    JSON.stringify({title: document.title, w: innerWidth, h: innerHeight,
      videos: Array.prototype.map.call(document.querySelectorAll("video"), function (v) {
        return {paused: v.paused, ready: v.readyState, muted: v.muted, err: v.error && v.error.code, top: Math.round(v.getBoundingClientRect().top)};
      }).slice(0, 4),
      text: document.body ? document.body.innerText.replace(/\\s+/g, " ").slice(0, 200) : ""})
    """
    // Fallbacks if a real key press doesn't move the feed: a synthetic key
    // event, then scrolling a snap-scrolling feed container (Instagram).
    private let fallbackJS = """
    (function () {
      var opts = {key: 'ArrowDown', code: 'ArrowDown', keyCode: 40, which: 40, bubbles: true};
      (document.activeElement || document.body).dispatchEvent(new KeyboardEvent('keydown', opts));
      document.dispatchEvent(new KeyboardEvent('keydown', opts));
      var s = Array.prototype.find.call(document.querySelectorAll('div'), function (e) {
        return getComputedStyle(e).scrollSnapType.indexOf('y') === 0 && e.scrollHeight > e.clientHeight + 100;
      });
      if (s) s.scrollBy({top: s.clientHeight, behavior: 'smooth'});
    })()
    """

    private func makePanel() -> FeedPanel {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let height = (visible.height * 0.85).rounded()
        let width = (height * 9 / 16).rounded()
        let frame = NSRect(x: visible.maxX - width - 16, y: visible.minY + (visible.height - height) / 2,
                           width: width, height: height)
        let panel = FeedPanel(contentRect: frame,
                              styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.title = "Ultimate Brain Stimulation"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        // Remembers where you last moved or resized it.
        panel.setFrameAutosaveName("FeedPopup")

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // keeps you logged in between launches
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: panel.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        // Desktop feed pages are laid out for wide windows; zoom out so they fit.
        webView.pageZoom = 0.6
        panel.contentView!.addSubview(webView)
        self.webView = webView
        return panel
    }

    func show(app: String) {
        if panel == nil { panel = makePanel() }
        guard let panel, let webView else { return }
        if loadedApp != app, let url = apps.first(where: { $0.key == app })?.url, let u = URL(string: url) {
            webView.load(URLRequest(url: u))
            loadedApp = app
            log("popup: loading \(app)")
        } else {
            webView.evaluateJavaScript(resumeJS)
        }
        panel.orderFrontRegardless()
        isShown = true
        scheduleAdvance()
    }

    func hide() {
        advanceTimer?.invalidate()
        advanceTimer = nil
        webView?.evaluateJavaScript(pauseJS)
        panel?.orderOut(nil)
        isShown = false
    }

    func resetDismissed() { dismissed = false }

    func windowWillClose(_ notification: Notification) {
        advanceTimer?.invalidate()
        advanceTimer = nil
        webView?.evaluateJavaScript(pauseJS)
        isShown = false
        dismissed = true
        onClose?()
    }

    private func scheduleAdvance() {
        advanceTimer?.invalidate()
        let seconds = Double(readConfig()["SECONDS_PER_VIDEO"] ?? "").flatMap { $0 > 0 ? $0 : nil } ?? 8
        advanceTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            self?.next()
        }
    }

    // Send a real down-arrow key straight to the web view. It doesn't need
    // the window to be focused, so it never touches what you're typing in.
    private func pressDown() {
        guard let webView, let panel else { return }
        let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: panel.windowNumber, context: nil,
                                            characters: down, charactersIgnoringModifiers: down,
                                            isARepeat: false, keyCode: 125) {
                type == .keyDown ? webView.keyDown(with: event) : webView.keyUp(with: event)
            }
        }
    }

    func next() {
        guard let webView else { return }
        webView.evaluateJavaScript(diagnoseJS) { info, _ in log("popup: page \(info as? String ?? "?")") }
        webView.evaluateJavaScript(probeJS) { [weak self] before, _ in
            guard let self else { return }
            self.pressDown()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                webView.evaluateJavaScript(self.probeJS) { after, _ in
                    let b = before as? String ?? "?", a = after as? String ?? "?"
                    if a == b {
                        webView.evaluateJavaScript(self.fallbackJS)
                        log("popup: key didn't move the feed, used fallback (video: \(a))")
                    } else {
                        log("popup: next video (\(a))")
                    }
                }
            }
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    let popup = FeedPopup()
    var previewing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.delegate = self
        // Closing the popup by hand also ends a "Show Popup Now" preview.
        popup.onClose = { [weak self] in self?.previewing = false }
        statusItem.menu = menu
        tick()
        // The hooks only write files; this loop turns that into showing/hiding the popup.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func tick() {
        let working = claudeIsWorking()
        if !working { popup.resetDismissed() }
        let wantPopup = previewing || (isEnabled && isPopupMode && working && !popup.dismissed)
        if wantPopup && !popup.isShown {
            popup.show(app: currentApp())
        } else if !wantPopup && popup.isShown {
            popup.hide()
        }
        updateIcon()
    }

    func updateIcon() {
        let name: String
        if !isEnabled { name = "brain.head.profile" }
        else if popup.isShown || isScrollingInBrowser { name = "brain.fill" }
        else { name = "brain" }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Ultimate Brain Stimulation")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = !isEnabled
    }

    // Rebuild every time the menu opens so it always shows the current settings.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let config = readConfig()
        let configuredApp = config["APP"] ?? "instagram"
        let seconds = Int(config["SECONDS_PER_VIDEO"] ?? "") ?? 8

        let status: String
        if !isEnabled { status = "Off" }
        else if popup.isShown || isScrollingInBrowser {
            let label = apps.first { $0.key == currentApp() }?.label ?? currentApp()
            status = "Scrolling \(label) while Claude works"
        } else { status = "Waiting for Claude to start working" }
        let statusLine = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Auto-scroll", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.state = isEnabled ? .on : .off
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())

        addHeader("Doomscroll on")
        for app in apps {
            let item = NSMenuItem(title: app.label, action: #selector(pickApp(_:)), keyEquivalent: "")
            item.representedObject = app.key
            item.state = app.key == configuredApp ? .on : .off
            item.target = self
            item.indentationLevel = 1
            menu.addItem(item)
        }
        menu.addItem(.separator())

        addHeader("Show it in")
        for (mode, label) in [("popup", "Popup on the side"), ("browser", "Chrome tab")] {
            let item = NSMenuItem(title: label, action: #selector(pickDisplay(_:)), keyEquivalent: "")
            item.representedObject = mode
            item.state = (mode == "popup") == isPopupMode ? .on : .off
            item.target = self
            item.indentationLevel = 1
            menu.addItem(item)
        }
        let preview = NSMenuItem(title: previewing ? "Hide Popup" : "Show Popup Now (to log in or test)",
                                 action: #selector(togglePreview), keyEquivalent: "")
        preview.target = self
        preview.indentationLevel = 1
        menu.addItem(preview)
        menu.addItem(.separator())

        let secondsItem = NSMenuItem(title: "Seconds per video", action: nil, keyEquivalent: "")
        let secondsMenu = NSMenu()
        for s in secondChoices {
            let item = NSMenuItem(title: "\(s) seconds", action: #selector(pickSeconds(_:)), keyEquivalent: "")
            item.tag = s
            item.state = s == seconds ? .on : .off
            item.target = self
            secondsMenu.addItem(item)
        }
        secondsItem.submenu = secondsMenu
        menu.addItem(secondsItem)

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = FileManager.default.fileExists(atPath: launchAgentPath) ? .on : .off
        login.target = self
        menu.addItem(login)

        let settings = NSMenuItem(title: "Open Settings File…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func addHeader(_ title: String) {
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
    }

    @objc func toggleEnabled() {
        runUbs([isEnabled ? "off" : "on"])
        tick()
    }

    @objc func pickApp(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        writeConfig("APP", key)
        // Switch straight away rather than waiting for the next prompt.
        if key != "rotate" { try? key.write(toFile: currentAppPath, atomically: true, encoding: .utf8) }
        if isScrollingInBrowser { runUbs(["reset"]) }
        if popup.isShown {
            popup.hide()
            tick()
        }
    }

    @objc func pickDisplay(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        writeConfig("SHOW_IN", mode)
        if isScrollingInBrowser { runUbs(["reset"]) }
        tick()
    }

    @objc func togglePreview() {
        previewing.toggle()
        tick()
    }

    @objc func pickSeconds(_ sender: NSMenuItem) {
        writeConfig("SECONDS_PER_VIDEO", String(sender.tag))
    }

    @objc func toggleLogin() {
        let fm = FileManager.default
        if fm.fileExists(atPath: launchAgentPath) {
            try? fm.removeItem(atPath: launchAgentPath)
            return
        }
        let plist: [String: Any] = [
            "Label": "com.bryanfrds.ultimate-brain-stimulation",
            "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
            "RunAtLoad": true,
        ]
        try? fm.createDirectory(atPath: (launchAgentPath as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        (plist as NSDictionary).write(toFile: launchAgentPath, atomically: true)
    }

    @objc func openSettings() {
        if !FileManager.default.fileExists(atPath: configPath) { writeConfig("APP", "instagram") }
        // The file has no extension, so ask for the default text editor explicitly.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-t", configPath]
        try? p.run()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
