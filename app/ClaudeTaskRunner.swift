import Cocoa
import WebKit

// MARK: - Native Bridge: Handles messages from JavaScript
class NativeBridge: NSObject, WKScriptMessageHandler {
    let tasksDir: String

    init(tasksDir: String) {
        self.tasksDir = tasksDir
        super.init()
        // Ensure tasks directory exists
        try? FileManager.default.createDirectory(
            atPath: tasksDir, withIntermediateDirectories: true
        )
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }
        let action = body["action"] as? String ?? ""

        switch action {
        case "saveGroup":
            // Save a single group JSON to ~/claude-auto/tasks/{id}.json
            guard let groupJSON = body["data"] as? [String: Any],
                  let groupId = groupJSON["id"] as? String else { return }
            let filePath = (tasksDir as NSString).appendingPathComponent("\(groupId).json")
            do {
                let data = try JSONSerialization.data(
                    withJSONObject: groupJSON, options: [.prettyPrinted, .sortedKeys]
                )
                try data.write(to: URL(fileURLWithPath: filePath))
            } catch {
                NSLog("Failed to save group \(groupId): \(error)")
            }

        case "deleteGroup":
            // Delete a group JSON file
            guard let groupId = body["groupId"] as? String else { return }
            let filePath = (tasksDir as NSString).appendingPathComponent("\(groupId).json")
            try? FileManager.default.removeItem(atPath: filePath)

        case "loadAllGroups":
            // Read all JSON files from tasks dir and send back to JS
            guard let webView = body["_webView"] as? WKWebView else { return }
            loadAndSendGroups(to: webView)

        case "runTasks":
            // Open a new Terminal window and run executor.sh
            let groupFile = body["groupFile"] as? String ?? ""
            let model = body["model"] as? String ?? "haiku"
            let executorPath = NSString("~/claude-auto/executor.sh").expandingTildeInPath

            let script: String
            if !groupFile.isEmpty {
                script = "tell application \"Terminal\"\nactivate\ndo script \"\(executorPath) '\(groupFile)' '\(model)'\"\nend tell"
            } else {
                script = "tell application \"Terminal\"\nactivate\ndo script \"\(executorPath)\"\nend tell"
            }

            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
                if let error = error {
                    NSLog("AppleScript error: \(error)")
                }
            }

        default:
            NSLog("Unknown bridge action: \(action)")
        }
    }

    func loadAndSendGroups(to webView: WKWebView) {
        var groups: [[String: Any]] = []
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: tasksDir) else { return }

        for file in files where file.hasSuffix(".json") {
            let path = (tasksDir as NSString).appendingPathComponent(file)
            guard let data = fm.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            groups.append(json)
        }

        if let jsonData = try? JSONSerialization.data(withJSONObject: groups),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            let escaped = jsonStr.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
            DispatchQueue.main.async {
                webView.evaluateJavaScript(
                    "if(window._onGroupsLoaded) window._onGroupsLoaded('\(escaped)')"
                )
            }
        }
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var bridge: NativeBridge!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let tasksDir = NSString("~/claude-auto/tasks").expandingTildeInPath

        // Native bridge for JS → filesystem
        bridge = NativeBridge(tasksDir: tasksDir)

        // WKWebView config with message handler
        let config = WKWebViewConfiguration()
        let storeID = UUID(uuidString: "C1A0DE00-C0DE-0000-A000-000000000001")!
        let store = WKWebsiteDataStore(forIdentifier: storeID)
        config.websiteDataStore = store
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.userContentController.add(bridge, name: "nativeBridge")

        // Create web view
        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")

        // Window
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let windowWidth: CGFloat = min(1280, screenFrame.width * 0.85)
        let windowHeight: CGFloat = min(860, screenFrame.height * 0.85)
        let windowX = screenFrame.origin.x + (screenFrame.width - windowWidth) / 2
        let windowY = screenFrame.origin.y + (screenFrame.height - windowHeight) / 2

        window = NSWindow(
            contentRect: NSRect(x: windowX, y: windowY, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Claude Todo"
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.backgroundColor = NSColor(red: 0.149, green: 0.149, blue: 0.141, alpha: 1)
        window.minSize = NSSize(width: 800, height: 500)
        window.contentView = webView
        window.appearance = NSAppearance(named: .darkAqua)

        // Load HTML
        let htmlPath = NSString("~/claude-auto/dashboard.html").expandingTildeInPath
        let htmlURL = URL(fileURLWithPath: htmlPath)

        if FileManager.default.fileExists(atPath: htmlPath) {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        } else {
            webView.loadHTMLString("<html><body style='background:#262624;color:#f5f4ef;font-family:system-ui;display:flex;align-items:center;justify-content:center;height:100vh;'><h1>dashboard.html not found</h1></body></html>", baseURL: nil)
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

// MARK: - Main
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)

let mainMenu = NSMenu()

let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(NSMenuItem(title: "About Claude Todo", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
appMenu.addItem(NSMenuItem.separator())
appMenu.addItem(NSMenuItem(title: "Quit Claude Todo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
appMenuItem.submenu = appMenu

let editMenuItem = NSMenuItem()
mainMenu.addItem(editMenuItem)
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
editMenu.addItem(NSMenuItem.separator())
editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
editMenuItem.submenu = editMenu

let viewMenuItem = NSMenuItem()
mainMenu.addItem(viewMenuItem)
let viewMenu = NSMenu(title: "View")
viewMenu.addItem(NSMenuItem(title: "Reload", action: #selector(WKWebView.reload(_:)), keyEquivalent: "r"))
viewMenuItem.submenu = viewMenu

let windowMenuItem = NSMenuItem()
mainMenu.addItem(windowMenuItem)
let windowMenu = NSMenu(title: "Window")
windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
windowMenu.addItem(NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f"))
windowMenuItem.submenu = windowMenu

app.mainMenu = mainMenu
app.run()
