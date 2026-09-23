import AppKit
import SwiftUI

// A client subprocess does not instantiate AppKit, claim the device, or write profiles.
if CommandLine.arguments.contains("--mcp") {
    MCPServer(handle: { try LocalBridge.request(operation: $0, arguments: $1) }).runStdio()
    exit(0)
}

@MainActor
final class StudioDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: StudioModel?
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var statusLine: NSMenuItem?
    private var pauseItem: NSMenuItem?
    private var profilesMenu: NSMenu?
    private var profileMenuSignature = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let identifier = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateAllWindows])
            NSApp.terminate(nil); return
        }
        do { model = try StudioModel() }
        catch {
            let alert = NSAlert(); alert.messageText = "Profiles could not be opened"
            alert.informativeText = error.localizedDescription + "\nYour files have not been replaced."
            alert.addButton(withTitle: "Quit")
            if (try? ProfileStore().loadBackup()) != nil { alert.addButton(withTitle: "Restore backup") }
            if alert.runModal() == .alertSecondButtonReturn {
                do { _ = try ProfileStore().restoreBackup(); model = try StudioModel() }
                catch { NSApp.presentError(error) }
            }
            guard model != nil else { NSApp.terminate(nil); return }
        }
        installMenu()
        model?.onStatusChange = { [weak self] in self?.updateStatus() }
        model?.start()
        showWindow()
    }
    private func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About KDCustom", action: #selector(about), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit KDCustom", action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = appMenu; main.addItem(appItem)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", Selector(("undo:")), "z"), ("Cut", #selector(NSText.cut(_:)), "x"),
                                     ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"),
                                     ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        editItem.submenu = edit; main.addItem(editItem); NSApp.mainMenu = main
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "circle.hexagongrid", accessibilityDescription: "KDCustom")
        let menu = NSMenu()
        statusLine = menu.addItem(withTitle: "KDCustom", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open KDCustom", action: #selector(showWindow), keyEquivalent: "").target = self
        pauseItem = menu.addItem(withTitle: "Pause", action: #selector(togglePause), keyEquivalent: ""); pauseItem?.target = self
        menu.addItem(withTitle: "Release all holds", action: #selector(releaseHolds), keyEquivalent: "").target = self
        let profiles = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Profile"); profiles.submenu = submenu; profilesMenu = submenu
        menu.addItem(profiles)
        menu.addItem(withTitle: "Reconnect device", action: #selector(reconnect), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "").target = self
        status.menu = menu; statusItem = status
    }
    private func updateStatus() {
        guard let model else { return }
        let title = "\(model.effectiveProfile.name) · \(model.outputStatus)"
        if statusLine?.title != title { statusLine?.title = title }
        let pauseTitle = model.paused ? "Resume controls" : "Pause controls"
        if pauseItem?.title != pauseTitle { pauseItem?.title = pauseTitle }
        let signature = model.document.profiles.map { $0.id + $0.name }.joined() + (model.lockedProfileID ?? "auto")
        if profileMenuSignature != signature, let menu = profilesMenu {
            profileMenuSignature = signature; menu.removeAllItems()
            let automatic = menu.addItem(withTitle: "Automatic · active app", action: #selector(selectProfile(_:)), keyEquivalent: "")
            automatic.target = self; automatic.state = model.lockedProfileID == nil ? .on : .off
            menu.addItem(.separator())
            for profile in model.document.profiles {
                let item = menu.addItem(withTitle: profile.name, action: #selector(selectProfile(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = profile.id
                item.state = model.lockedProfileID == profile.id ? .on : .off
            }
        }
    }
    @objc private func selectProfile(_ sender: NSMenuItem) { model?.lockedProfileID = sender.representedObject as? String }
    @objc private func releaseHolds() { model?.emergencyRelease() }
    @objc func showWindow() {
        guard let model else { return }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 790),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "KDCustom"; window.delegate = self
            window.minSize = NSSize(width: 1050, height: 710)
            window.contentView = NSHostingView(rootView: StudioRootView(model: model))
            window.appearance = nil
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("KDCustom.Main")
            window.center(); self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func togglePause() { model?.paused.toggle() }
    @objc private func reconnect() { model?.reconnect() }
    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "KDCustom", .credits: NSAttributedString(string: "Native control for Huion Keydial Remote K40\nIndependent project · ivg-design/KDCustom")])
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model?.stop() }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = StudioDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
