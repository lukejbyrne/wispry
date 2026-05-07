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

final class HubViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private weak var appDelegate: AppDelegate?
    private let store = SettingsStore.shared

    private let historyTable = NSTableView()
    private let historyDetailTextView = NSTextView()
    private let dictionaryTextView = NSTextView()
    private let snippetsTextView = NSTextView()
    private let scratchpadTextView = NSTextView()
    private let dictionaryField = NSTextField()
    private let snippetPhraseField = NSTextField()
    private let snippetExpansionField = NSTextField()
    private let stylePopup = NSPopUpButton()
    private let autoPasteButton = NSButton(checkboxWithTitle: "Paste into the active app when dictation ends", target: nil, action: nil)
    private let bubbleButton = NSButton(checkboxWithTitle: "Show floating bubble", target: nil, action: nil)
    private var historyExpandedAll = false

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
        stack.addArrangedSubview(historyPanel())
        stack.addArrangedSubview(scrollableText(historyDetailTextView, height: 120))

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

    private func historyPanel() -> NSView {
        let tableScroll = NSScrollView()
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.hasVerticalScroller = true
        tableScroll.wantsLayer = true
        tableScroll.layer?.backgroundColor = NSColor(calibratedWhite: 0.995, alpha: 0.92).cgColor
        tableScroll.layer?.cornerRadius = 8
        tableScroll.layer?.borderColor = NSColor(calibratedRed: 0.82, green: 0.85, blue: 0.90, alpha: 1).cgColor
        tableScroll.layer?.borderWidth = 1

        historyTable.headerView = nil
        historyTable.dataSource = self
        historyTable.delegate = self
        historyTable.rowHeight = 30
        historyTable.intercellSpacing = NSSize(width: 8, height: 4)
        historyTable.selectionHighlightStyle = .regular

        let timeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("time"))
        timeColumn.width = 142
        let summaryColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("summary"))
        summaryColumn.width = 410
        historyTable.addTableColumn(timeColumn)
        historyTable.addTableColumn(summaryColumn)
        tableScroll.documentView = historyTable

        let copy = NSButton(title: "Copy selected", target: self, action: #selector(copySelectedHistory))
        let expand = NSButton(title: "Expand all", target: self, action: #selector(toggleExpandHistory))
        let buttons = NSStackView(views: [copy, expand])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [tableScroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        tableScroll.widthAnchor.constraint(equalToConstant: 572).isActive = true
        tableScroll.heightAnchor.constraint(equalToConstant: 170).isActive = true
        return stack
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

        historyTable.reloadData()
        if historyTable.selectedRow < 0 && !store.recent.isEmpty {
            historyTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateHistoryDetail()

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

    @objc private func copySelectedHistory() {
        let selected = historyTable.selectedRow
        let text: String
        if historyExpandedAll {
            text = expandedHistoryText()
        } else if selected >= 0 && selected < store.recent.count {
            text = store.recent[selected].text
        } else {
            text = historyDetailTextView.string
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func toggleExpandHistory(_ sender: NSButton) {
        historyExpandedAll.toggle()
        sender.title = historyExpandedAll ? "Collapse" : "Expand all"
        updateHistoryDetail()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        store.recent.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < store.recent.count, let tableColumn else { return nil }
        let identifier = tableColumn.identifier
        let item = store.recent[row]
        let text = identifier.rawValue == "time"
            ? dateTimeFormatter.string(from: item.date)
            : summary(for: item.text)

        let cell = NSTableCellView()
        let field = NSTextField(labelWithString: text)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        field.font = identifier.rawValue == "time"
            ? NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            : NSFont.systemFont(ofSize: 13, weight: .medium)
        field.textColor = identifier.rawValue == "time"
            ? NSColor(calibratedRed: 0.36, green: 0.39, blue: 0.45, alpha: 1)
            : NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.18, alpha: 1)
        cell.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        historyExpandedAll = false
        updateHistoryDetail()
    }

    private func updateHistoryDetail() {
        if historyExpandedAll {
            historyDetailTextView.string = expandedHistoryText()
            return
        }

        let selected = historyTable.selectedRow
        if selected >= 0 && selected < store.recent.count {
            let item = store.recent[selected]
            historyDetailTextView.string = "\(dateTimeFormatter.string(from: item.date))  \(item.appName)\n\n\(item.text)"
        } else {
            historyDetailTextView.string = store.recent.isEmpty ? "No dictations yet." : ""
        }
    }

    private func expandedHistoryText() -> String {
        store.recent.map { item in
            "\(dateTimeFormatter.string(from: item.date))  \(item.appName)\n\(item.text)"
        }.joined(separator: "\n\n")
    }

    private func summary(for text: String) -> String {
        let words = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .prefix(8)
            .joined(separator: " ")
        if words.isEmpty { return "Empty dictation" }
        return text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count > 8 ? words + "..." : words
    }

    private var dateTimeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd MMM HH:mm"
        return formatter
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
