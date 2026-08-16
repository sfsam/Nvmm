//
//  Nvmm
//  PasteTrimmingTextField.swift
//

import AppKit

final class PasteTrimmingTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { PasteTrimmingTextFieldCell.self }
        set {}
    }
}

final class PasteTrimmingTextFieldCell: NSTextFieldCell {
    private let pasteTrimmingFieldEditor = PasteTrimmingFieldEditor()

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        pasteTrimmingFieldEditor
    }
}

final class PasteTrimmingFieldEditor: NSTextView {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer()
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        super.init(frame: .zero, textContainer: textContainer)
        isFieldEditor = true
    }

    required init?(coder: NSCoder) {
        pasteboard = .general
        super.init(coder: coder)
        isFieldEditor = true
    }

    override func paste(_ sender: Any?) {
        guard let string = pasteboard.string(forType: .string) else {
            super.paste(sender)
            return
        }
        insertText(
            string.trimmingCharacters(in: .whitespacesAndNewlines),
            replacementRange: selectedRange())
    }
}
