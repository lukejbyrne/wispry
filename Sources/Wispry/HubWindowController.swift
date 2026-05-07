import AppKit
import Carbon

private enum HubPalette {
    static let window = NSColor(calibratedRed: 0.946, green: 0.949, blue: 0.936, alpha: 1)
    static let sidebar = NSColor(calibratedRed: 0.912, green: 0.920, blue: 0.902, alpha: 1)
    static let panel = NSColor(calibratedRed: 0.982, green: 0.980, blue: 0.966, alpha: 1)
    static let field = NSColor(calibratedRed: 0.992, green: 0.990, blue: 0.976, alpha: 1)
    static let text = NSColor(calibratedRed: 0.082, green: 0.086, blue: 0.078, alpha: 1)
    static let muted = NSColor(calibratedRed: 0.382, green: 0.392, blue: 0.360, alpha: 1)
    static let border = NSColor(calibratedRed: 0.746, green: 0.746, blue: 0.696, alpha: 1)
    static let selected = NSColor(calibratedRed: 0.796, green: 0.875, blue: 0.980, alpha: 1)
    static let accent = NSColor(calibratedRed: 0.094, green: 0.310, blue: 0.690, alpha: 1)
}

final class HubWindowController: NSWindowController {
    init(appDelegate: AppDelegate) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 540),
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
    private let historySearchField = NSSearchField()
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
    private var historyQuery = ""
    private var shortcutCaptureAction: ShortcutAction?
    private var shortcutCaptureMonitor: Any?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 540))
        view.wantsLayer = true
        view.layer?.backgroundColor = HubPalette.window.cgColor

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
        sidebar.layer?.backgroundColor = HubPalette.sidebar.cgColor

        let contentShell = NSView()
        contentShell.translatesAutoresizingMaskIntoConstraints = false
        contentShell.wantsLayer = true
        contentShell.layer?.backgroundColor = HubPalette.window.cgColor
        contentShell.addSubview(contentView)
        contentView.translatesAutoresizingMaskIntoConstraints = false

        root.addArrangedSubview(sidebar)
        root.addArrangedSubview(contentShell)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 156),
            contentView.topAnchor.constraint(equalTo: contentShell.topAnchor, constant: 22),
            contentView.leadingAnchor.constraint(equalTo: contentShell.leadingAnchor, constant: 24),
            contentView.trailingAnchor.constraint(equalTo: contentShell.trailingAnchor, constant: -24),
            contentView.bottomAnchor.constraint(equalTo: contentShell.bottomAnchor, constant: -22)
        ])

        buildSidebar()
        installShortcutCaptureMonitor()
        render(section: .home)
    }

    deinit {
        if let shortcutCaptureMonitor {
            NSEvent.removeMonitor(shortcutCaptureMonitor)
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    private func buildSidebar() {
        let brand = NSTextField(labelWithString: "Wispry")
        brand.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        brand.textColor = HubPalette.text
        sidebar.addArrangedSubview(brand)

        let tagline = NSTextField(labelWithString: "voice in, text out")
        tagline.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        tagline.textColor = HubPalette.muted
        sidebar.addArrangedSubview(tagline)

        let spacer = NSView()
        spacer.heightAnchor.constraint(equalToConstant: 12).isActive = true
        sidebar.addArrangedSubview(spacer)

        for section in Section.allCases {
            let button = NSButton(title: section.rawValue, target: self, action: #selector(sectionSelected(_:)))
            button.bezelStyle = .shadowlessSquare
            button.alignment = .left
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 7
            button.tag = Section.allCases.firstIndex(of: section) ?? 0
            button.widthAnchor.constraint(equalToConstant: 128).isActive = true
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
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
        titleLabel.textColor = HubPalette.text
        subtitleLabel.stringValue = subtitle(for: section)
        subtitleLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textColor = HubPalette.muted
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
            return "Start quickly, keep paste predictable, tune the cleanup."
        case .history:
            return "Recent dictations by time, with a short summary and full text."
        case .scratchpad:
            return "Draft or paste text here, then clean it up locally."
        case .dictionary:
            return "Terms Wispry should bias speech recognition toward."
        case .snippets:
            return "Spoken phrases that expand into reusable text."
        case .shortcuts:
            return "Record your own key combos. Fn remains the push-to-talk modifier."
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
        start.bezelStyle = .rounded
        start.keyEquivalent = "\r"
        let accessibility = NSButton(title: "Accessibility access", target: self, action: #selector(requestAccessibility))
        accessibility.bezelStyle = .rounded

        let styleRow = row(label: "Cleanup style", control: stylePopup)
        let buttons = NSStackView(views: [start, accessibility])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let status = homeStatusView()
        let stack = panelStack()
        stack.addArrangedSubview(status)
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(styleRow)
        stack.addArrangedSubview(autoPasteButton)
        stack.addArrangedSubview(bubbleButton)
        stack.addArrangedSubview(buttons)
        return panel(stack, height: 228)
    }

    private func historyView() -> NSView {
        historySearchField.placeholderString = "Search history"
        historySearchField.target = self
        historySearchField.action = #selector(historySearchChanged)
        historySearchField.widthAnchor.constraint(equalToConstant: 540).isActive = true

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

        let stack = NSStackView(views: [historySearchField, tableScroll, detail, buttons])
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
        let stack = panelStack()
        for action in ShortcutAction.allCases {
            stack.addArrangedSubview(shortcutRow(for: action))
        }

        let fixed = NSTextField(wrappingLabelWithString: "Fixed while recording: Return commits, Escape cancels. Fn hold is push-to-talk; double-tap Fn latches, pressing Fn again commits. Mouse trigger: F13.")
        fixed.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        fixed.textColor = HubPalette.muted
        fixed.maximumNumberOfLines = 3
        stack.addArrangedSubview(fixed)
        return panel(stack, height: 310)
    }

    private func refresh() {
        stylePopup.selectItem(withTitle: store.transformStyle.rawValue)
        autoPasteButton.state = store.autoPaste ? .on : .off
        bubbleButton.state = store.bubbleVisible ? .on : .off
        historySearchField.stringValue = historyQuery
        historyTable.reloadData()
        if historyTable.selectedRow < 0 && !filteredHistory.isEmpty {
            historyTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateHistoryDetail()
        dictionaryTextView.string = store.dictionaryWords.isEmpty ? "No dictionary terms yet." : store.dictionaryWords.joined(separator: "\n")
        snippetsTextView.string = store.snippets.map { "\"\($0.phrase)\" -> \($0.expansion)" }.joined(separator: "\n\n")
    }

    private func updateSidebarSelection() {
        for (section, button) in sectionButtons {
            button.state = section == selectedSection ? .on : .off
            applySidebarButtonStyle(button, selected: section == selectedSection)
        }
    }

    private func applySidebarButtonStyle(_ button: NSButton, selected: Bool) {
        button.layer?.backgroundColor = selected ? HubPalette.selected.cgColor : NSColor.clear.cgColor
        let color = selected ? HubPalette.accent : HubPalette.text
        let font = NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .medium)
        let title = NSAttributedString(
            string: button.title,
            attributes: [
                .foregroundColor: color,
                .font: font
            ]
        )
        button.attributedTitle = title
        button.attributedAlternateTitle = title
    }

    private func homeStatusView() -> NSView {
        let paste = store.autoPaste ? "Paste on" : "Clipboard only"
        let bubble = store.bubbleVisible ? "Bubble on" : "Bubble hidden"
        let style = store.transformStyle.rawValue
        let row = NSStackView(views: [
            statusChip(title: "Ready"),
            statusChip(title: paste),
            statusChip(title: style),
            statusChip(title: bubble)
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func statusChip(title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = HubPalette.accent
        label.alignment = .center

        let wrapper = NSView()
        wrapper.wantsLayer = true
        wrapper.layer?.backgroundColor = HubPalette.selected.withAlphaComponent(0.56).cgColor
        wrapper.layer?.cornerRadius = 7
        wrapper.layer?.borderColor = HubPalette.selected.cgColor
        wrapper.layer?.borderWidth = 1
        wrapper.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 5),
            label.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -9),
            label.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -5)
        ])
        return wrapper
    }

    private func separator() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = HubPalette.border.withAlphaComponent(0.65).cgColor
        line.widthAnchor.constraint(equalToConstant: 532).isActive = true
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
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
        wrapper.layer?.backgroundColor = HubPalette.panel.cgColor
        wrapper.layer?.cornerRadius = 8
        wrapper.layer?.borderColor = HubPalette.border.cgColor
        wrapper.layer?.borderWidth = 1
        content.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 14),
            content.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor, constant: -14),
            content.bottomAnchor.constraint(lessThanOrEqualTo: wrapper.bottomAnchor, constant: -14),
            wrapper.widthAnchor.constraint(equalToConstant: 560)
        ])
        if let height {
            wrapper.heightAnchor.constraint(equalToConstant: height).isActive = true
        }
        return wrapper
    }

    private func row(label text: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = HubPalette.text
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
        scroll.drawsBackground = true
        scroll.backgroundColor = HubPalette.field
        scroll.layer?.backgroundColor = HubPalette.field.cgColor
        scroll.layer?.cornerRadius = 8
        scroll.layer?.borderColor = HubPalette.border.cgColor
        scroll.layer?.borderWidth = 1
        scroll.widthAnchor.constraint(equalToConstant: 560).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }

    private func scrollableText(_ textView: NSTextView, height: CGFloat, editable: Bool = false) -> NSScrollView {
        textView.isEditable = editable
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = HubPalette.field
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textColor = HubPalette.text
        textView.insertionPointColor = HubPalette.text
        return scrollView(document: textView, height: height)
    }

    private func shortcutRow(for action: ShortcutAction) -> NSView {
        let title = NSTextField(labelWithString: action.title)
        title.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        title.textColor = HubPalette.text
        title.widthAnchor.constraint(equalToConstant: 180).isActive = true

        let shortcut = NSTextField(labelWithString: shortcutCaptureAction == action ? "Press new shortcut..." : store.shortcuts.shortcut(for: action).display)
        shortcut.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        shortcut.textColor = shortcutCaptureAction == action
            ? HubPalette.accent
            : HubPalette.muted
        shortcut.widthAnchor.constraint(equalToConstant: 175).isActive = true

        let record = NSButton(title: "Record", target: self, action: #selector(recordShortcut(_:)))
        record.tag = ShortcutAction.allCases.firstIndex(of: action) ?? 0
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetShortcut(_:)))
        reset.tag = record.tag

        let row = NSStackView(views: [title, shortcut, record, reset])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    @objc private func styleChanged() {
        guard let title = stylePopup.selectedItem?.title, let style = TransformStyle(rawValue: title) else { return }
        store.transformStyle = style
    }

    @objc private func historySearchChanged() {
        historyQuery = historySearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        historyTable.deselectAll(nil)
        historyTable.reloadData()
        if !filteredHistory.isEmpty {
            historyTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateHistoryDetail()
    }

    @objc private func recordShortcut(_ sender: NSButton) {
        let actions = ShortcutAction.allCases
        guard sender.tag >= 0 && sender.tag < actions.count else { return }
        shortcutCaptureAction = actions[sender.tag]
        render(section: .shortcuts)
    }

    @objc private func resetShortcut(_ sender: NSButton) {
        let actions = ShortcutAction.allCases
        guard sender.tag >= 0 && sender.tag < actions.count else { return }
        let action = actions[sender.tag]
        let defaults = ShortcutSettings.defaults
        store.setShortcut(defaults.shortcut(for: action), for: action)
        appDelegate?.reloadHotKeys()
        render(section: .shortcuts)
    }

    @objc private func autoPasteChanged() {
        store.autoPaste = autoPasteButton.state == .on
        render(section: .home)
    }

    @objc private func bubbleVisibilityChanged() {
        store.bubbleVisible = bubbleButton.state == .on
        appDelegate?.setBubbleVisible(store.bubbleVisible)
        render(section: .home)
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
        let items = filteredHistory
        let text: String
        if historyExpandedAll {
            text = expandedHistoryText()
        } else if selected >= 0 && selected < items.count {
            text = items[selected].text
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
        filteredHistory.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let items = filteredHistory
        guard row < items.count, let tableColumn else { return nil }
        let item = items[row]
        let text = tableColumn.identifier.rawValue == "time" ? dateFormatter.string(from: item.date) : summary(for: item.text)
        let cell = NSTableCellView()
        let field = NSTextField(labelWithString: text)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        field.font = tableColumn.identifier.rawValue == "time" ? NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: 13, weight: .medium)
        field.textColor = tableColumn.identifier.rawValue == "time" ? HubPalette.muted : HubPalette.text
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
        let items = filteredHistory
        if selected >= 0 && selected < items.count {
            let item = items[selected]
            historyDetailTextView.string = "\(dateFormatter.string(from: item.date))  \(item.appName)\n\n\(item.text)"
        } else {
            historyDetailTextView.string = store.recent.isEmpty ? "No dictations yet." : ""
        }
    }

    private func expandedHistoryText() -> String {
        filteredHistory.map { "\(dateFormatter.string(from: $0.date))  \($0.appName)\n\($0.text)" }.joined(separator: "\n\n")
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

    private var filteredHistory: [RecentDictation] {
        guard !historyQuery.isEmpty else { return store.recent }
        let needle = historyQuery.lowercased()
        return store.recent.filter {
            $0.text.lowercased().contains(needle)
                || $0.appName.lowercased().contains(needle)
                || summary(for: $0.text).lowercased().contains(needle)
        }
    }

    private func installShortcutCaptureMonitor() {
        guard shortcutCaptureMonitor == nil else { return }
        shortcutCaptureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let action = self.shortcutCaptureAction else { return event }
            guard let shortcut = self.shortcut(from: event) else { return nil }
            self.store.setShortcut(shortcut, for: action)
            self.appDelegate?.reloadHotKeys()
            self.shortcutCaptureAction = nil
            self.render(section: .shortcuts)
            return nil
        }
    }

    private func shortcut(from event: NSEvent) -> KeyShortcut? {
        let modifiers = carbonModifiers(from: event.modifierFlags)
        guard modifiers != 0 else { return nil }
        return KeyShortcut(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers,
            display: shortcutDisplay(keyCode: event.keyCode, flags: event.modifierFlags)
        )
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private func shortcutDisplay(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("Control") }
        if flags.contains(.option) { parts.append("Option") }
        if flags.contains(.shift) { parts.append("Shift") }
        if flags.contains(.command) { parts.append("Command") }
        parts.append(keyName(for: keyCode))
        return parts.joined(separator: "+")
    }

    private func keyName(for keyCode: UInt16) -> String {
        let names: [UInt16: String] = [
            UInt16(kVK_Space): "Space",
            UInt16(kVK_Return): "Return",
            UInt16(kVK_Escape): "Escape",
            UInt16(kVK_Tab): "Tab",
            UInt16(kVK_ANSI_0): "0",
            UInt16(kVK_ANSI_1): "1",
            UInt16(kVK_ANSI_2): "2",
            UInt16(kVK_ANSI_3): "3",
            UInt16(kVK_ANSI_4): "4",
            UInt16(kVK_ANSI_5): "5",
            UInt16(kVK_ANSI_6): "6",
            UInt16(kVK_ANSI_7): "7",
            UInt16(kVK_ANSI_8): "8",
            UInt16(kVK_ANSI_9): "9",
            UInt16(kVK_ANSI_A): "A",
            UInt16(kVK_ANSI_B): "B",
            UInt16(kVK_ANSI_C): "C",
            UInt16(kVK_ANSI_D): "D",
            UInt16(kVK_ANSI_E): "E",
            UInt16(kVK_ANSI_F): "F",
            UInt16(kVK_ANSI_G): "G",
            UInt16(kVK_ANSI_H): "H",
            UInt16(kVK_ANSI_I): "I",
            UInt16(kVK_ANSI_J): "J",
            UInt16(kVK_ANSI_K): "K",
            UInt16(kVK_ANSI_L): "L",
            UInt16(kVK_ANSI_M): "M",
            UInt16(kVK_ANSI_N): "N",
            UInt16(kVK_ANSI_O): "O",
            UInt16(kVK_ANSI_P): "P",
            UInt16(kVK_ANSI_Q): "Q",
            UInt16(kVK_ANSI_R): "R",
            UInt16(kVK_ANSI_S): "S",
            UInt16(kVK_ANSI_T): "T",
            UInt16(kVK_ANSI_U): "U",
            UInt16(kVK_ANSI_V): "V",
            UInt16(kVK_ANSI_W): "W",
            UInt16(kVK_ANSI_X): "X",
            UInt16(kVK_ANSI_Y): "Y",
            UInt16(kVK_ANSI_Z): "Z"
        ]
        return names[keyCode] ?? "Key \(keyCode)"
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
