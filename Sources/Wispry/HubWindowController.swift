import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import Speech

private enum HubPalette {
    static let signalSurface = NSColor(calibratedRed: 0.062, green: 0.080, blue: 0.062, alpha: 1)
    static let signalPanel = NSColor(calibratedRed: 0.088, green: 0.114, blue: 0.088, alpha: 1)
    static let signalField = NSColor(calibratedRed: 0.050, green: 0.065, blue: 0.050, alpha: 1)
    static let signalText = NSColor(calibratedRed: 0.965, green: 0.946, blue: 0.895, alpha: 1)
    static let signalMuted = NSColor(calibratedRed: 0.680, green: 0.692, blue: 0.642, alpha: 1)
    static let signalBorder = NSColor(calibratedRed: 0.965, green: 0.946, blue: 0.895, alpha: 0.18)
    static let signalAccent = NSColor(calibratedRed: 0.655, green: 0.815, blue: 0.420, alpha: 1)
    static let signalRed = NSColor(calibratedRed: 0.790, green: 0.270, blue: 0.210, alpha: 1)
    static let window = signalSurface
    static let sidebar = signalSurface
    static let panel = signalPanel
    static let field = signalField
    static let text = signalText
    static let muted = signalMuted
    static let border = signalBorder
    static let selected = signalAccent.withAlphaComponent(0.14)
    static let accent = signalAccent
}

final class HubWindowController: NSWindowController {
    init(appDelegate: AppDelegate) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Wispry"
        window.minSize = NSSize(width: 820, height: 560)
        window.center()
        window.isReleasedWhenClosed = false
        window.contentViewController = HubViewController(appDelegate: appDelegate)
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func showShortcuts() {
        (window?.contentViewController as? HubViewController)?.showShortcuts()
    }
}

