import AppKit
import SwiftUI

/// The Listen pane's text. While editing it's an ordinary text editor; while reading it can't be edited, shows the
/// sentence and word being spoken, follows them down the page, and a click on any word jumps there.
struct ReadingTextView: NSViewRepresentable {
    @Binding var text: String
    /// The text being read, or nil while editing.
    var readingText: String?
    var sentenceRange: NSRange?
    var wordRange: NSRange?
    var onClickLocation: (Int) -> Void

    static let font = NSFont.systemFont(ofSize: 18)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        // TextKit 1, for the layout manager's temporary attributes: highlights that never touch the text itself.
        let textView = ClickableTextView(usingTextLayoutManager: false)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 28, height: 24)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.defaultParagraphStyle = Self.paragraphStyle
        textView.typingAttributes = Self.attributes
        textView.delegate = context.coordinator
        textView.setAccessibilityIdentifier("ListenText")
        textView.onClick = { [weak coordinator = context.coordinator] location in
            coordinator?.parent.onClickLocation(location)
        }
        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }

        let shown = readingText ?? text
        if textView.string != shown {
            textView.textStorage?.setAttributedString(NSAttributedString(string: shown, attributes: Self.attributes))
            coordinator.lastWordRange = nil
            coordinator.lastSentenceRange = nil
        }
        let isReading = readingText != nil
        textView.isEditable = !isReading
        textView.isSelectable = !isReading
        textView.isReading = isReading
        if isReading, textView.window?.firstResponder === textView {
            textView.window?.makeFirstResponder(nil)
        }
        coordinator.highlight(sentence: isReading ? sentenceRange : nil, word: isReading ? wordRange : nil)
    }

    static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.35
        style.paragraphSpacing = 8
        return style
    }

    static var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraphStyle]
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ReadingTextView
        weak var textView: ClickableTextView?
        var lastSentenceRange: NSRange?
        var lastWordRange: NSRange?

        init(_ parent: ReadingTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView, parent.readingText == nil else { return }
            parent.text = textView.string
        }

        func highlight(sentence: NSRange?, word: NSRange?) {
            guard let textView, let layoutManager = textView.layoutManager else { return }
            guard sentence != lastSentenceRange || word != lastWordRange else { return }
            let length = (textView.string as NSString).length
            let clamp: (NSRange?) -> NSRange? = { range in
                guard let range, range.location != NSNotFound, NSMaxRange(range) <= length else { return nil }
                return range
            }
            if let old = clamp(lastSentenceRange) { layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: old) }
            if let old = clamp(lastWordRange) {
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: old)
                layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: old)
            }
            if let sentence = clamp(sentence) {
                layoutManager.addTemporaryAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.12), forCharacterRange: sentence)
            }
            if let word = clamp(word) {
                layoutManager.addTemporaryAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.38), forCharacterRange: word)
                if word != lastWordRange { follow(word) }
            }
            lastSentenceRange = sentence
            lastWordRange = word
        }

        /// Keeps the word being read in view: when it reaches the bottom fifth of the window (or is out of sight),
        /// scrolls so it sits a third of the way down.
        private func follow(_ range: NSRange) {
            guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer,
                  let clipView = textView.enclosingScrollView?.contentView
            else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.y += textView.textContainerOrigin.y
            let visible = clipView.documentVisibleRect
            let isAbove = rect.minY < visible.minY
            let isNearBottom = rect.maxY > visible.maxY - visible.height * 0.2
            guard isAbove || isNearBottom else { return }
            let maxY = max(textView.frame.height - visible.height, 0)
            let y = min(max(rect.minY - visible.height / 3, 0), maxY)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                clipView.animator().setBoundsOrigin(NSPoint(x: visible.minX, y: y))
            }
            textView.enclosingScrollView?.reflectScrolledClipView(clipView)
        }
    }
}

/// A text view that, while reading, turns a click into a jump to the word clicked instead of moving the cursor.
final class ClickableTextView: NSTextView {
    var isReading = false {
        didSet {
            if isReading != oldValue { window?.invalidateCursorRects(for: self) }
        }
    }
    var onClick: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard isReading else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard let layoutManager, let textContainer else { return }
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: containerPoint, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        // Clicks past the end of the last line don't count.
        let lineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        guard lineRect.insetBy(dx: -4, dy: -2).contains(containerPoint) else { return }
        onClick?(layoutManager.characterIndexForGlyph(at: glyph))
    }

    override func resetCursorRects() {
        if isReading {
            addCursorRect(visibleRect, cursor: .pointingHand)
        } else {
            super.resetCursorRects()
        }
    }
}
