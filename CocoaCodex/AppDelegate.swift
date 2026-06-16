//
//  AppDelegate.swift
//  CocoaCodex
//
//  Created by zie on 2026/6/16.
//

import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    private let accessibilityService = AccessibilityService()
    private let locationReader = XcodeLocationReader()
    private let codexInserter = CodexChatInserter()
    private var hotKeyManager: GlobalHotKey?
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var shortcutRecorder: ShortcutRecorderWindowController?
    private var activationObserver: NSObjectProtocol?
    private var shortcut = KeyboardShortcut.load()
    private var statusMessage = "Ready. Focus Xcode and press Cmd+L."

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        NSLog("CocoaCodex did finish launching")
        NSApp.setActivationPolicy(.accessory)
        NSApp.windows.forEach { $0.close() }

        setupStatusItem()
        setupHotKey()
        observeActiveApplication()
        accessibilityService.requestPermissionIfNeeded()
        updateHotKeyRegistration()
        updateMenu()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        hotKeyManager?.unregister()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}

private extension AppDelegate {
    func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.isVisible = true
        if let button = item.button {
            let image = NSImage(systemSymbolName: "curlybraces", accessibilityDescription: "CocoaCodex")
                ?? NSImage(systemSymbolName: "curlybraces.square", accessibilityDescription: "CocoaCodex")
                ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "CocoaCodex")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
            button.toolTip = "CocoaCodex"
            button.target = self
            button.action = #selector(showStatusMenu)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        NSLog("CocoaCodex status item created: \(item)")
    }

    func setupHotKey() {
        hotKeyManager = GlobalHotKey { [weak self] in
            self?.copyXcodeLocationToClipboard()
        }
    }

    func observeActiveApplication() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateHotKeyRegistration()
            self?.updateMenu()
        }
    }

    func updateHotKeyRegistration() {
        guard isXcodeFrontmost else {
            hotKeyManager?.unregister()
            return
        }

        do {
            try hotKeyManager?.register(shortcut)
        } catch {
            statusMessage = "Shortcut failed: \(error.localizedDescription)"
        }
    }

    var isXcodeFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.isXcode == true
    }

    func updateMenu() {
        let menu = NSMenu()

        let axStatus = accessibilityService.isTrusted ? "Accessibility: Granted" : "Accessibility: Not Granted"
        let axItem = NSMenuItem(title: axStatus, action: nil, keyEquivalent: "")
        axItem.isEnabled = false
        menu.addItem(axItem)

        menu.addItem(NSMenuItem(
            title: "Shortcut: \(shortcut.displayString)",
            action: #selector(setShortcutFromMenu),
            keyEquivalent: ""
        ).targeting(self))

        menu.addItem(NSMenuItem(
            title: "Quit",
            action: #selector(quitFromMenu),
            keyEquivalent: "q"
        ).targeting(self))

        statusMenu = menu
    }

    func copyXcodeLocationToClipboard() {
        guard accessibilityService.isTrusted else {
            statusMessage = "Accessibility permission is required."
            accessibilityService.requestPermissionIfNeeded()
            updateMenu()
            NSSound.beep()
            return
        }

        do {
            let location = try locationReader.readFrontmostXcodeLocation()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(location.markdown, forType: .string)
            do {
                try codexInserter.pasteIntoCurrentChat(location.markdown)
                statusMessage = "Inserted \(location.fileName) line \(location.lineDescription) into Codex."
            } catch {
                statusMessage = "Copied, Codex insert failed: \(error.localizedDescription)"
                NSSound.beep()
            }
        } catch {
            statusMessage = error.localizedDescription
            NSSound.beep()
        }

        updateMenu()
    }

    @objc func copyNowFromMenu() {
        copyXcodeLocationToClipboard()
    }

    @objc func pasteClipboardIntoCodexFromMenu() {
        guard accessibilityService.isTrusted else {
            statusMessage = "Accessibility permission is required."
            accessibilityService.requestPermissionIfNeeded()
            updateMenu()
            NSSound.beep()
            return
        }

        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            statusMessage = "Clipboard has no text to paste."
            updateMenu()
            NSSound.beep()
            return
        }

        do {
            try codexInserter.pasteIntoCurrentChat(text)
            statusMessage = "Inserted clipboard text into Codex."
        } catch {
            statusMessage = error.localizedDescription
            NSSound.beep()
        }

        updateMenu()
    }

    @objc func setShortcutFromMenu() {
        let controller = ShortcutRecorderWindowController(currentShortcut: shortcut) { [weak self] newShortcut in
            guard let self else { return }
            shortcut = newShortcut
            shortcut.save()
            statusMessage = "Shortcut set to \(newShortcut.displayString)."
            updateHotKeyRegistration()
            updateMenu()
        }
        shortcutRecorder = controller
        controller.showWindow(nil)
    }

    @objc func resetShortcutFromMenu() {
        shortcut = .default
        shortcut.save()
        statusMessage = "Shortcut reset to Cmd+L."
        updateHotKeyRegistration()
        updateMenu()
    }

    @objc func requestAccessibilityFromMenu() {
        accessibilityService.requestPermissionIfNeeded()
        updateMenu()
    }

    @objc func openAccessibilitySettingsFromMenu() {
        accessibilityService.openSettings()
    }

    @objc func quitFromMenu() {
        NSApp.terminate(nil)
    }

    @objc func showStatusMenu() {
        guard let statusItem, let statusMenu else { return }
        statusItem.popUpMenu(statusMenu)
    }
}

private extension NSMenuItem {
    func targeting(_ target: AnyObject) -> NSMenuItem {
        self.target = target
        return self
    }
}
