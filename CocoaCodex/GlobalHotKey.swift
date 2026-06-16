import Carbon
import Cocoa

enum GlobalHotKeyError: LocalizedError {
    case registrationFailed(OSStatus)
    case handlerInstallFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .registrationFailed(status):
            return "Unable to register shortcut (OSStatus \(status))."
        case let .handlerInstallFailed(status):
            return "Unable to install shortcut handler (OSStatus \(status))."
        }
    }
}

final class GlobalHotKey {
    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var currentShortcut: KeyboardShortcut?
    private let hotKeyID = EventHotKeyID(signature: 0x43435843, id: 1)

    init(action: @escaping () -> Void) {
        self.action = action
    }

    deinit {
        unregister()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    func register(_ shortcut: KeyboardShortcut) throws {
        if currentShortcut == shortcut, hotKeyRef != nil {
            return
        }

        unregister()
        try installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else {
            throw GlobalHotKeyError.registrationFailed(status)
        }

        hotKeyRef = ref
        currentShortcut = shortcut
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        currentShortcut = nil
    }

    private func installHandlerIfNeeded() throws {
        guard eventHandlerRef == nil else { return }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        guard status == noErr else {
            throw GlobalHotKeyError.handlerInstallFailed(status)
        }
    }

    func handlePressed(id: UInt32) {
        guard id == hotKeyID.id else { return }
        action()
    }
}

private let hotKeyEventHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return noErr }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )

    guard status == noErr else { return status }

    let manager = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in
        manager.handlePressed(id: hotKeyID.id)
    }

    return noErr
}
