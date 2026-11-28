//
//  ComposerTextEditor.swift
//  nodeloc
//
//  The one text editor every composer uses: the topic composer, the reply
//  composer in the reader, and the chat input.
//
//  Why UIKit. Two things the composers need are out of reach of SwiftUI's
//  `TextEditor`: a site emoji shown in the text as its image (a text
//  attachment), and an emoji panel that takes the keyboard's place without
//  the field losing focus (the text view's `inputView`). Both are ordinary
//  `UITextView` features, so the editor is one, wrapped.
//
//  The draft is still an `AttributedString`, so the composers keep their
//  formatting, mention and markdown code. A site emoji in it is one U+FFFC
//  character carrying `ComposerEmojiAttribute` (its code); everything that
//  leaves the editor — sending, drafts, copying — goes through
//  `ComposerEmojiCodec.flatten`, which turns those back into `:code:`, so what
//  the server and drafts see is exactly what the old picker produced.
//

import SwiftUI
import UIKit

// MARK: - The emoji attribute

/// A site emoji's code, on the single U+FFFC character that shows it.
enum ComposerEmojiAttribute: CodableAttributedStringKey {
    typealias Value = String
    static let name = "nodeloc.emoji"
}

// MARK: - Codec

/// Converts between the editor's form (emoji as attachments) and the
/// `:code:` text that is sent and stored.
@MainActor
enum ComposerEmojiCodec {
    static let objectReplacement: Character = "\u{FFFC}"

    /// Emoji runs become `:code:` text; everything else is left as it was.
    static func flatten(_ text: AttributedString) -> AttributedString {
        guard text.runs.contains(where: { $0[ComposerEmojiAttribute.self] != nil }) else { return text }
        var result = AttributedString()
        for run in text.runs {
            if let code = run[ComposerEmojiAttribute.self] {
                var piece = AttributedString(":\(code):")
                var attributes = run.attributes
                attributes[ComposerEmojiAttribute.self] = nil
                piece.setAttributes(attributes)
                result += piece
            } else {
                result += text[run.range]
            }
        }
        return result
    }

    /// The flattened text as a plain string.
    static func plain(_ text: AttributedString) -> String {
        String(flatten(text).characters)
    }

    /// Known `:code:` tokens become emoji; unknown ones stay as typed. For a
    /// draft or a post loaded into an editor.
    static func inflate(_ text: AttributedString) -> AttributedString {
        let plain = String(text.characters)
        guard plain.contains(":") else { return text }
        var result = text
        // Back to front, so earlier offsets stay valid as later ones shrink.
        let matches = plain.matches(of: /:([a-z0-9_+\-]{1,40}):/).reversed()
        for match in matches {
            let code = String(match.output.1)
            guard EmojiCatalog.shared.emoji(named: code)?.url != nil else { continue }
            let lower = plain.distance(from: plain.startIndex, to: match.range.lowerBound)
            let length = plain.distance(from: match.range.lowerBound, to: match.range.upperBound)
            let start = result.index(result.startIndex, offsetByCharacters: lower)
            let end = result.index(start, offsetByCharacters: length)
            var emoji = AttributedString(String(objectReplacement))
            var attributes = result[start..<end].runs.first?.attributes ?? AttributeContainer()
            attributes[ComposerEmojiAttribute.self] = code
            emoji.setAttributes(attributes)
            result.replaceSubrange(start..<end, with: emoji)
        }
        return result
    }

    static func inflate(_ plain: String) -> AttributedString {
        inflate(AttributedString(plain))
    }
}

// MARK: - Style

/// How the draft's attributes are drawn. Each composer stores formatting its
/// own way; this is the one place that knows how each looks.
struct ComposerEditorStyle: Equatable {
    var fontSize: CGFloat = 16
    var monospaced = false
    /// Bold/italic/strike from the reply composer's bitmask attribute.
    var readsEmphasisMask = false
    /// Bold/italic/strike/code and links from Foundation's presentation intent
    /// (the topic composer).
    var readsPresentationIntent = false
    var placeholder: String = ""

    static func reply() -> ComposerEditorStyle {
        ComposerEditorStyle(fontSize: 15, readsEmphasisMask: true)
    }
    static func compose(source: Bool) -> ComposerEditorStyle {
        ComposerEditorStyle(fontSize: source ? 15 : 16, monospaced: source, readsPresentationIntent: !source)
    }
    static func chat() -> ComposerEditorStyle {
        ComposerEditorStyle(fontSize: 16)
    }

