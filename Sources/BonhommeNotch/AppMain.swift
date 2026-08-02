import AppKit
import Foundation
import BonhommeNotchCore

@main
enum BonhommeNotchMain {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--help") || args.contains("-h") {
            printHelp()
            exit(0)
        }
        if args.contains("--version") {
            print("BonhommeNotch 0.1.0")
            exit(0)
        }
        if args.contains("--socket-selftest") {
            let code = SocketSelfTest.run()
            exit(Int32(code))
        }
        if args.contains("--print-paths") {
            print("socket: \(BonhommePaths.socketPath())")
            print("status: \(BonhommePaths.statusPath())")
            print("support: \(BonhommePaths.applicationSupportDirectory())")
            exit(0)
        }
        if args.contains("--status") {
            let path = BonhommePaths.statusPath()
            if let snap = try? StatusSnapshot.load(from: path) {
                print(String(data: try! JSONSerialization.data(withJSONObject: snap.jsonObject(), options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
                exit(0)
            } else {
                fputs("no status at \(path)\n", stderr)
                exit(1)
            }
        }

        // Full app: menu bar + socket.
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    static func printHelp() {
        print("""
        BonhommeNotch — local multi-agent telemetry HUD (menu bar)

        Usage:
          BonhommeNotch                 Launch menu-bar app + socket bridge
          BonhommeNotch --socket-selftest
          BonhommeNotch --status
          BonhommeNotch --print-paths
          BonhommeNotch --version

        Environment:
          BONHOMME_NOTCH_SOCKET   Override Unix socket path
          AGENT_NOTCH_SOCKET      Compat override (same)

        Default socket:
          ~/Library/Application Support/BonhommeNotch/notch.sock
        """)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SessionStore()
    var bridge: SocketBridge!
    var statusItem: NSStatusItem?
    var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        bridge = SocketBridge(store: store)
        do {
            try bridge.start()
            fputs("[BonhommeNotch] socket listening at \(bridge.socketPath)\n", stderr)
        } catch {
            fputs("[BonhommeNotch] socket start failed: \(error)\n", stderr)
        }

        store.onChange = { [weak self] in
            DispatchQueue.main.async { self?.refreshMenuBar() }
        }

        setupMenuBar()
        refreshMenuBar()
        bridge.writeStatus()

        // Periodic status rewrite for external observers.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.bridge.writeStatus()
            self?.refreshMenuBar()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        bridge?.stop()
    }

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.title = "BN"
            button.toolTip = "BonhommeNotch"
        }
        statusItem = item
        refreshMenuBar()
    }

    private func refreshMenuBar() {
        let ranked = store.ranked()
        let title: String
        if ranked.isEmpty {
            title = "BN"
        } else if let first = ranked.first, first.attention == .needsYou {
            title = "BN·!"
        } else {
            title = "BN·\(ranked.count)"
        }
        statusItem?.button?.title = title

        let menu = NSMenu()
        menu.addItem(withTitle: store.statusSummary, action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        if ranked.isEmpty {
            menu.addItem(withTitle: "No agent sessions", action: nil, keyEquivalent: "")
        } else {
            for session in ranked.prefix(20) {
                let line = session.focusLine
                let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                item.representedObject = session.sessionID
                menu.addItem(item)

                if session.attention == .needsYou && session.gateWaiting
                    && GateDecisionBuilder.supportsBlockingGate(session.source) {
                    let approve = NSMenuItem(
                        title: "  Approve",
                        action: #selector(approveGate(_:)),
                        keyEquivalent: ""
                    )
                    approve.target = self
                    approve.representedObject = session.sessionID
                    menu.addItem(approve)

                    let deny = NSMenuItem(
                        title: "  Deny",
                        action: #selector(denyGate(_:)),
                        keyEquivalent: ""
                    )
                    deny.target = self
                    deny.representedObject = session.sessionID
                    menu.addItem(deny)
                }
            }
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Copy status summary", action: #selector(copyStatus), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "Quit BonhommeNotch", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items {
            if item.action == #selector(copyStatus) || item.action == #selector(quit) {
                item.target = self
            }
        }
        statusItem?.menu = menu
    }

    @objc private func approveGate(_ sender: NSMenuItem) {
        guard let sid = sender.representedObject as? String else { return }
        _ = bridge.approve(sessionID: sid)
        refreshMenuBar()
    }

    @objc private func denyGate(_ sender: NSMenuItem) {
        guard let sid = sender.representedObject as? String else { return }
        _ = bridge.deny(sessionID: sid)
        refreshMenuBar()
    }

    @objc private func copyStatus() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(store.statusSummary, forType: .string)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
