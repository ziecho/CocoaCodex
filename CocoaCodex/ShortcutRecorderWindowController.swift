import Cocoa

final class ShortcutRecorderWindowController: NSWindowController {
    private let captureView: ShortcutCaptureView

    init(currentShortcut: KeyboardShortcut, onShortcut: @escaping (KeyboardShortcut) -> Void) {
        captureView = ShortcutCaptureView(currentShortcut: currentShortcut)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 132),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Shortcut"
        panel.isReleasedWhenClosed = false
        panel.center()

        super.init(window: panel)

        captureView.onShortcut = { shortcut in
            onShortcut(shortcut)
        }

        panel.contentView = makeContentView(currentShortcut: currentShortcut)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeContentView(currentShortcut: KeyboardShortcut) -> NSView {
        let container = NSStackView()
        container.orientation = .horizontal
        container.alignment = .centerY
        container.distribution = .fill
        container.spacing = 22
        container.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4

        let title = NSTextField(labelWithString: "Insert Xcode Selection into Codex")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail

        let detail = NSTextField(labelWithString: "Focus the field, then press a shortcut.")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail

        textStack.addArrangedSubview(title)
        textStack.addArrangedSubview(detail)
        container.addArrangedSubview(textStack)
        container.addArrangedSubview(captureView)
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        captureView.setContentHuggingPriority(.required, for: .horizontal)
        return container
    }
}

final class ShortcutCaptureView: NSView {
    var onShortcut: ((KeyboardShortcut) -> Void)?
    private var text: String
    private var isFocused = false

    init(currentShortcut: KeyboardShortcut) {
        text = currentShortcut.displayString
        super.init(frame: NSRect(x: 0, y: 0, width: 180, height: 36))
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 180, height: 36)
    }

    override func becomeFirstResponder() -> Bool {
        isFocused = true
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isFocused = false
        needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            window?.close()
            return
        }

        guard let shortcut = KeyboardShortcut.from(event: event) else {
            text = "Use Cmd, Ctrl, or Opt"
            needsDisplay = true
            NSSound.beep()
            return
        }

        text = shortcut.displayString
        needsDisplay = true
        onShortcut?(shortcut)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSColor.textBackgroundColor.setFill()
        path.fill()

        let strokeColor = isFocused ? NSColor.controlAccentColor : NSColor.separatorColor
        strokeColor.setStroke()
        path.lineWidth = isFocused ? 2 : 1
        path.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let size = attributed.size()
        attributed.draw(at: NSPoint(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2
        ))
    }
}