    var font: UIFont {
        monospaced
            ? .monospacedSystemFont(ofSize: Theme.scaledSize(fontSize), weight: .regular)
            : Theme.uiBody(fontSize)
    }
}

// MARK: - Proxy

/// What a composer can ask of the editor beyond its bindings: the styling the
/// next typed character gets, which only the text view knows.
@MainActor
@Observable
final class ComposerEditorProxy {
    /// The reply composer's emphasis bitmask for the caret or selection.
    private(set) var activeEmphasis = 0
    @ObservationIgnored fileprivate weak var coordinator: ComposerTextEditor.Coordinator?

    fileprivate func publish(emphasis: Int) {
        if activeEmphasis != emphasis { activeEmphasis = emphasis }
    }

    /// Sets the emphasis the next typed characters get (empty selection).
    func setTypingEmphasis(_ mask: Int) {
        coordinator?.setTypingEmphasis(mask)
        publish(emphasis: mask)
    }

    /// Inserts a pick at the caret, as the panel does.
    func insert(_ pick: ComposerEmojiPick) {
        coordinator?.insert(pick)
    }
}

// MARK: - Keyboard height

/// The last system keyboard height seen, so the emoji panel takes exactly the
/// keyboard's place and nothing above it moves when switching.
@MainActor
final class KeyboardHeightTracker {
    static let shared = KeyboardHeightTracker()
    private(set) var height: CGFloat = 336
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            MainActor.assumeIsolated {
                // Only a real keyboard (not the panel itself, not a hardware
                // keyboard's bar) sets the height.
                if frame.height > 200, !KeyboardHeightTracker.shared.panelShowing {
                    KeyboardHeightTracker.shared.height = frame.height
                }
            }
        }
    }

    var panelShowing = false
}

// MARK: - Editor