final class HubViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Section: String, CaseIterable {
        case home = "Home"
        case history = "History"
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
    private let dictionaryTextView = NSTextView()
    private let snippetsTextView = NSTextView()
    private let dictionaryField = NSTextField()
    private let snippetPhraseField = NSTextField()
    private let snippetExpansionField = NSTextField()
    private var homeStyleButtons: [TransformStyle: NSButton] = [:]
    private var sectionButtons: [Section: NSButton] = [:]
    private var historyExpandedAll = false
    private var historyQuery = ""
    private var shortcutCaptureAction: ShortcutAction?
    private var shortcutCaptureMonitors: [Any] = []

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 860, height: 620))
        view.wantsLayer = true
        view.layer?.backgroundColor = HubPalette.window.cgColor

        let root = NSStackView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.orientation = .horizontal
        root.alignment = .height
        root.spacing = 0
        view.addSubview(root)

        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.distribution = .fill
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
        for monitor in shortcutCaptureMonitors {
            NSEvent.removeMonitor(monitor)
        }
        appDelegate?.setShortcutCaptureActive(false)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    private func buildSidebar() {
        let brandRow = NSStackView()
        brandRow.orientation = .horizontal
        brandRow.alignment = .centerY
        brandRow.spacing = 9

        let mark = NSImageView(image: WispryIcon.appMark(size: 26))
        mark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 26),
            mark.heightAnchor.constraint(equalToConstant: 26)
        ])
        brandRow.addArrangedSubview(mark)

        let brand = NSTextField(labelWithString: "Wispry")
        brand.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        brand.textColor = HubPalette.signalText
        brandRow.addArrangedSubview(brand)
        sidebar.addArrangedSubview(brandRow)

        let tagline = NSTextField(labelWithString: "voice in, text out")
        tagline.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        tagline.textColor = HubPalette.signalMuted
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
        let sidebarFill = NSView()
        sidebarFill.setContentHuggingPriority(.defaultLow, for: .vertical)
        sidebarFill.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        sidebarFill.heightAnchor.constraint(greaterThanOrEqualToConstant: 1).isActive = true
        sidebar.addArrangedSubview(sidebarFill)
        updateSidebarSelection()
    }

    @objc private func sectionSelected(_ sender: NSButton) {
        let sections = Section.allCases
        guard sender.tag >= 0 && sender.tag < sections.count else { return }
        render(section: sections[sender.tag])
    }

    func showShortcuts() {
        render(section: .shortcuts)
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

        if section != .home {
            titleLabel.stringValue = section.rawValue
            titleLabel.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
            titleLabel.textColor = HubPalette.text
            subtitleLabel.stringValue = subtitle(for: section)
            subtitleLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
            subtitleLabel.textColor = HubPalette.signalMuted
            subtitleLabel.maximumNumberOfLines = 2

            stack.addArrangedSubview(titleLabel)
            stack.addArrangedSubview(subtitleLabel)
        }
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
        case .dictionary:
            return "Words and phrases Wispry should bias recognition toward on the next dictation."
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
        case .dictionary:
            return dictionaryView()
        case .snippets:
            return snippetsView()
        case .shortcuts:
            return shortcutsView()
        }
    }

    private func homeView() -> NSView {
        let start = NSButton(title: "Start dictation", target: self, action: #selector(startDictation))
        stylePrimaryButton(start)
        start.keyEquivalent = "\r"
        let accessibility = NSButton(title: "Accessibility access", target: self, action: #selector(requestAccessibility))
        styleSecondarySignalButton(accessibility)

        let topLine = NSStackView(views: [
            signalTitleLabel("Ready"),
            flexibleSpacer(),
            signalChip(title: store.autoPaste ? "Paste on" : "Clipboard only")
        ])
        topLine.orientation = .horizontal
        topLine.alignment = .centerY
        topLine.spacing = 10
        topLine.widthAnchor.constraint(equalToConstant: 560).isActive = true

        let meter = SignalMeterView()
        meter.translatesAutoresizingMaskIntoConstraints = false
        meter.widthAnchor.constraint(equalToConstant: 560).isActive = true
        meter.heightAnchor.constraint(equalToConstant: 124).isActive = true

        let buttons = NSStackView(views: [start, accessibility, flexibleSpacer()])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.widthAnchor.constraint(equalToConstant: 560).isActive = true

        let autoPaste = signalToggleButton(
            title: store.autoPaste ? "Auto paste on" : "Clipboard only",
            selected: store.autoPaste,
            action: #selector(toggleAutoPasteFromHome)
        )
        let bubble = signalToggleButton(
            title: store.bubbleVisible ? "Bubble visible" : "Bubble hidden",
            selected: store.bubbleVisible,
            action: #selector(toggleBubbleFromHome)
        )
        let toggles = NSStackView(views: [autoPaste, bubble, flexibleSpacer()])
        toggles.orientation = .horizontal
        toggles.alignment = .centerY
        toggles.spacing = 8
        toggles.widthAnchor.constraint(equalToConstant: 560).isActive = true

        let stack = panelStack()
        stack.spacing = 13
        stack.addArrangedSubview(topLine)
        stack.addArrangedSubview(meter)
        stack.addArrangedSubview(buttons)
        stack.addArrangedSubview(permissionChecklist())
        stack.addArrangedSubview(signalSeparator())
        stack.addArrangedSubview(signalStatusLine(label: "Target", value: "Frontmost app"))
        stack.addArrangedSubview(signalControlLine(label: "Cleanup", control: homeStylePicker()))
        stack.addArrangedSubview(signalStatusLine(label: "Shortcuts", value: appDelegate?.shortcutStatusText() ?? "All shortcuts registered"))
        stack.addArrangedSubview(signalStatusLine(label: "Paste", value: appDelegate?.outputStatusText() ?? "No dictation pasted yet."))
        stack.addArrangedSubview(toggles)
        return signalPanel(stack, height: 520)
    }

    private func historyView() -> NSView {
        historySearchField.placeholderString = "Search history"
        historySearchField.target = self
        historySearchField.action = #selector(historySearchChanged)
        styleSignalTextField(historySearchField)
        historySearchField.widthAnchor.constraint(equalToConstant: 560).isActive = true

        historyTable.headerView = nil
        historyTable.dataSource = self
        historyTable.delegate = self
        historyTable.backgroundColor = HubPalette.signalField
        historyTable.usesAlternatingRowBackgroundColors = false
        historyTable.rowHeight = 30
        historyTable.intercellSpacing = NSSize(width: 8, height: 4)
        historyTable.selectionHighlightStyle = .regular
        if historyTable.tableColumns.isEmpty {
            let timeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("time"))
            timeColumn.width = 150
            let summaryColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("summary"))
            summaryColumn.width = 410
            historyTable.addTableColumn(timeColumn)
            historyTable.addTableColumn(summaryColumn)
        }

        let tableScroll = scrollView(document: historyTable, height: 210)
        let detail = scrollableText(historyDetailTextView, height: 130)
        let copy = NSButton(title: "Copy selected", target: self, action: #selector(copySelectedHistory))
        styleSignalSmallButton(copy, width: 112)
        let expand = NSButton(title: "Expand all", target: self, action: #selector(toggleExpandHistory))
        styleSignalSmallButton(expand, width: 98)
        let buttons = NSStackView(views: [copy, expand])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [historySearchField, tableScroll, detail, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        return signalPanel(stack, height: 430)
    }

    private func dictionaryView() -> NSView {
        dictionaryField.placeholderString = "Add name, acronym, product, or technical term"
        dictionaryField.target = self
        dictionaryField.action = #selector(addDictionaryWord)
        styleSignalTextField(dictionaryField)
        let add = NSButton(title: "Add", target: self, action: #selector(addDictionaryWord))
        styleSignalSmallButton(add, width: 72)
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearDictionary))
        styleSignalSmallButton(clear, width: 72)
        let row = NSStackView(views: [dictionaryField, add, clear])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        dictionaryField.widthAnchor.constraint(equalToConstant: 330).isActive = true

        let note = NSTextField(wrappingLabelWithString: "Dictionary terms are sent into Apple Speech as recognition hints when the next recording starts. They improve odds, but they are not hard replacements.")
        note.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        note.textColor = HubPalette.signalMuted
        note.maximumNumberOfLines = 3
        note.widthAnchor.constraint(equalToConstant: 560).isActive = true

        let stack = NSStackView(views: [row, note, scrollableText(dictionaryTextView, height: 280)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        return signalPanel(stack, height: 390)
    }

    private func snippetsView() -> NSView {
        snippetPhraseField.placeholderString = "Spoken phrase"
        snippetExpansionField.placeholderString = "Expansion"
        styleSignalTextField(snippetPhraseField)
        styleSignalTextField(snippetExpansionField)
        let add = NSButton(title: "Add", target: self, action: #selector(addSnippet))
        styleSignalSmallButton(add, width: 68)
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetSnippets))
        styleSignalSmallButton(reset, width: 72)
        let row = NSStackView(views: [snippetPhraseField, snippetExpansionField, add, reset])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        snippetPhraseField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        snippetExpansionField.widthAnchor.constraint(equalToConstant: 246).isActive = true

        let stack = NSStackView(views: [row, scrollableText(snippetsTextView, height: 260)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        return signalPanel(stack, height: 356)
    }

    private func shortcutsView() -> NSView {
        let stack = panelStack()
        for action in ShortcutAction.allCases {
            stack.addArrangedSubview(shortcutRow(for: action))
        }

        let fixed = NSTextField(wrappingLabelWithString: "Fixed while recording: Return commits, Escape cancels. Fn hold is push-to-talk; double-tap Fn latches dictation. Mouse trigger: F13.")
        fixed.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        fixed.textColor = HubPalette.muted
        fixed.maximumNumberOfLines = 3
        fixed.widthAnchor.constraint(equalToConstant: 560).isActive = true
        stack.addArrangedSubview(fixed)
        let status = NSTextField(wrappingLabelWithString: appDelegate?.shortcutStatusText() ?? "All shortcuts registered")
        status.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        status.textColor = (appDelegate?.shortcutStatusText() ?? "").contains("could not register") ? HubPalette.signalRed : HubPalette.muted
        status.maximumNumberOfLines = 3
        status.widthAnchor.constraint(equalToConstant: 560).isActive = true
        stack.addArrangedSubview(status)
        return signalPanel(stack, height: 356)
    }

    private func refresh() {
        historySearchField.stringValue = historyQuery
        updateHomeStyleButtons()
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

    private func signalChip(title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        label.textColor = HubPalette.signalAccent
        label.alignment = .center

        let wrapper = NSView()
        wrapper.wantsLayer = true
        wrapper.layer?.backgroundColor = HubPalette.signalAccent.withAlphaComponent(0.14).cgColor
        wrapper.layer?.cornerRadius = 999
        wrapper.layer?.borderColor = HubPalette.signalAccent.withAlphaComponent(0.22).cgColor
        wrapper.layer?.borderWidth = 1
        wrapper.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 6),
            label.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -10),
            label.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -6)
        ])
        return wrapper
    }

    private func signalTitleLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        label.textColor = HubPalette.signalText
        return label
    }

    private func flexibleSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return spacer
    }

    private func signalStatusLine(label: String, value: String) -> NSView {
        let valueLabel = NSTextField(wrappingLabelWithString: value)
        valueLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        valueLabel.textColor = HubPalette.signalText
        valueLabel.maximumNumberOfLines = 2
        valueLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
        return signalControlLine(label: label, control: valueLabel)
    }

    private func permissionChecklist() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.widthAnchor.constraint(equalToConstant: 560).isActive = true

        stack.addArrangedSubview(permissionRow(
            title: "Microphone",
            status: microphoneStatus.title,
            detail: microphoneStatus.detail,
            ready: microphoneStatus.ready
        ))
        stack.addArrangedSubview(permissionRow(
            title: "Speech",
            status: speechStatus.title,
            detail: speechStatus.detail,
            ready: speechStatus.ready
        ))
        stack.addArrangedSubview(permissionRow(
            title: "Accessibility",
            status: accessibilityStatus.title,
            detail: accessibilityStatus.detail,
            ready: accessibilityStatus.ready
        ))
        return stack
    }

    private func permissionRow(title: String, status: String, detail: String, ready: Bool) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = HubPalette.signalText
        titleLabel.widthAnchor.constraint(equalToConstant: 92).isActive = true

        let chip = NSTextField(labelWithString: status)
        chip.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        chip.textColor = ready ? HubPalette.signalAccent : HubPalette.signalText
        chip.alignment = .center
        let chipWrap = NSView()
        chipWrap.wantsLayer = true
        chipWrap.layer?.backgroundColor = ready
            ? HubPalette.signalAccent.withAlphaComponent(0.12).cgColor
            : HubPalette.signalRed.withAlphaComponent(0.16).cgColor
        chipWrap.layer?.borderColor = ready
            ? HubPalette.signalAccent.withAlphaComponent(0.25).cgColor
            : HubPalette.signalRed.withAlphaComponent(0.35).cgColor
        chipWrap.layer?.borderWidth = 1
        chipWrap.layer?.cornerRadius = 7
        chipWrap.addSubview(chip)
        chip.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            chip.topAnchor.constraint(equalTo: chipWrap.topAnchor, constant: 4),
            chip.leadingAnchor.constraint(equalTo: chipWrap.leadingAnchor, constant: 8),
            chip.trailingAnchor.constraint(equalTo: chipWrap.trailingAnchor, constant: -8),
            chip.bottomAnchor.constraint(equalTo: chipWrap.bottomAnchor, constant: -4),
            chipWrap.widthAnchor.constraint(equalToConstant: 116)
        ])

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = HubPalette.signalMuted
        detailLabel.maximumNumberOfLines = 2
        detailLabel.widthAnchor.constraint(equalToConstant: 320).isActive = true

        let row = NSStackView(views: [titleLabel, chipWrap, detailLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.widthAnchor.constraint(equalToConstant: 560).isActive = true
        return row
    }

    private var microphoneStatus: (title: String, detail: String, ready: Bool) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return ("Ready", "Microphone access is available.", true)
        case .notDetermined:
            return ("First use", "macOS will ask when you start dictation.", true)
        case .denied, .restricted:
            return ("Blocked", "Open System Settings to allow microphone access.", false)
        @unknown default:
            return ("Check", "macOS returned an unknown microphone state.", false)
        }
    }

    private var speechStatus: (title: String, detail: String, ready: Bool) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return ("Ready", "Speech Recognition access is available.", true)
        case .notDetermined:
            return ("First use", "macOS will ask when you start dictation.", true)
        case .denied, .restricted:
            return ("Blocked", "Open System Settings to allow Speech Recognition.", false)
        @unknown default:
            return ("Check", "macOS returned an unknown speech state.", false)
        }
    }

    private var accessibilityStatus: (title: String, detail: String, ready: Bool) {
        if AXIsProcessTrusted() {
            return ("Ready", "Wispry can paste and repolish selected text.", true)
        }
        return ("Needed", "Required for reliable paste and selected-text rewrite.", false)
    }

    private func signalControlLine(label: String, control: NSView) -> NSView {
        let title = NSTextField(labelWithString: label)
        title.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        title.textColor = HubPalette.signalMuted
        title.widthAnchor.constraint(equalToConstant: 92).isActive = true

        let line = NSStackView(views: [title, control, flexibleSpacer()])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 12
        line.widthAnchor.constraint(equalToConstant: 560).isActive = true
        return line
    }

    private func homeStylePicker() -> NSView {
        homeStyleButtons.removeAll()
        let styles: [TransformStyle] = [.clean, .professional, .casual, .list, .verbatim]
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6

        for style in styles {
            let button = NSButton(title: style.rawValue, target: self, action: #selector(homeStyleSelected(_:)))
            button.tag = styles.firstIndex(of: style) ?? 0
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 7
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: style == .professional ? 96 : 62).isActive = true
            homeStyleButtons[style] = button
            row.addArrangedSubview(button)
        }

        updateHomeStyleButtons()
        return row
    }

    private func updateHomeStyleButtons() {
        for (style, button) in homeStyleButtons {
            let selected = store.transformStyle == style
            button.layer?.backgroundColor = selected
                ? HubPalette.signalText.cgColor
                : HubPalette.signalAccent.withAlphaComponent(0.11).cgColor
            button.layer?.borderColor = selected
                ? HubPalette.signalText.cgColor
                : HubPalette.signalBorder.cgColor
            button.layer?.borderWidth = 1
            button.attributedTitle = NSAttributedString(
                string: style.rawValue,
                attributes: [
                    .foregroundColor: selected ? HubPalette.signalSurface : HubPalette.signalText,
                    .font: NSFont.systemFont(ofSize: 12, weight: selected ? .bold : .semibold)
                ]
            )
        }
    }

    private func signalToggleButton(title: String, selected: Bool, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.layer?.backgroundColor = selected
            ? HubPalette.signalAccent.withAlphaComponent(0.16).cgColor
            : NSColor.clear.cgColor
        button.layer?.borderColor = selected
            ? HubPalette.signalAccent.withAlphaComponent(0.28).cgColor
            : HubPalette.signalBorder.cgColor
        button.layer?.borderWidth = 1
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: selected ? HubPalette.signalAccent : HubPalette.signalMuted,
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
            ]
        )
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 112).isActive = true
        return button
    }

    private func signalSeparator() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = HubPalette.signalBorder.cgColor
        line.widthAnchor.constraint(equalToConstant: 560).isActive = true
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func stylePrimaryButton(_ button: NSButton) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = HubPalette.signalText.cgColor
        button.layer?.cornerRadius = 7
        button.attributedTitle = NSAttributedString(
            string: button.title,
            attributes: [
                .foregroundColor: HubPalette.signalSurface,
                .font: NSFont.systemFont(ofSize: 13, weight: .bold)
            ]
        )
        button.heightAnchor.constraint(equalToConstant: 38).isActive = true
        button.widthAnchor.constraint(equalToConstant: 132).isActive = true
    }

    private func styleSecondarySignalButton(_ button: NSButton) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.layer?.borderColor = HubPalette.signalBorder.cgColor
        button.layer?.borderWidth = 1
        button.layer?.cornerRadius = 7
        button.attributedTitle = NSAttributedString(
            string: button.title,
            attributes: [
                .foregroundColor: HubPalette.signalText,
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
            ]
        )
        button.heightAnchor.constraint(equalToConstant: 38).isActive = true
        button.widthAnchor.constraint(equalToConstant: 154).isActive = true
    }

    private func styleSignalSmallButton(_ button: NSButton, width: CGFloat) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.layer?.borderColor = HubPalette.signalBorder.cgColor
        button.layer?.borderWidth = 1
        button.layer?.cornerRadius = 7
        button.attributedTitle = NSAttributedString(
            string: button.title,
            attributes: [
                .foregroundColor: HubPalette.signalText,
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
            ]
        )
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    private func styleSignalTextField(_ field: NSTextField) {
        field.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        field.textColor = HubPalette.signalText
        field.backgroundColor = HubPalette.signalField
        field.drawsBackground = true
        field.bezelStyle = .roundedBezel
        field.wantsLayer = true
        field.layer?.backgroundColor = HubPalette.signalField.cgColor
        field.layer?.borderColor = HubPalette.signalBorder.cgColor
        field.layer?.borderWidth = 1
        field.layer?.cornerRadius = 7
    }

    private func panelStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        return stack
    }

    private func signalPanel(_ content: NSView, height: CGFloat? = nil) -> NSView {
        let wrapper = NSView()
        wrapper.wantsLayer = true
        wrapper.layer?.backgroundColor = HubPalette.signalPanel.cgColor
        wrapper.layer?.cornerRadius = 10
        wrapper.layer?.borderColor = HubPalette.signalBorder.cgColor
        wrapper.layer?.borderWidth = 1
        wrapper.shadow = NSShadow()
        wrapper.shadow?.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.16)
        wrapper.shadow?.shadowBlurRadius = 22
        wrapper.shadow?.shadowOffset = NSSize(width: 0, height: -12)
        content.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 18),
            content.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor, constant: -18),
            content.bottomAnchor.constraint(lessThanOrEqualTo: wrapper.bottomAnchor, constant: -18),
            wrapper.widthAnchor.constraint(equalToConstant: 600)
        ])
        if let height {
            wrapper.heightAnchor.constraint(equalToConstant: height).isActive = true
        }
        return wrapper
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

        let recordTitle = shortcutCaptureAction == action ? "Cancel" : "Record"
        let record = NSButton(title: recordTitle, target: self, action: #selector(recordShortcut(_:)))
        record.tag = ShortcutAction.allCases.firstIndex(of: action) ?? 0
        styleSignalSmallButton(record, width: 72)
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetShortcut(_:)))
        reset.tag = record.tag
        styleSignalSmallButton(reset, width: 64)

        let row = NSStackView(views: [title, shortcut, record, reset])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.widthAnchor.constraint(equalToConstant: 560).isActive = true
        return row
    }

    @objc private func homeStyleSelected(_ sender: NSButton) {
        let styles: [TransformStyle] = [.clean, .professional, .casual, .list, .verbatim]
        guard sender.tag >= 0 && sender.tag < styles.count else { return }
        store.transformStyle = styles[sender.tag]
        updateHomeStyleButtons()
        render(section: .home)
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
        let action = actions[sender.tag]
        if shortcutCaptureAction == action {
            cancelShortcutCapture()
        } else {
            beginShortcutCapture(action)
        }
    }

    @objc private func resetShortcut(_ sender: NSButton) {
        cancelShortcutCapture()
        let actions = ShortcutAction.allCases
        guard sender.tag >= 0 && sender.tag < actions.count else { return }
        let action = actions[sender.tag]
        let defaults = ShortcutSettings.defaults
        store.setShortcut(defaults.shortcut(for: action), for: action)
        appDelegate?.reloadHotKeys()
        render(section: .shortcuts)
    }

    @objc private func toggleAutoPasteFromHome() {
        store.autoPaste.toggle()
        render(section: .home)
    }

    @objc private func toggleBubbleFromHome() {
        store.bubbleVisible.toggle()
        appDelegate?.setBubbleVisible(store.bubbleVisible)
        render(section: .home)
    }

    @objc private func requestAccessibility() {
        appDelegate?.requestAccessibilityPrompt()
    }

    @objc private func startDictation() {
        appDelegate?.toggleDictation()
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
        guard shortcutCaptureMonitors.isEmpty else { return }
        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleShortcutCapture(event) == true ? nil : event
        }
        if let local {
            shortcutCaptureMonitors.append(local)
        }

        let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            _ = self?.handleShortcutCapture(event)
        }
        if let global {
            shortcutCaptureMonitors.append(global)
        }
    }

    private func beginShortcutCapture(_ action: ShortcutAction) {
        shortcutCaptureAction = action
        appDelegate?.setShortcutCaptureActive(true)
        render(section: .shortcuts)
    }

    private func finishShortcutCapture(_ shortcut: KeyShortcut, for action: ShortcutAction) {
        store.setShortcut(shortcut, for: action)
        shortcutCaptureAction = nil
        appDelegate?.setShortcutCaptureActive(false)
        render(section: .shortcuts)
    }

    private func cancelShortcutCapture() {
        guard shortcutCaptureAction != nil else { return }
        shortcutCaptureAction = nil
        appDelegate?.setShortcutCaptureActive(false)
        render(section: .shortcuts)
    }

    private func handleShortcutCapture(_ event: NSEvent) -> Bool {
        guard let action = shortcutCaptureAction else { return false }

        if event.keyCode == UInt16(kVK_Escape) {
            cancelShortcutCapture()
            return true
        }

        guard let shortcut = shortcut(from: event) else {
            NSSound.beep()
            return true
        }

        finishShortcutCapture(shortcut, for: action)
        return true
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

private final class SignalMeterView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        HubPalette.signalField.setFill()
        path.fill()
        HubPalette.signalBorder.setStroke()
        path.lineWidth = 1
        path.stroke()

        drawWash(in: rect)
        drawWave(in: rect)
    }

    private func drawWash(in rect: NSRect) {
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).addClip()

        HubPalette.signalAccent.withAlphaComponent(0.18).setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX - 42, y: rect.minY - 38, width: 190, height: 138)).fill()

        HubPalette.signalRed.withAlphaComponent(0.18).setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.maxX - 176, y: rect.maxY - 122, width: 230, height: 146)).fill()

        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private func drawWave(in rect: NSRect) {
        HubPalette.signalText.setFill()
        let bars: [CGFloat] = [18, 32, 42, 26, 36]
        let barWidth: CGFloat = 6
        let spacing: CGFloat = 6
        let totalWidth = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * spacing
        let startX = rect.midX - totalWidth / 2

        for (index, height) in bars.enumerated() {
            let alpha = 0.42 + CGFloat(index) * 0.10
            HubPalette.signalText.withAlphaComponent(min(alpha, 0.90)).setFill()
            let x = startX + CGFloat(index) * (barWidth + spacing)
            let y = rect.midY - height / 2
            let bar = NSBezierPath(
                roundedRect: NSRect(x: x, y: y, width: barWidth, height: height),
                xRadius: 3,
                yRadius: 3
            )
            bar.fill()
        }
    }
}
