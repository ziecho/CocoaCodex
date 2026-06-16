import ApplicationServices
import Carbon.HIToolbox
import Cocoa

enum CodexChatInsertError: LocalizedError {
    case codexNotRunning
    case noCodexWindow
    case noChatInput
    case pasteFailed

    var errorDescription: String? {
        switch self {
        case .codexNotRunning:
            return "Codex is not running."
        case .noCodexWindow:
            return "Could not find Codex's current chat window."
        case .noChatInput:
            return "Could not find Codex's chat input."
        case .pasteFailed:
            return "Could not paste into Codex."
        }
    }
}

final class CodexChatInserter {
    func pasteIntoCurrentChat(_ text: String) throws {
        guard let app = runningCodexApp else {
            throw CodexChatInsertError.codexNotRunning
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, true as CFTypeRef)

        guard let window = focusedWindow(in: appElement) else {
            throw CodexChatInsertError.noCodexWindow
        }

        guard let input = chatInput(in: window, appElement: appElement) else {
            throw CodexChatInsertError.noChatInput
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        app.activate()
        focus(input)
        click(input)

        guard postPasteShortcut() else {
            throw CodexChatInsertError.pasteFailed
        }
    }
}

private extension CodexChatInserter {
    struct Candidate {
        let element: AXUIElement
        let score: Int
    }

    var runningCodexApp: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { app in
            if app.localizedName == "Codex" { return true }
            guard let bundleIdentifier = app.bundleIdentifier?.lowercased() else { return false }
            return bundleIdentifier.contains("codex")
        }
    }

    func focusedWindow(in appElement: AXUIElement) -> AXUIElement? {
        let focused: AXUIElement? = copyAttribute(kAXFocusedWindowAttribute, from: appElement)
        let main: AXUIElement? = copyAttribute(kAXMainWindowAttribute, from: appElement)
        if let focused { return focused }
        if let main { return main }

        let windows: [AXUIElement] = copyAttribute(kAXWindowsAttribute, from: appElement) ?? []
        return windows.first
    }

    func chatInput(in window: AXUIElement, appElement: AXUIElement) -> AXUIElement? {
        if let focused: AXUIElement = copyAttribute(kAXFocusedUIElementAttribute, from: appElement),
           isChatInput(focused, window: window) {
            return focused
        }

        if let probed = probeChatInput(in: window, appElement: appElement) {
            return probed
        }

        let windowFrame = frame(of: window)
        var visited = Set<UInt64>()
        var candidates = [Candidate]()
        collectChatInputs(in: window, windowFrame: windowFrame, visited: &visited, candidates: &candidates)
        return candidates.max { $0.score < $1.score }?.element
    }

    func probeChatInput(in window: AXUIElement, appElement: AXUIElement) -> AXUIElement? {
        guard let windowFrame = frame(of: window) else { return nil }

        let xValues = [
            windowFrame.midX,
            windowFrame.minX + windowFrame.width * 0.45,
            windowFrame.minX + windowFrame.width * 0.65,
        ]
        let yValues = [
            windowFrame.maxY - 90,
            windowFrame.maxY - 130,
            windowFrame.maxY - 180,
        ]

        for y in yValues {
            for x in xValues {
                var elementRef: AXUIElement?
                let result = AXUIElementCopyElementAtPosition(appElement, Float(x), Float(y), &elementRef)
                guard result == .success, let element = elementRef else { continue }

                if let input = nearestChatInput(startingAt: element, window: window) {
                    return input
                }

                var visited = Set<UInt64>()
                if let input = firstChatInput(in: element, window: window, visited: &visited) {
                    return input
                }
            }
        }

        return nil
    }

    func nearestChatInput(startingAt element: AXUIElement, window: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        while let element = current {
            if isChatInput(element, window: window) {
                return element
            }
            current = copyAttribute(kAXParentAttribute, from: element)
        }
        return nil
    }

    func firstChatInput(
        in element: AXUIElement,
        window: AXUIElement,
        visited: inout Set<UInt64>,
        depth: Int = 0
    ) -> AXUIElement? {
        guard depth < 8 else { return nil }

        let hash = UInt64(CFHash(element))
        guard !visited.contains(hash) else { return nil }
        visited.insert(hash)

        if isChatInput(element, window: window) {
            return element
        }

        for child in children(of: element) {
            if let input = firstChatInput(in: child, window: window, visited: &visited, depth: depth + 1) {
                return input
            }
        }

        return nil
    }