struct ComposerTextEditor: UIViewRepresentable {
    @Binding var text: AttributedString
    /// Character offsets into `text`, as `AttributedString.CharacterView` counts.
    @Binding var selection: Range<Int>
    @Binding var isFocused: Bool
    @Binding var showsEmojiPanel: Bool
    var style: ComposerEditorStyle = ComposerEditorStyle()
    var isEditable = true
    var proxy: ComposerEditorProxy?
    /// The reply bar grows with its text; told the height the text needs.
    var onContentHeight: ((CGFloat) -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> ComposerUITextView {
        KeyboardHeightTracker.shared.start()
        let view = ComposerUITextView()
        view.delegate = context.coordinator
        view.coordinator = context.coordinator
        view.backgroundColor = .clear
        view.allowsEditingTextAttributes = false
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.textContainer.lineFragmentPadding = 5
        view.keyboardDismissMode = .interactive
        view.isScrollEnabled = true
        context.coordinator.textView = view
        context.coordinator.lastDark = colorScheme == .dark
        context.coordinator.lastStyle = style
        proxy?.coordinator = context.coordinator
        context.coordinator.apply(text: text, selection: selection, force: true)
        return view
    }

    func updateUIView(_ view: ComposerUITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        proxy?.coordinator = coordinator
        view.isEditable = isEditable
        view.tintColor = UIColor(Theme.accent)
        let styleChanged = coordinator.lastStyle != style || coordinator.lastDark != (colorScheme == .dark)
        coordinator.lastStyle = style
        coordinator.lastDark = colorScheme == .dark
        coordinator.apply(text: text, selection: selection, force: styleChanged)

        // Panel in or out — in place of the keyboard, focus kept.
        let wantsPanel = showsEmojiPanel && isFocused
        if wantsPanel != (view.inputView != nil) {
            view.inputView = wantsPanel ? coordinator.panelView() : nil
            KeyboardHeightTracker.shared.panelShowing = wantsPanel
            if view.isFirstResponder { view.reloadInputViews() }
        }
        if isFocused, !view.isFirstResponder, view.window != nil {
            DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        } else if !isFocused, view.isFirstResponder {
            DispatchQueue.main.async { _ = view.resignFirstResponder() }
        }
    }

    static func dismantleUIView(_ view: ComposerUITextView, coordinator: Coordinator) {
        KeyboardHeightTracker.shared.panelShowing = false
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextEditor
        weak var textView: ComposerUITextView?
        var lastStyle: ComposerEditorStyle?
        var lastDark = false
        /// The draft as last read from or written to the text view, so a
        /// binding update that is only our own echo doesn't rebuild it.
        private var lastText = AttributedString()
        private var lastSelection = 0..<0
        private var isApplying = false
        private var panelHost: UIViewController?
        private let haptic = UIImpactFeedbackGenerator(style: .light)

        init(parent: ComposerTextEditor) { self.parent = parent }

        // MARK: Model → view

        func apply(text: AttributedString, selection: Range<Int>, force: Bool) {
            guard let textView else { return }
            if force || text != lastText {
                isApplying = true
                textView.attributedText = ComposerAttributedBridge.uiText(
                    from: text,
                    style: parent.style,
                    dark: lastDark,
                    onImage: { [weak self] in self?.emojiImageArrived() }
                )
                lastText = text
                isApplying = false
                setSelection(selection, in: textView)
                lastSelection = selection
                refreshTypingAttributes()
                reportHeight()
            } else if selection != lastSelection {
                setSelection(selection, in: textView)
                lastSelection = selection
                refreshTypingAttributes()
            }
        }

        private func setSelection(_ selection: Range<Int>, in textView: UITextView) {
            let string = textView.text ?? ""
            let range = ComposerAttributedBridge.nsRange(characterRange: selection, in: string)
            if textView.selectedRange != range {
                isApplying = true
                textView.selectedRange = range
                isApplying = false
            }
        }

        // MARK: View → model

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplying else { return }
            pushText()
            reportHeight()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplying else { return }
            pushSelection()
            refreshTypingAttributes()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
            if parent.showsEmojiPanel { parent.showsEmojiPanel = false }
        }

        private func pushText() {
            guard let textView else { return }
            let model = ComposerAttributedBridge.model(from: textView.attributedText, style: parent.style)
            lastText = model
            parent.text = model
            pushSelection()
        }

        private func pushSelection() {
            guard let textView else { return }
            let range = ComposerAttributedBridge.characterRange(
                nsRange: textView.selectedRange,
                in: textView.text ?? ""
            )
            lastSelection = range
            if parent.selection != range { parent.selection = range }
        }

        private func reportHeight() {
            guard let textView, let onContentHeight = parent.onContentHeight else { return }
            let width = textView.bounds.width > 0 ? textView.bounds.width : UIScreen.main.bounds.width - 24
            let size = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            DispatchQueue.main.async { onContentHeight(size.height) }
        }

        // MARK: Typing attributes

        /// Typing carries the formatting of the text before the caret, but
        /// never an emoji: the next character after one is plain text.
        func refreshTypingAttributes() {
            guard let textView else { return }
            var attributes = textView.typingAttributes
            attributes[.attachment] = nil
            attributes[ComposerAttributedBridge.emojiKey] = nil
            attributes[.font] = attributes[.font] ?? parent.style.font
            textView.typingAttributes = ComposerAttributedBridge.displayAttributes(
                storage: attributes,
                style: parent.style,
                dark: lastDark
            )
            if parent.style.readsEmphasisMask {
                parent.proxy?.publish(emphasis: activeEmphasis(in: textView))
            }
        }

        private func activeEmphasis(in textView: UITextView) -> Int {
            let range = textView.selectedRange
            guard range.length > 0, let text = textView.attributedText else {
                return textView.typingAttributes[ComposerAttributedBridge.emphasisKey] as? Int ?? 0
            }
            var mask = 7
            text.enumerateAttribute(ComposerAttributedBridge.emphasisKey, in: range) { value, _, _ in
                mask &= (value as? Int) ?? 0
            }
            return mask
        }

        func setTypingEmphasis(_ mask: Int) {
            guard let textView else { return }
            var storage = textView.typingAttributes
            storage[ComposerAttributedBridge.emphasisKey] = mask == 0 ? nil : mask
            textView.typingAttributes = ComposerAttributedBridge.displayAttributes(
                storage: storage,
                style: parent.style,
                dark: lastDark
            )
        }

        // MARK: Emoji panel

        func panelView() -> UIView {
            if let host = panelHost { return host.view }
            let panel = ComposerEmojiPanel(
                onPick: { [weak self] pick in self?.insert(pick) },
                onDelete: { [weak self] in self?.deleteBackward() }
            )
            let host = UIHostingController(rootView: panel)
            host.view.backgroundColor = UIColor(Theme.bg)
            host.view.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: KeyboardHeightTracker.shared.height)
            host.view.autoresizingMask = [.flexibleWidth]
            host.sizingOptions = []
            panelHost = host
            return host.view
        }

