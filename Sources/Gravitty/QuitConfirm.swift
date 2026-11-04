import AppKit

// Quit confirmation drawn inside the panel (a normal alert opens underneath the always-on-top panel).
// Covers the terminal area; the panel's key handler swallows every key while it is up (Return quits, Esc cancels).
final class QuitConfirm: NSView {
    var onQuit: (() -> Void)?
    var onCancel: (() -> Void)?
    private let message = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.9).cgColor
        isHidden = true
        let title = NSTextField(labelWithString: "Quit Gravitty?")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.textColor = .white
        message.textColor = NSColor.white.withAlphaComponent(0.75)
        message.alignment = .center
        message.preferredMaxLayoutWidth = 380
        let cancel = NSButton(title: "Cancel   esc", target: self, action: #selector(cancel))
        let quit = NSButton(title: "Quit   ↩", target: self, action: #selector(quit))
        quit.bezelColor = .systemRed
        quit.keyEquivalent = "\r"          // Return
        cancel.keyEquivalent = "\u{1b}"    // Esc
        let buttons = NSStackView(views: [cancel, quit])
        buttons.spacing = 12
        let stack = NSStackView(views: [title, message, buttons])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String) {
        message.stringValue = text
        isHidden = false
        window?.makeFirstResponder(self) // take the keyboard from the terminal
    }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) { // the buttons' key equivalents cover Return and Esc; this just keeps other keys out of the terminal
        switch e.keyCode { case 36, 76: quit(); case 53: cancel(); default: break }
    }
    override func mouseDown(with e: NSEvent) {} // clicks never reach the terminal behind
    @objc func quit() { isHidden = true; onQuit?() }
    @objc func cancel() { isHidden = true; onCancel?() }
}
