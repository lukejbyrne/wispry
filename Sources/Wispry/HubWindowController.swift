import AppKit

final class HubWindowController: NSWindowController {
    init(appDelegate: AppDelegate) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Wispry"
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
    private enum Section: String, CaseIterable {
        case home = "Home"
        case history = "History"
        case scratchpad = "Scratchpad"
        case dictionary = "Dictionary"
        case snippets = "Snippets"
        case shortcuts = "Shortcuts"
    }

    private weak var appDelegate: AppDelegate?
    private let store = SettingsStore.shared
    private var selectedSection: Section = .home

    private let sidebar = NSStackView()
    private let contentView = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let historyTable = NSTableView()
    private let historyDetailTextView = NSTextView()
    private let scratchpadTextView = NSTextView()
    private let dictionaryTextView = NSTextView()
    private let snippetsTextView = NSTextView()
    private let dictionaryField = NSTextField()
    private let snippetPhraseField = NSTextField()
    private let snippetExpansionField = NSTextField()
    private let stylePopup = NSPopUpButton()
    private let autoPasteButton = NSButton(checkboxWithTitle: "Auto paste when dictation ends", target: nil, action: nil)
    private let bubbleButton = NSButton(checkboxWithTitle: "Show floating bubble", target: nil, action: nil)
    private var sectionButtons: [Section: NSButton] = [:]
    private var historyExpandedAll = false

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 520))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedRed: 0.94, green: 0.95, blue: 0.97, alpha: 1).cgColor

        let root = NSStackView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.orientation = .horizontal
        root.alignment = .top
        root.spacing = 0
        view.addSubview(root)

        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 6
        sidebar.edgeInsets = NSEdgeInsets(top: 18, left: 14, bottom: 18, right: 14)
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1).cgColor

        let contentShell = NSView()
        contentShell.translatesAutoresizingMaskIntoConstraints = false
        contentShell.addSubview(contentView)
        contentView.translatesAutoresizingMaskIntoConstraints = false

        root.addArrangedSubview(sidebar)
        root.addArrangedSubview(contentShell)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 150),
            contentView.topAnchor.constraint(equalTo: contentShell.topAnchor, constant: 22),
            contentView.leadingAnchor.constraint(equalTo: contentShell.leadingAnchor, constant: 24),
            contentView.trailingAnchor.constraint(equalTo: contentShell.trailingAnchor, constant: -24),
            contentView.bottomAnchor.constraint(equalTo: contentShell.bottomAnchor, constant: -22)
        ])

        buildSidebar()
        render(section: .home)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    private func buildSidebar() {
        let brand = NSTextField(labelWithString: "Wispry")
        brand.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        brand.textColor = NSColor(calibratedWhite: 0.96, alpha: 1)
        sidebar.addArrangedSubview(brand)

        let spacer = NSView()
        spacer.heightAnchor.constraint(equalToConstant: 10).isActive = true
        sidebar.addArrangedSubview(spacer)

        for section in Section.allCases {
            let button = NSButton(title: section.rawValue, target: self, action: #selector(sectionSelected(_:)))
            button.bezelStyle = .texturedRounded
            button.alignment = .left
            button.tag = Section.allCases.firstIndex(of: section) ?? 0
            button.widthAnchor.constraint(equalToConstant: 122).isActive = true
            sectionButtons[section] = button
            sidebar.addArrangedSubview(button)
        }
        updateSidebarSelection()
    }

    @objc private func sectionSelected(_ sender: NSButton) {
        let sections = Section.allCases
        guard sender.tag >= 0 && sender.tag < sections.count else { return }
        render(section: sections[sender.tag])
    }

    private func render(section: Section) {
        selectedSection = section
        updateSidebarSelection()
        contentView.subviews.forEach { $0.removeFromSuperview() }

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        contentView.addSubview(stack)

        titleLabel.stringValue = section.rawValue
        titleLabel.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        subtitleLabel.stringValue = subtitle(for: section)
        subtitleLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textColor = NSColor(calibratedWhite: 0.34, alpha: 1)
        subtitleLabel.maximumNumberOfLines = 2

        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        stack.addArrangedSubview(content(for: section))

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor)
        ])

        refresh()
    }

    private func subtitle(for section: Section) -> String {
        switch section {
        case .home:
            return "Fast dictation controls and paste behavior."
        case .history:
            return "Recent dictations by time, with a short summary and full text."
        case .scratchpad:
            return "Draft or paste text here, then clean it up locally."
        case .dictionary:
            return "Terms Wispry should bias speech recognition toward."
        case .snippets:
            return "Spoken phrases that expand into reusable text."
        case .shortcuts:
            return "Keyboard and mouse controls."
        }
    }

    private func content(for section: Section) -> NSView {
        switch section {
        case .home:
            return homeView()
        case .history:
            return historyView()
        case .scratchpad:
            return scratchpadView()
        case .dictionary:
            return dictionaryView()
        case .snippets:
            return snippetsView()
        case .shortcuts:
            return shortcutsView()
        }
    }

    private func homeView() -> NSView {
        stylePopup.removeAllItems()
        stylePopup.addItems(withTitles: TransformStyle.allCases.map(\.rawValue))
        stylePopup.target = self
        stylePopup.action = #selector(styleChanged)

        autoPasteButton.target = self
        autoPasteButton.action = #selector(autoPasteChanged)
        bubbleButton.target = self
        bubbleButton.action = #selector(bubbleVisibilityChanged)

        let start = NSButton(title: "Start dictation", target: self, action: #selector(startDictation))
        let accessibility = NSButton(title: "Accessibility access", target: self, action: #selector(requestAccessibility))

        let styleRow = row(label: "Cleanup style", control: stylePopup)
        let buttons = NSStackView(views: [start, accessibility])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = panelStack()
        stack.addArrangedSubview(styleRow)
        stack.addArrangedSubview(autoPasteButton)
        stack.addArrangedSubview(bubbleButton)
        stack.addArrangedSubview(buttons)
        return panel(stack, height: 180)
    }

    private func historyView() -> NSView {
        historyTable.headerView = nil
        historyTable.dataSource = self
        historyTable.delegate = self
        historyTable.rowHeight = 30
        historyTable.intercellSpacing = NSSize(width: 8, height: 4)
        historyTable.selectionHighlightStyle = .regular
        if historyTable.tableColumns.isEmpty {
            let timeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("time"))
            timeColumn.width = 145
            let summaryColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("summary"))
            summaryColumn.width = 395
            historyTable.addTableColumn(timeColumn)
            historyTable.addTableColumn(summaryColumn)
        }

        let tableScroll = scrollView(document: historyTable, height: 210)
        let detail = scrollableText(historyDetailTextView, height: 130)
        let copy = NSButton(title: "Copy selected", target: self, action: #selector(copySelectedHistory))
        let expand = NSButton(title: "Expand all", target: self, action: #selector(toggleExpandHistory))
        let buttons = NSStackView(views: [copy, expand])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [tableScroll, detail, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        return stack
    }

    private func scratchpadView() -> NSView {
        let clean = NSButton(title: "Clean", target: self, action: #selector(cleanScratchpad))
        let professional = NSButton(title: "Professional", target: self, action: #selector(professionalScratchpad))
        let casual = NSButton(title: "Casual", target: self, action: #selector(casualScratchpad))
        let list = NSButton(title: "List", target: self, action: #selector(listScratchpad))
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyScratchpad))
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearScratchpad))
        let controls = NSStackView(views: [clean, professional, casual, list, copy, clear])
        controls.orientation = .horizontal
        controls.spacing = 8

        let stack = NSStackView(views: [controls, scrollableText(scratchpadTextView, height: 250, editable: true)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        return stack
    }

    private func dictionaryView() -> NSView {
        dictionaryField.placeholderString = "Add name, acronym, product, or technical term"
        let add = NSButton(title: "Add", target: self, action: #selector(addDictionaryWord))
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearDictionary))
        let row = NSStackView(views: [dictionaryField, add, clear])
        row.orientation = .horizontal
        row.spacing = 8
        dictionaryField.widthAnchor.constraint(equalToConstant: 350).isActive = true

        let stack = NSStackView(views: [row, scrollableText(dictionaryTextView, height: 260)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        return stack
    }

    private func snippetsView() -> NSView {
        snippetPhraseField.placeholderString = "Spoken phrase"
        snippetExpansionField.placeholderString = "Expansion"
        let add = NSButton(title: "Add", target: self, action: #selector(addSnippet))
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetSnippets))
        let row = NSStackView(views: [snippetPhraseField, snippetExpansionField, add, reset])
        row.orientation = .horizontal
        row.spacing = 8
        snippetPhraseField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        snippetExpansionField.widthAnchor.constraint(equalToConstant: 270).isActive = true

        let stack = NSStackView(views: [row, scrollableText(snippetsTextView, height: 260)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        return stack
    }

    private func shortcutsView() -> NSView {
        let shortcuts = [
            "Click bubble: start or stop dictation",
            "Return while recording: stop, clean up, paste",
            "Escape while recording: cancel",
            "Hold Fn: push to talk, release to stop",
            "Double-tap Fn: latch recording",
            "Control+Option+Space: toggle",
            "F13: mouse trigger",
            "Option+2/3/4/5: repolish selected text"
        ].joined(separator: "\n")
        let text = NSTextView()
        text.string = shortcuts
        return scrollableText(text, height: 280)
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
        dictionaryTextView.string = store.dictionaryWords.isEmpty ? "No dictionary terms yet." : store.dictionaryWords.joined(separator: "\n")
        snippetsTextView.string = store.snippets.map { "\"\($0.phrase)\" -> \($0.expansion)" }.joined(separator: "\n\n")
    }

    private func updateSidebarSelection() {
        for (section, button) in sectionButtons {
            button.state = section == selectedSection ? .on : .off
        }
    }

    private func panelStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        return stack
    }

    private func panel(_ content: NSView, height: CGFloat? = nil) -> NSView {
        let wrapper = NSView()
        wrapper.wantsLayer = true
        wrapper.layer?.backgroundColor = NSColor(calibratedWhite: 0.985, alpha: 1).cgColor
        wrapper.layer?.cornerRadius = 8
        wrapper.layer?.borderColor = NSColor(calibratedWhite: 0.82, alpha: 1).cgColor
        wrapper.layer?.borderWidth = 1
        content.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 14),
            content.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor, constant: -14),
            content.bottomAnchor.constraint(lessThanOrEqualTo: wrapper.bottomAnchor, constant: -14),
            wrapper.widthAnchor.constraint(equalToConstant: 540)
        ])
        if let height {
            wrapper.heightAnchor.constraint(equalToConstant: height).isActive = true
        }
        return wrapper
    }

    private func row(label text: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor(calibratedWhite: 0.18, alpha: 1)
        label.widthAnchor.constraint(equalToConstant: 112).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func scrollView(document: NSView, height: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.wantsLayer = true
        scroll.layer?.backgroundColor = NSColor(calibratedWhite: 0.985, alpha: 1).cgColor
        scroll.layer?.cornerRadius = 8
        scroll.layer?.borderColor = NSColor(calibratedWhite: 0.82, alpha: 1).cgColor
        scroll.layer?.borderWidth = 1
        scroll.widthAnchor.constraint(equalToConstant: 540).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }

    private func scrollableText(_ textView: NSTextView, height: CGFloat, editable: Bool = false) -> NSScrollView {
        textView.isEditable = editable
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textColor = NSColor(calibratedWhite: 0.11, alpha: 1)
        textView.insertionPointColor = NSColor(calibratedWhite: 0.1, alpha: 1)
        return scrollView(document: textView, height: height)
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

    @objc private func cleanScratchpad() { transformScratchpad(.clean) }
    @objc private func professionalScratchpad() { transformScratchpad(.professional) }
    @objc private func casualScratchpad() { transformScratchpad(.casual) }
    @objc private func listScratchpad() { transformScratchpad(.list) }

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
        let item = store.recent[row]
        let text = tableColumn.identifier.rawValue == "time" ? dateFormatter.string(from: item.date) : summary(for: item.text)
        let cell = NSTableCellView()
        let field = NSTextField(labelWithString: text)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        field.font = tableColumn.identifier.rawValue == "time" ? NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: 13, weight: .medium)
        field.textColor = tableColumn.identifier.rawValue == "time" ? NSColor(calibratedWhite: 0.38, alpha: 1) : NSColor(calibratedWhite: 0.10, alpha: 1)
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
            historyDetailTextView.string = "\(dateFormatter.string(from: item.date))  \(item.appName)\n\n\(item.text)"
        } else {
            historyDetailTextView.string = store.recent.isEmpty ? "No dictations yet." : ""
        }
    }

    private func expandedHistoryText() -> String {
        store.recent.map { "\(dateFormatter.string(from: $0.date))  \($0.appName)\n\($0.text)" }.joined(separator: "\n\n")
    }

    private func summary(for text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let summary = words.prefix(8).joined(separator: " ")
        return words.count > 8 ? summary + "..." : (summary.isEmpty ? "Empty dictation" : summary)
    }

    private var dateFormatter: DateFormatter {
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