        /// One pick, at the caret, replacing any selection. The panel stays up.
        func insert(_ pick: ComposerEmojiPick) {
            guard let textView else { return }
            ComposerEmojiRecents.record(pick)
            haptic.impactOccurred(intensity: 0.6)

            let storage = textView.textStorage
            let range = textView.selectedRange
            let base = ComposerAttributedBridge.storageAttributes(textView.typingAttributes)
            let inserted = NSMutableAttributedString()

            switch pick {
            case .site(let code):
                // The old picker's spacing, kept so the sent text is identical:
                // a space before when glued to a word, one after always.
                let preceding: Character? = {
                    guard range.location > 0 else { return nil }
                    let ns = storage.string as NSString
                    let r = ns.rangeOfComposedCharacterSequence(at: range.location - 1)
                    return (ns.substring(with: r)).first
                }()
                if let preceding, preceding.isLetter || preceding.isNumber {
                    inserted.append(NSAttributedString(string: " ", attributes: base))
                }
                inserted.append(ComposerAttributedBridge.emojiString(
                    code: code,
                    storage: base,
                    style: parent.style,
                    onImage: { [weak self] in self?.emojiImageArrived() }
                ))
                inserted.append(NSAttributedString(string: " ", attributes: base))
            case .character(let value), .kaomoji(let value):
                inserted.append(NSAttributedString(string: value, attributes: base))
            }

            let styled = NSMutableAttributedString(attributedString: inserted)
            ComposerAttributedBridge.restyle(styled, style: parent.style, dark: lastDark)
            textView.undoManager?.removeAllActions()
            storage.replaceCharacters(in: range, with: styled)
            textView.selectedRange = NSRange(location: range.location + styled.length, length: 0)
            pushText()
            refreshTypingAttributes()
            reportHeight()
            textView.scrollRangeToVisible(textView.selectedRange)
        }

        /// The panel's ⌫: one character, or one whole emoji.
        func deleteBackward() {
            guard let textView else { return }
            haptic.impactOccurred(intensity: 0.4)
            textView.deleteBackward()
            pushText()
            reportHeight()
        }

        /// A site emoji's image finished loading: redraw where it sits.
        private func emojiImageArrived() {
            guard let textView else { return }
            let storage = textView.textStorage
            storage.beginEditing()
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard let attachment = value as? ComposerEmojiAttachment else { return }
                storage.removeAttribute(.attachment, range: range)
                storage.addAttribute(.attachment, value: attachment, range: range)
            }
            storage.endEditing()
        }
    }
}

// MARK: - Text view

/// Copying or cutting gives `:code:` for site emoji, so it pastes correctly
/// anywhere.
final class ComposerUITextView: UITextView {
    weak var coordinator: ComposerTextEditor.Coordinator?

    override func copy(_ sender: Any?) {
        UIPasteboard.general.string = selectedPlainText()
    }

    override func cut(_ sender: Any?) {
        UIPasteboard.general.string = selectedPlainText()
        guard let range = selectedTextRange else { return }
        replace(range, withText: "")
    }

    private func selectedPlainText() -> String {
        let range = selectedRange
        guard range.length > 0 else { return "" }
        return ComposerAttributedBridge.plainText(attributedText.attributedSubstring(from: range))
    }
}

// MARK: - Attachment

/// A site emoji in the text: one character wide, sized to the line, sitting
/// on the baseline.
final class ComposerEmojiAttachment: NSTextAttachment {
    let code: String

