import ApplicationServices
import Cocoa

struct XcodeLocation {
    let fileURL: URL
    let startLine: Int
    let endLine: Int

    var fileName: String {
        fileURL.lastPathComponent
    }

    var lineDescription: String {
        startLine == endLine ? "\(startLine)" : "\(startLine)-\(endLine)"
    }

    var markdown: String {
        "[\(fileName) (line \(lineDescription))](\(fileURL.path):\(lineDescription))"
    }
}

enum XcodeLocationError: LocalizedError {
    case xcodeNotFrontmost
    case noXcodeWindow
    case noDocumentURL
    case noSourceEditor
    case noEditorContent
    case noSelectionRange

    var errorDescription: String? {
        switch self {
        case .xcodeNotFrontmost:
            return "Xcode is not the frontmost app."
        case .noXcodeWindow:
            return "Could not find Xcode's active window."
        case .noDocumentURL:
            return "Could not read Xcode's current file path."
        case .noSourceEditor:
            return "Focus the Xcode source editor first."
        case .noEditorContent:
            return "Could not read the Xcode editor content."
        case .noSelectionRange:
            return "Could not read the Xcode selection range."
        }
    }
}

final class XcodeLocationReader {
    func readFrontmostXcodeLocation() throws -> XcodeLocation {
        guard let app = NSWorkspace.shared.frontmostApplication, app.isXcode else {
            throw XcodeLocationError.xcodeNotFrontmost
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let focusedWindow: AXUIElement? = copyAttribute(kAXFocusedWindowAttribute, from: appElement)
            ?? copyAttribute(kAXMainWindowAttribute, from: appElement)

        guard let window = focusedWindow else {
            throw XcodeLocationError.noXcodeWindow
        }

        let focusedElement: AXUIElement? = copyAttribute(kAXFocusedUIElementAttribute, from: appElement)
        guard let sourceEditor = findSourceEditor(from: focusedElement, in: window) else {
            throw XcodeLocationError.noSourceEditor
        }

        guard let fileURL = documentURL(from: sourceEditor, focusedWindow: window) else {
            throw XcodeLocationError.noDocumentURL
        }

        guard let content: String = copyAttribute(kAXValueAttribute, from: sourceEditor) else {
            throw XcodeLocationError.noEditorContent
        }

        guard let selectedRange = selectedTextRange(from: sourceEditor) else {
            throw XcodeLocationError.noSelectionRange
        }

        let lineRange = lineRange(in: content, selectedRange: selectedRange)
        return XcodeLocation(fileURL: fileURL, startLine: lineRange.start, endLine: lineRange.end)
    }
}

private extension XcodeLocationReader {
    func documentURL(from sourceEditor: AXUIElement, focusedWindow: AXUIElement) -> URL? {
        let editorWindow: AXUIElement? = copyAttribute(kAXWindowAttribute, from: sourceEditor)
        let candidates = [focusedWindow, editorWindow].compactMap { $0 }

        for candidate in candidates {
            if let document: String = copyAttribute(kAXDocumentAttribute, from: candidate),
               let url = parseDocumentURL(document) {
                return adjustedFileURL(url)
            }
        }

        return nil
    }

    func parseDocumentURL(_ rawDocument: String) -> URL? {
        if let url = URL(string: rawDocument), url.isFileURL {
            return url.standardizedFileURL
        }

        let decoded = rawDocument.removingPercentEncoding ?? rawDocument
        if decoded.hasPrefix("file://") {
            let path = String(decoded.dropFirst("file://".count))
            return URL(fileURLWithPath: path).standardizedFileURL
        }

        guard decoded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: decoded).standardizedFileURL
    }

    func adjustedFileURL(_ url: URL) -> URL {
        if url.pathExtension == "playground",
           FileManager.default.fileExists(atPath: url.path) {
            return url.appendingPathComponent("Contents.swift")
        }
        return url
    }

    func selectedTextRange(from sourceEditor: AXUIElement) -> CFRange? {
        guard let value: AXValue = copyAttribute(kAXSelectedTextRangeAttribute, from: sourceEditor) else {
            return nil
        }

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(value, .cfRange, &range) else {
            return nil
        }
        return range
    }

    func lineNumber(in content: String, utf16Offset: Int) -> Int {
        let clampedOffset = max(0, min(utf16Offset, content.utf16.count))
        var line = 1
        for codeUnit in content.utf16.prefix(clampedOffset) where codeUnit == 10 {
            line += 1
        }
        return line
    }

    func lineRange(in content: String, selectedRange: CFRange) -> (start: Int, end: Int) {
        let startOffset = max(0, selectedRange.location)
        let rawEndOffset = startOffset + max(0, selectedRange.length)
        let endOffset = selectedRange.length == 0 ? startOffset : rawEndOffset - 1
        let startLine = lineNumber(in: content, utf16Offset: startOffset)
        let endLine = lineNumber(in: content, utf16Offset: endOffset)
        return (startLine, max(startLine, endLine))
    }

    func findSourceEditor(from focusedElement: AXUIElement?, in window: AXUIElement) -> AXUIElement? {
        if let focusedElement, let editor = nearestSourceEditor(startingAt: focusedElement) {
            return editor
        }
        return firstSourceEditor(in: window)
    }

    func nearestSourceEditor(startingAt element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        while let element = current {
            if isNonNavigatorSourceEditor(element) {
                return element
            }
            current = parent(of: element)
        }
        return nil
    }

    func firstSourceEditor(in element: AXUIElement) -> AXUIElement? {
        var visitedCount = 0
        return firstSourceEditor(in: element, visitedCount: &visitedCount)
    }

    func firstSourceEditor(in element: AXUIElement, visitedCount: inout Int) -> AXUIElement? {
        visitedCount += 1
        guard visitedCount < 2_000 else { return nil }

        let description = description(of: element)
        if description == "navigator" || description == "Debug Area" {
            return nil
        }

        if isNonNavigatorSourceEditor(element) {
            return element
        }

        for child in children(of: element) {
            if let editor = firstSourceEditor(in: child, visitedCount: &visitedCount) {
                return editor
            }
        }

        return nil
    }

    func isNonNavigatorSourceEditor(_ element: AXUIElement) -> Bool {
        description(of: element) == "Source Editor" && !isDescendantOfNavigator(element)
    }

    func isDescendantOfNavigator(_ element: AXUIElement) -> Bool {
        var current = parent(of: element)
        while let element = current {
            if description(of: element) == "navigator" {
                return true
            }
            current = parent(of: element)
        }
        return false
    }

    func description(of element: AXUIElement) -> String {
        (copyAttribute(kAXDescriptionAttribute, from: element) as String?) ?? ""
    }

    func parent(of element: AXUIElement) -> AXUIElement? {
        copyAttribute(kAXParentAttribute, from: element)
    }

    func children(of element: AXUIElement) -> [AXUIElement] {
        (copyAttribute(kAXChildrenAttribute, from: element) as [AXUIElement]?) ?? []
    }

    func copyAttribute<T>(_ attribute: String, from element: AXUIElement, as type: T.Type = T.self) -> T? {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value as? T
    }
}

extension NSRunningApplication {
    var isXcode: Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == "com.apple.dt.Xcode" || bundleIdentifier.hasPrefix("com.apple.dt.Xcode.")
    }
}
