// Menu bar app for Ultimate Brain Stimulation.
// Toggles scrolling on/off and edits the same config file that bin/ubs reads.
import AppKit

let home = FileManager.default.homeDirectoryForCurrentUser.path
let configPath = home + "/.config/ultimate-brain-stimulation/config"
let stateDir = home + "/.cache/ultimate-brain-stimulation"
let disabledPath = stateDir + "/disabled"
let pidPath = stateDir + "/scroller.pid"
let currentAppPath = stateDir + "/current_app"
let launchAgentPath = home + "/Library/LaunchAgents/com.bryanfrds.ultimate-brain-stimulation.plist"
// Set by build.sh so the app can call the script that lives in the repo.
let ubsPath = Bundle.main.object(forInfoDictionaryKey: "UBSPath") as? String ?? ""

let apps: [(key: String, label: String)] = [
    ("instagram", "Instagram Reels"),
    ("tiktok", "TikTok"),
    ("douyin", "Douyin"),
    ("rotate", "Rotate (new app each prompt)"),
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

// MARK: - State

var isEnabled: Bool { !FileManager.default.fileExists(atPath: disabledPath) }

var isScrolling: Bool {
    guard let text = try? String(contentsOfFile: pidPath, encoding: .utf8),
          let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
    return kill(pid, 0) == 0
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

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        // Keep the icon in step with the scroller, which the hooks start and stop.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.updateIcon() }
    }

    func updateIcon() {
        let name: String
        if !isEnabled { name = "brain.head.profile" }
        else if isScrolling { name = "brain.fill" }
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
        let currentApp = config["APP"] ?? "instagram"
        let seconds = Int(config["SECONDS_PER_VIDEO"] ?? "") ?? 8

        let status: String
        if !isEnabled { status = "Off" }
        else if isScrolling {
            let app = (try? String(contentsOfFile: currentAppPath, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            status = "Scrolling \(apps.first { $0.key == app }?.label ?? app) while Claude works"
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

        let appHeader = NSMenuItem(title: "Doomscroll on", action: nil, keyEquivalent: "")
        appHeader.isEnabled = false
        menu.addItem(appHeader)
        for app in apps {
            let item = NSMenuItem(title: app.label, action: #selector(pickApp(_:)), keyEquivalent: "")
            item.representedObject = app.key
            item.state = app.key == currentApp ? .on : .off
            item.target = self
            item.indentationLevel = 1
            menu.addItem(item)
        }
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

    @objc func toggleEnabled() {
        runUbs([isEnabled ? "off" : "on"])
        updateIcon()
    }

    @objc func pickApp(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        writeConfig("APP", key)
        // Restart a running scroller so the new app takes effect straight away.
        if isScrolling { runUbs(["reset"]) }
        updateIcon()
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