    init(code: String, font: UIFont, onImage: @escaping @MainActor () -> Void) {
        self.code = code
        super.init(data: nil, ofType: nil)
        let side = (font.lineHeight).rounded()
        // On the baseline, sinking only as far as the descender.
        bounds = CGRect(x: 0, y: font.descender.rounded(), width: side, height: side)
        if let cached = ComposerEmojiImages.cached(code: code, side: side) {
            image = cached
        } else {
            image = ComposerEmojiImages.placeholder(side: side)
            Task { @MainActor [weak self] in
                guard let loaded = await ComposerEmojiImages.load(code: code, side: side) else { return }
                self?.image = loaded
                onImage()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Site emoji images for the editor: the shared remote cache, scaled to the
/// line off the main thread. Animated emoji show their first frame.
@MainActor
enum ComposerEmojiImages {
    private static let cache = NSCache<NSString, UIImage>()

    static func url(code: String) -> URL? {
        EmojiCatalog.shared.emoji(named: code)?.url.flatMap { nodelocSiteURL($0) }
    }

    static func cached(code: String, side: CGFloat) -> UIImage? {
        cache.object(forKey: "\(code)@\(Int(side))" as NSString)
    }

    static func load(code: String, side: CGFloat) async -> UIImage? {
        guard let url = url(code: code) else { return nil }
        let maxPixel = 96
        var source = RemoteImageMemoryCache.shared.image(for: url, atLeast: maxPixel)
        if source == nil {
            source = await RemoteImageDiskCache.shared.image(for: url, maxPixel: maxPixel)
            if let source { RemoteImageMemoryCache.shared.insert(source, for: url, maxPixel: maxPixel) }
        }
        guard let source else { return nil }
        let scaled = await Task.detached(priority: .userInitiated) { resize(source, side: side) }.value
        cache.setObject(scaled, forKey: "\(code)@\(Int(side))" as NSString)
        return scaled
    }

    nonisolated static func resize(_ image: UIImage, side: CGFloat) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let factor = min(side / size.width, side / size.height)
        let target = CGSize(width: size.width * factor, height: size.height * factor)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        let canvas = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            image.draw(in: CGRect(
                x: (side - target.width) / 2,
                y: (side - target.height) / 2,
                width: target.width,
                height: target.height
            ))
        }
    }

    static func placeholder(side: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            UIColor(Theme.surface).setFill()
            UIBezierPath(roundedRect: CGRect(x: 1, y: 1, width: side - 2, height: side - 2), cornerRadius: side / 4).fill()
        }
    }
}

// MARK: - Bridge

/// `AttributedString` (the composers' draft) ⇄ `NSAttributedString` (the
/// text view). The text view's storage carries the draft's own attributes
/// under private keys next to the fonts and colours drawn from them, so the
/// conversion back is exact.
@MainActor
enum ComposerAttributedBridge {
    static let emphasisKey = NSAttributedString.Key("nodeloc.emphasis")
    static let intentKey = NSAttributedString.Key("nodeloc.intent")
    static let linkKey = NSAttributedString.Key("nodeloc.link")
    static let emojiKey = NSAttributedString.Key("nodeloc.emoji")
    private static let storageKeys: [NSAttributedString.Key] = [emphasisKey, intentKey, linkKey, emojiKey]

    static func storageAttributes(_ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        attributes.filter { storageKeys.contains($0.key) && $0.key != emojiKey }
    }

    // MARK: Model → UIKit

    static func uiText(
        from text: AttributedString,
        style: ComposerEditorStyle,
        dark: Bool,
        onImage: @escaping @MainActor () -> Void
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in text.runs {
            var storage: [NSAttributedString.Key: Any] = [:]
            if style.readsEmphasisMask, let mask = run[EmphasisAttribute.self], mask != 0 {
                storage[emphasisKey] = mask
            }
            if style.readsPresentationIntent {
                if let intent = run.inlinePresentationIntent, !intent.isEmpty { storage[intentKey] = intent.rawValue }
                if let link = run.link { storage[linkKey] = link }
            }
            if let code = run[ComposerEmojiAttribute.self] {
                let count = text[run.range].characters.count
                for _ in 0..<max(count, 1) {
                    result.append(emojiString(code: code, storage: storage, style: style, onImage: onImage))
                }
                continue
            }
            result.append(NSAttributedString(string: String(text[run.range].characters), attributes: storage))
        }
        restyle(result, style: style, dark: dark)
        return result
    }

    static func emojiString(
        code: String,
        storage: [NSAttributedString.Key: Any],
        style: ComposerEditorStyle,
        onImage: @escaping @MainActor () -> Void
    ) -> NSAttributedString {
        let attachment = ComposerEmojiAttachment(code: code, font: style.font, onImage: onImage)
        let string = NSMutableAttributedString(attachment: attachment)
        var attributes = storage
        attributes[emojiKey] = code
        string.addAttributes(attributes, range: NSRange(location: 0, length: string.length))
        return string
    }

