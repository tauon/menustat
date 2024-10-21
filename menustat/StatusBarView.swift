import Cocoa

class StatusBarView: NSView {
    var statusText: String = "" {
        didSet {
            textField.stringValue = statusText
            updateFrameSize()
        }
    }
    let font = NSFont(name: "Menlo", size: 8)!
    private let textField: NSTextField
    private var previousWidth: CGFloat = 0

    override init(frame frameRect: NSRect) {
        textField = NSTextField(frame: frameRect)
        super.init(frame: frameRect)
        setupTextField()
    }

    required init?(coder: NSCoder) {
        textField = NSTextField()
        super.init(coder: coder)
        setupTextField()
    }

    private func setupTextField() {
        textField.isEditable = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.font = font
        textField.alignment = .center
        textField.lineBreakMode = .byWordWrapping
        textField.usesSingleLineMode = false
        textField.maximumNumberOfLines = 2
        textField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)

        // Constraints to fill the parent view
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            textField.topAnchor.constraint(equalTo: self.topAnchor),
            textField.bottomAnchor.constraint(equalTo: self.bottomAnchor)
        ])

        // Set initial frame size
        self.setFrameSize(NSSize(width: 70, height: NSStatusBar.system.thickness))
    }

    // Handle mouse click to show the window
    override func mouseDown(with event: NSEvent) {
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            appDelegate.showWindow()
        }
    }

    // Function to update frame size
    func updateFrameSize() {
        let textSize = textField.attributedStringValue.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: NSStatusBar.system.thickness),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).size

        let newWidth = ceil(textSize.width) + 10 // Add some padding

        // Only update if width has changed significantly
        if abs(newWidth - previousWidth) > 1.0 {
            previousWidth = newWidth
            self.setFrameSize(NSSize(width: newWidth, height: NSStatusBar.system.thickness))
        }
    }
}