    func collectChatInputs(
        in element: AXUIElement,
        windowFrame: CGRect?,
        visited: inout Set<UInt64>,
        candidates: inout [Candidate],
        depth: Int = 0
    ) {
        guard depth < 80 else { return }

        let hash = UInt64(CFHash(element))
        guard !visited.contains(hash) else { return }
        visited.insert(hash)

        if isChatInput(element, window: nil) {
            candidates.append(Candidate(element: element, score: score(element, windowFrame: windowFrame)))
        }

        for child in children(of: element) {
            collectChatInputs(
                in: child,
                windowFrame: windowFrame,
                visited: &visited,
                candidates: &candidates,
                depth: depth + 1
            )
        }
    }

    func isChatInput(_ element: AXUIElement, window: AXUIElement?) -> Bool {
        let role = stringAttribute(kAXRoleAttribute, from: element)
        guard role == kAXTextAreaRole as String || role == kAXTextFieldRole as String else {
            return false
        }

        let searchableText = [
            stringAttribute(kAXTitleAttribute, from: element),
            stringAttribute(kAXDescriptionAttribute, from: element),
            stringAttribute(kAXPlaceholderValueAttribute, from: element),
            stringAttribute(kAXValueAttribute, from: element),
            domClassList(of: element),
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()

        let excludedHints = [
            "筛选文件",
            "搜索",
            "filter",
            "search",
            "workspace-directory-tree-search",
        ]

        if excludedHints.contains(where: searchableText.contains) {
            return false
        }

        if role == kAXTextAreaRole as String {
            return true
        }

        guard let frame = frame(of: element), frame.width > 300 else {
            return false
        }

        if let windowFrame = window.flatMap(frame(of:)) {
            return frame.midY > windowFrame.midY && frame.minX > windowFrame.minX + 250
        }

        return true
    }

    func score(_ element: AXUIElement, windowFrame: CGRect?) -> Int {
        let role = stringAttribute(kAXRoleAttribute, from: element)
        var score = role == kAXTextAreaRole as String ? 1_000 : 200

        if boolAttribute(kAXFocusedAttribute, from: element) {
            score += 200
        }

        guard let frame = frame(of: element) else {
            return score
        }

        if frame.width > 400 { score += 150 }
        if frame.height >= 20 { score += 50 }

        if let windowFrame {
            if frame.midY > windowFrame.midY { score += 300 }
            if frame.minX > windowFrame.minX + 250 { score += 150 }
            if frame.maxY > windowFrame.maxY - 260 { score += 150 }
        }

        return score
    }

    func focus(_ element: AXUIElement) {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, true as CFTypeRef)
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }

    func click(_ element: AXUIElement) {
        guard let frame = frame(of: element) else { return }

        let point = CGPoint(x: frame.midX, y: frame.midY)
        let source = CGEventSource(stateID: .hidSystemState)
        let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)

        move?.post(tap: .cghidEventTap)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    func postPasteShortcut() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    func children(of element: AXUIElement) -> [AXUIElement] {
        for attribute in [kAXChildrenAttribute as String, "AXVisibleChildren", "AXContents"] {
            let children: [AXUIElement]? = copyAttribute(attribute, from: element)
            if let children, !children.isEmpty {
                return children
            }
        }
        return []
    }

    func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = copyAttribute(kAXPositionAttribute, from: element),
              let sizeValue: AXValue = copyAttribute(kAXSizeAttribute, from: element)
        else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size)
        else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    func domClassList(of element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, "AXDOMClassList" as CFString, &value) == .success else {
            return nil
        }
        if let string = value as? String { return string }
        if let strings = value as? [String] { return strings.joined(separator: " ") }
        return nil
    }

    func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        copyAttribute(attribute, from: element)
    }

    func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool {
        (copyAttribute(attribute, from: element) as Bool?) ?? false
    }

    func copyAttribute<T>(_ attribute: String, from element: AXUIElement, as type: T.Type = T.self) -> T? {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value as? T
    }
}