    /// Fonts and colours from the storage keys, over the whole string.
    static func restyle(_ string: NSMutableAttributedString, style: ComposerEditorStyle, dark: Bool) {
        let full = NSRange(location: 0, length: string.length)
        string.enumerateAttributes(in: full) { attributes, range, _ in
            let display = displayAttributes(storage: attributes, style: style, dark: dark)
            string.setAttributes(display, range: range)
        }
    }

    /// The storage keys plus what they look like.
    static func displayAttributes(
        storage: [NSAttributedString.Key: Any],
        style: ComposerEditorStyle,
        dark: Bool
    ) -> [NSAttributedString.Key: Any] {
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        var result: [NSAttributedString.Key: Any] = [:]
        for key in storageKeys { if let value = storage[key] { result[key] = value } }
        if let attachment = storage[.attachment] { result[.attachment] = attachment }

        var font = style.font
        var symbolic: UIFontDescriptor.SymbolicTraits = []
        var strike = false
        var code = false
        if let mask = storage[emphasisKey] as? Int {
            if mask & 1 != 0 { symbolic.insert(.traitBold) }
            if mask & 2 != 0 { symbolic.insert(.traitItalic) }
            if mask & 4 != 0 { strike = true }
        }
        if let raw = storage[intentKey] as? UInt {
            let intent = InlinePresentationIntent(rawValue: raw)
            if intent.contains(.stronglyEmphasized) { symbolic.insert(.traitBold) }
            if intent.contains(.emphasized) { symbolic.insert(.traitItalic) }
            if intent.contains(.strikethrough) { strike = true }
            if intent.contains(.code) { code = true }
        }
        if code {
            font = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
        } else if !symbolic.isEmpty, let descriptor = font.fontDescriptor.withSymbolicTraits(symbolic) {
            font = UIFont(descriptor: descriptor, size: font.pointSize)
        }
        result[.font] = font
        result[.foregroundColor] = storage[linkKey] != nil
            ? UIColor(Theme.accent).resolvedColor(with: traits)
            : UIColor(Theme.text).resolvedColor(with: traits)
        if strike { result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if code { result[.backgroundColor] = UIColor(Theme.hover).resolvedColor(with: traits) }
        if storage[linkKey] != nil { result[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return result
    }

    // MARK: UIKit → model

    static func model(from string: NSAttributedString, style: ComposerEditorStyle) -> AttributedString {
        var result = AttributedString()
        string.enumerateAttributes(in: NSRange(location: 0, length: string.length)) { attributes, range, _ in
            let substring = (string.string as NSString).substring(with: range)
            var piece = AttributedString(substring)
            var container = AttributeContainer()
            if let mask = attributes[emphasisKey] as? Int, mask != 0 {
                container[EmphasisAttribute.self] = mask
            }
            if let raw = attributes[intentKey] as? UInt {
                container.inlinePresentationIntent = InlinePresentationIntent(rawValue: raw)
            }
            if let link = attributes[linkKey] as? URL { container.link = link }
            if let code = attributes[emojiKey] as? String {
                container[ComposerEmojiAttribute.self] = code
            }
            piece.setAttributes(container)
            result += piece
        }
        return result
    }

    /// `:code:` for emoji, the characters for the rest.
    static func plainText(_ string: NSAttributedString) -> String {
        var out = ""
        string.enumerateAttributes(in: NSRange(location: 0, length: string.length)) { attributes, range, _ in
            if let code = attributes[emojiKey] as? String {
                out += String(repeating: ":\(code):", count: range.length)
            } else {
                out += (string.string as NSString).substring(with: range)
            }
        }
        return out
    }

    // MARK: Offsets

    static func nsRange(characterRange: Range<Int>, in string: String) -> NSRange {
        let count = string.count
        let lower = min(max(characterRange.lowerBound, 0), count)
        let upper = min(max(characterRange.upperBound, lower), count)
        let start = string.index(string.startIndex, offsetBy: lower)
        let end = string.index(start, offsetBy: upper - lower)
        return NSRange(start..<end, in: string)
    }

    static func characterRange(nsRange: NSRange, in string: String) -> Range<Int> {
        guard let range = Range(nsRange, in: string) else {
            let count = string.count
            return count..<count
        }
        let lower = string.distance(from: string.startIndex, to: range.lowerBound)
        let upper = lower + string.distance(from: range.lowerBound, to: range.upperBound)
        return lower..<upper
    }
}
