import AppKit

final class HubWindowController: NSWindowController {
    init(appDelegate: AppDelegate) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Wispry Hub"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentViewController = HubViewController(appDelegate: appDelegate)
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        nil
    }
}

final class HubViewController: NSViewController {
    private weak var appDelegate: AppDelegate?
    private let store = SettingsStore.shared

    private let recentTextView = NSTextView()
    private let dictionaryTextView = NSTextView()
    private let snippetsTextView = NSTextView()
    private let scratchpadTextView = NSTextView()
    private let dictionaryField = NSTextField()
    private let snippetPhraseField = NSTextField()
    private let snippetExpansionField = NSTextField()
    private let stylePopup = NSPopUpButton()
    private let autoPasteButton = NSButton(checkboxWithTitle: "Paste into the active app when dictation ends", target: nil, action: nil)
    private let bubbleButton = NSButton(checkboxWithTitle: "Show floating bubble", target: nil, action: nil)

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 720))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedRed: 0.965, green: 0.970, blue: 0.978, alpha: 1).cgColor

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        view.addSubview(scrollView)

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = content

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
        ])

        stack.addArrangedSubview(titleLabel("Wispry Home"))
        stack.addArrangedSubview(bodyLabel("Dictation, shortcuts, snippets, transformations, scratchpad, dictionary, and history."))

        stack.addArrangedSubview(sectionTitle("Controls"))
        stack.addArrangedSubview(settingsPanel())

        stack.addArrangedSubview(sectionTitle("Scratchpad"))
        stack.addArrangedSubview(scratchpadPanel())
        stack.addArrangedSubview(scrollableText(scratchpadTextView, height: 130, editable: true))

        stack.addArrangedSubview(sectionTitle("History"))
        stack.addArrangedSubview(scrollableText(recentTextView, height: 130))

        stack.addArrangedSubview(sectionTitle("Personal Dictionary"))
        stack.addArrangedSubview(dictionaryPanel())
        stack.addArrangedSubview(scrollableText(dictionaryTextView, height: 100))

        stack.addArrangedSubview(sectionTitle("Snippets"))
        stack.addArrangedSubview(snippetPanel())
        stack.addArrangedSubview(scrollableText(snippetsTextView, height: 130))

        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    private func settingsPanel() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let styleLabel = bodyLabel("Default cleanup")
        stylePopup.addItems(withTitles: TransformStyle.allCases.map(\.rawValue))
        stylePopup.target = self
        stylePopup.action = #selector(styleChanged)
        row.addArrangedSubview(styleLabel)
        row.addArrangedSubview(stylePopup)

        autoPasteButton.target = self
        autoPasteButton.action = #selector(autoPasteChanged)
        bubbleButton.target = self
        bubbleButton.action = #selector(bubbleVisibilityChanged)

        let accessibility = NSButton(title: "Open Accessibility Prompt", target: self, action: #selector(requestAccessibility))
        let start = NSButton(title: "Start Dictation", target: self, action: #selector(startDictation))

        stack.addArrangedSubview(row)
        stack.addArrangedSubview(autoPasteButton)
        stack.addArrangedSubview(bubbleButton)

        let buttonRow = NSStackView(views: [start, accessibility])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        stack.addArrangedSubview(buttonRow)
        stack.addArrangedSubview(bodyLabel("Shortcuts: hold Fn for push-to-talk, double-tap Fn to latch, Escape cancels, Control+Option+Space toggles, F13 supports mouse triggers, Option+2/3/4/5 repolishes selected text."))

        return panel(stack)
    }

    private func scratchpadPanel() -> NSView {
        let clean = NSButton(title: "Clean", target: self, action: #selector(cleanScratchpad))
        let professional = NSButton(title: "Professional", target: self, action: #selector(professionalScratchpad))
        let casual = NSButton(title: "Casual", target: self, action: #selector(casualScratchpad))
        let list = NSButton(title: "List", target: self, action: #selector(listScratchpad))
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyScratchpad))
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearScratchpad))
        let row = NSStackView(views: [clean, professional, casual, list, copy, clear])
        row.orientation = .horizontal
        row.spacing = 8
        return panel(row)
    }

    private func dictionaryPanel() -> NSView {
        dictionaryField.placeholderString = "Add a name, acronym, product, or technical term"
        dictionaryField.translatesAutoresizingMaskIntoConstraints = false
        let add = NSButton(title: "Add", target: self, action: #selector(addDictionaryWord))
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearDictionary))
        let row = NSStackView(views: [dictionaryField, add, clear])
        row.orientation = .horizontal
        row.spacing = 8
        dictionaryField.widthAnchor.constraint(equalToConstant: 340).isActive = true
        return panel(row)
    }

    private func snippetPanel() -> NSView {
        snippetPhraseField.placeholderString = "Spoken phrase"
        snippetExpansionField.placeholderString = "Expansion text"
        snippetPhraseField.translatesAutoresizingMaskIntoConstraints = false
        snippetExpansionField.translatesAutoresizingMaskIntoConstraints = false
        snippetPhraseField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        snippetExpansionField.widthAnchor.constraint(equalToConstant: 250).isActive = true

        let add = NSButton(title: "Add", target: self, action: #selector(addSnippet))
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetSnippets))
        let row = NSStackView(views: [snippetPhraseField, snippetExpansionField, add, reset])
        row.orientation = .horizontal
        row.spacing = 8
        return panel(row)
    }

    private func panel(_ content: NSView) -> NSView {
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.wantsLayer = true
        wrapper.layer?.backgroundColor = NSColor(calibratedWhite: 0.995, alpha: 0.92).cgColor
        wrapper.layer?.cornerRadius = 8
        wrapper.layer?.borderColor = NSColor(calibratedRed: 0.82, green: 0.85, blue: 0.90, alpha: 1).cgColor
        wrapper.layer?.borderWidth = 1

        content.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 12),
            content.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor, constant: -12),
            content.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -12),
            wrapper.widthAnchor.constraint(equalToConstant: 572)
        ])
        return wrapper
    }

    private func scrollableText(_ textView: NSTextView, height: CGFloat, editable: Bool = false) -> NSView {
        textView.isEditable = editable
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = editable ? NSFont.systemFont(ofSize: 13) : NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor(calibratedRed: 0.12, green: 0.15, blue: 0.20, alpha: 0.94)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.wantsLayer = true
        scroll.layer?.backgroundColor = NSColor(calibratedWhite: 0.995, alpha: 0.9).cgColor
        scroll.layer?.cornerRadius = 8
        scroll.layer?.borderColor = NSColor(calibratedRed: 0.82, green: 0.85, blue: 0.90, alpha: 1).cgColor
        scroll.layer?.borderWidth = 1
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 572),
            scroll.heightAnchor.constraint(equalToConstant: height)
        ])
        return scroll
    }

    private func titleLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 28, weight: .bold)
        label.textColor = NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.18, alpha: 1)
        return label
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        label.textColor = NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.18, alpha: 1)
        return label
    }

    private func bodyLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = NSColor(calibratedRed: 0.25, green: 0.28, blue: 0.34, alpha: 1)
        label.maximumNumberOfLines = 0
        return label
    }

    private func refresh() {
        stylePopup.selectItem(withTitle: store.transformStyle.rawValue)
        autoPasteButton.state = store.autoPaste ? .on : .off
        bubbleButton.state = store.bubbleVisible ? .on : .off

        let formatter = RelativeDateTimeFormatter()
        recentTextView.string = store.recent.map { item in
            let time = formatter.localizedString(for: item.date, relativeTo: Date())
            return "[\(time), \(item.appName)]\n\(item.text)"
        }.joined(separator: "\n\n")

        dictionaryTextView.string = store.dictionaryWords.isEmpty
            ? "No dictionary words yet. Wispry also auto-learns likely capitalized terms from accepted dictations."
            : store.dictionaryWords.joined(separator: "\n")

        snippetsTextView.string = store.snippets.map { snippet in
            "\"\(snippet.phrase)\" -> \(snippet.expansion)"
        }.joined(separator: "\n\n")
    }

    @objc private func styleChanged() {
        guard let title = stylePopup.selectedItem?.title, let style = TransformStyle(rawValue: title) else { return }
        store.transformStyle = style
    }

    @objc private func autoPasteChanged() {
        store.autoPaste = autoPasteButton.state == .on
    }

    @objc private func bubbleVisibilityChanged() {
        store.bubbleVisible = bubbleButton.state == .on
        appDelegate?.setBubbleVisible(store.bubbleVisible)
    }

    @objc private func requestAccessibility() {
        appDelegate?.requestAccessibilityPrompt()
    }

    @objc private func startDictation() {
        appDelegate?.toggleDictation()
    }

    @objc private func cleanScratchpad() {
        transformScratchpad(.clean)
    }

    @objc private func professionalScratchpad() {
        transformScratchpad(.professional)
    }

    @objc private func casualScratchpad() {
        transformScratchpad(.casual)
    }

    @objc private func listScratchpad() {
        transformScratchpad(.list)
    }

    @objc private func copyScratchpad() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(scratchpadTextView.string, forType: .string)
    }

    @objc private func clearScratchpad() {
        scratchpadTextView.string = ""
    }

    private func transformScratchpad(_ style: TransformStyle) {
        let processed = TextPipeline.process(scratchpadTextView.string, style: style, snippets: store.snippets)
        if !processed.cancelled {
            scratchpadTextView.string = processed.text
        }
    }

    @objc private func addDictionaryWord() {
        let word = dictionaryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        store.dictionaryWords = store.dictionaryWords + [word]
        dictionaryField.stringValue = ""
        refresh()
    }

    @objc private func clearDictionary() {
        store.dictionaryWords = []
        refresh()
    }

    @objc private func addSnippet() {
        let phrase = snippetPhraseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let expansion = snippetExpansionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, !expansion.isEmpty else { return }
        store.snippets = store.snippets + [VoiceSnippet(phrase: phrase, expansion: expansion)]
        snippetPhraseField.stringValue = ""
        snippetExpansionField.stringValue = ""
        refresh()
    }

    @objc private func resetSnippets() {
        store.snippets = VoiceSnippet.defaults
        refresh()
    }
}
