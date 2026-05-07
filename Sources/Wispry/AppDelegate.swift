import AppKit
import ApplicationServices
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SettingsStore.shared
    private let dictationEngine = DictationEngine()
    private let hotKeys = HotKeyManager()

    private var statusItem: NSStatusItem?
    private var bubbleWindow: BubbleWindow?
    private var hubWindowController: HubWindowController?
    private var targetApplication: NSRunningApplication?
    private var lastExternalApplication: NSRunningApplication?
    private var targetAppName = "Active App"
    private var lastTranscript = ""
    private var copyButtonWorkItem: DispatchWorkItem?
    private var isListening = false
    private var isProcessingDictation = false
    private var functionKeyIsDown = false
    private var functionKeyLatched = false
    private var functionReleaseStopWorkItem: DispatchWorkItem?
    private var lastFunctionReleaseDate = Date.distantPast
    private var successResetWorkItem: DispatchWorkItem?
    private var recordingEventTap: CFMachPort?
    private var recordingEventRunLoopSource: CFRunLoopSource?
    private var functionEventTap: CFMachPort?
    private var functionEventRunLoopSource: CFRunLoopSource?
    private let bubbleSize = NSSize(width: 46, height: 46)

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenuBar()
        installBubble()
        installHotKeys()
        installEscapeMonitor()
        installFunctionKeyMonitor()
        installApplicationTracking()
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictationEngine.cancel()
        removeFunctionEventTap()
    }

    func setBubbleVisible(_ visible: Bool) {
        store.bubbleVisible = visible
        visible ? bubbleWindow?.orderFrontRegardless() : bubbleWindow?.orderOut(nil)
    }

    func toggleDictation() {
        if isListening {
            stopDictation()
        } else if !isProcessingDictation {
            startDictation()
        }
    }

    @objc func requestAccessibilityPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func reloadHotKeys() {
        hotKeys.install(shortcuts: store.shortcuts)
    }

    private func installMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Wispry")
        item.button?.imagePosition = .imageOnly
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func installBubble() {
        let defaultFrame: NSRect
        if let screen = NSScreen.main {
            defaultFrame = NSRect(
                x: screen.visibleFrame.maxX - bubbleSize.width - 22,
                y: screen.visibleFrame.midY - bubbleSize.height / 2,
                width: bubbleSize.width,
                height: bubbleSize.height
            )
        } else {
            defaultFrame = NSRect(x: 800, y: 500, width: bubbleSize.width, height: bubbleSize.height)
        }

        let frame = normalizedBubbleFrame(saved: store.bubbleFrame, fallback: defaultFrame)
        store.bubbleFrame = frame
        let window = BubbleWindow(frame: frame)
        window.bubbleView.delegate = self
        bubbleWindow = window
        if store.bubbleVisible {
            window.orderFrontRegardless()
        }
    }

    private func installHotKeys() {
        hotKeys.delegate = self
        reloadHotKeys()
    }

    private func installEscapeMonitor() {
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isListening else { return }
            if event.keyCode == UInt16(kVK_Escape) {
                self.cancelDictation()
            } else if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
                self.stopDictation()
            }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isListening else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.cancelDictation()
                return nil
            }
            if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
                self.stopDictation()
                return nil
            }
            return event
        }
    }

    private func installFunctionKeyMonitor() {
        if installFunctionEventTap() {
            return
        }

        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFunctionModifierChange(event)
        }
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFunctionModifierChange(event)
            return event
        }
    }

    private func handleFunctionModifierChange(_ event: NSEvent) {
        handleFunctionFlagChange(isDown: event.modifierFlags.contains(.function))
    }

    private func handleFunctionFlagChange(isDown: Bool) {
        guard isDown != functionKeyIsDown else { return }

        functionKeyIsDown = isDown
        if isDown {
            functionReleaseStopWorkItem?.cancel()
            if isListening && functionKeyLatched {
                functionKeyLatched = false
                stopDictation()
                return
            }
            let isDoubleTap = Date().timeIntervalSince(lastFunctionReleaseDate) < 0.36
            if isDoubleTap {
                functionKeyLatched = true
                if !isListening && !isProcessingDictation {
                    startDictation()
                }
            } else {
                functionKeyLatched = false
                if !isListening && !isProcessingDictation {
                    startDictation()
                }
            }
        } else {
            lastFunctionReleaseDate = Date()
            guard isListening, !functionKeyLatched else { return }
            let item = DispatchWorkItem { [weak self] in
                guard let self, !self.functionKeyIsDown, self.isListening, !self.functionKeyLatched else { return }
                self.stopDictation()
            }
            functionReleaseStopWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: item)
        }
    }

    private func installFunctionEventTap() -> Bool {
        removeFunctionEventTap()
        guard AXIsProcessTrusted() else { return false }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard type == .flagsChanged, let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let isFunctionKeyEvent = keyCode == UInt16(kVK_Function)
            guard isFunctionKeyEvent else {
                return Unmanaged.passUnretained(event)
            }

            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
            let isDown = event.flags.contains(.maskSecondaryFn)
            DispatchQueue.main.async {
                appDelegate.handleFunctionFlagChange(isDown: isDown)
            }
            return nil
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        functionEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: userInfo
        )

        guard let functionEventTap else { return false }
        functionEventRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, functionEventTap, 0)
        if let functionEventRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), functionEventRunLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: functionEventTap, enable: true)
        return true
    }

    private func installApplicationTracking() {
        lastExternalApplication = currentExternalApplication()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeApplicationChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func activeApplicationChanged(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        if isExternalApplication(application) {
            lastExternalApplication = application
        }
    }

    private func startDictation() {
        guard !isProcessingDictation else { return }
        isProcessingDictation = true
        targetApplication = currentExternalApplication() ?? lastExternalApplication
        targetAppName = targetApplication?.localizedName ?? "Active App"
        setBubbleState(.processing)
        bubbleWindow?.bubbleView.partialTranscript = ""
        bubbleWindow?.bubbleView.showCopyButton = false

        dictationEngine.requestPermissions { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.beginRecording()
            case .failure(let error):
                self.presentError(error.localizedDescription)
            }
        }
    }

    private func beginRecording() {
        do {
            dictationEngine.onPartial = { [weak self] text in
                self?.bubbleWindow?.bubbleView.partialTranscript = text
            }
            dictationEngine.onComplete = { [weak self] result in
                self?.completeDictation(result)
            }
            try dictationEngine.start(contextualStrings: store.dictionaryWords)
            isListening = true
            hotKeys.installRecordingHotKeys()
            installRecordingEventTap()
            setBubbleState(.listening)
        } catch {
            isProcessingDictation = false
            presentError(error.localizedDescription)
        }
    }

    private func stopDictation() {
        guard isListening else { return }
        isListening = false
        hotKeys.uninstallRecordingHotKeys()
        removeRecordingEventTap()
        functionKeyLatched = false
        setBubbleState(.processing)
        dictationEngine.stopAndCommit()
    }

    private func cancelDictation() {
        guard isListening || isProcessingDictation else { return }
        isListening = false
        isProcessingDictation = false
        hotKeys.uninstallRecordingHotKeys()
        removeRecordingEventTap()
        functionKeyLatched = false
        dictationEngine.cancel()
        setBubbleState(.idle)
        bubbleWindow?.bubbleView.partialTranscript = ""
    }

    private func completeDictation(_ result: Result<String, Error>) {
        isListening = false
        isProcessingDictation = false
        hotKeys.uninstallRecordingHotKeys()
        removeRecordingEventTap()
        functionKeyLatched = false

        switch result {
        case .success(let rawText):
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                setBubbleState(.idle)
                return
            }

            let style = store.style(
                for: targetApplication?.bundleIdentifier,
                appName: targetApplication?.localizedName
            )
            let processed = TextPipeline.process(text, style: style, snippets: store.snippets)
            if processed.cancelled || processed.text.isEmpty {
                setBubbleState(.idle)
                return
            }

            lastTranscript = processed.text
            store.addRecent(text: processed.text, appName: targetAppName)
            store.learnLikelyTerms(from: processed.text)
            showSuccessTick()

            if store.autoPaste {
                pasteOrCopy(processed.text, shouldPressEnter: processed.shouldPressEnter)
            } else {
                copyToClipboard(processed.text)
            }

        case .failure(let error):
            presentError(error.localizedDescription)
        }
    }

    private func pasteOrCopy(_ text: String, shouldPressEnter: Bool) {
        copyToClipboard(text)
        let target = targetApplication ?? lastExternalApplication
        target?.activate(options: [.activateIgnoringOtherApps])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
            target?.activate(options: [.activateIgnoringOtherApps])
            if AXIsProcessTrusted() {
                if !self.insertTextIntoFocusedElement(text) {
                    self.sendPasteShortcut(to: target)
                }
            } else {
                self.sendPasteViaSystemEvents(target: target)
            }

            if shouldPressEnter {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                    self.sendKey(UInt16(kVK_Return))
                }
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func repolishSelection(style: TransformStyle) {
        guard AXIsProcessTrusted() else {
            copyToClipboard("Wispry needs Accessibility access before it can repolish selected text. Open Wispry > Accessibility Access from the menu.")
            return
        }

        let target = NSWorkspace.shared.frontmostApplication
        let pasteboard = NSPasteboard.general
        let previousString = pasteboard.string(forType: .string)
        let previousChangeCount = pasteboard.changeCount

        sendKey(UInt16(kVK_ANSI_C), flags: .maskCommand)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            guard pasteboard.changeCount != previousChangeCount,
                  let selectedText = pasteboard.string(forType: .string),
                  !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                if let previousString {
                    pasteboard.clearContents()
                    pasteboard.setString(previousString, forType: .string)
                }
                return
            }

            let processed = TextPipeline.process(selectedText, style: style, snippets: self.store.snippets)
            guard !processed.cancelled, !processed.text.isEmpty else { return }

            self.lastTranscript = processed.text
            self.store.addRecent(text: processed.text, appName: target?.localizedName ?? "Selected Text")
            pasteboard.clearContents()
            pasteboard.setString(processed.text, forType: .string)
            target?.activate(options: [.activateIgnoringOtherApps])

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                if !self.insertTextIntoFocusedElement(processed.text) {
                    self.sendKey(UInt16(kVK_ANSI_V), flags: .maskCommand)
                }
            }
        }
    }

    private func sendPasteShortcut(to target: NSRunningApplication?) {
        sendCommandShortcut(UInt16(kVK_ANSI_V), pid: target?.processIdentifier)
    }

    private func sendPasteViaSystemEvents(target: NSRunningApplication? = nil) {
        let activateLine: String
        if let bundleIdentifier = target?.bundleIdentifier {
            activateLine = "tell application id \"\(bundleIdentifier)\" to activate\n"
        } else {
            activateLine = ""
        }
        let script = "\(activateLine)delay 0.05\ntell application \"System Events\" to keystroke \"v\" using command down"
        var errorInfo: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&errorInfo)
    }

    private func insertTextIntoFocusedElement(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedElement = focusedRef else {
            return false
        }

        let element = focusedElement as! AXUIElement
        if AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success {
            return true
        }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let currentValue = valueRef as? String else {
            return false
        }

        var range = CFRange(location: currentValue.count, length: 0)
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeRef {
            let rangeValue = rangeRef as! AXValue
            AXValueGetValue(rangeValue, .cfRange, &range)
        }

        let nsValue = currentValue as NSString
        guard range.location >= 0, range.location <= nsValue.length, range.length >= 0, range.location + range.length <= nsValue.length else {
            return false
        }

        let nextValue = nsValue.replacingCharacters(in: NSRange(location: range.location, length: range.length), with: text)
        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, nextValue as CFTypeRef) == .success else {
            return false
        }

        var nextRange = CFRange(location: range.location + (text as NSString).length, length: 0)
        if let nextRangeValue = AXValueCreate(.cfRange, &nextRange) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, nextRangeValue)
        }
        return true
    }

    private func installRecordingEventTap() {
        removeRecordingEventTap()
        guard AXIsProcessTrusted() else { return }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard type == .keyDown, let userInfo else { return Unmanaged.passUnretained(event) }
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

            if keyCode == UInt16(kVK_Escape) {
                DispatchQueue.main.async { appDelegate.cancelDictation() }
                return nil
            }
            if keyCode == UInt16(kVK_Return) || keyCode == UInt16(kVK_ANSI_KeypadEnter) {
                DispatchQueue.main.async { appDelegate.stopDictation() }
                return nil
            }

            return Unmanaged.passUnretained(event)
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        recordingEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: userInfo
        )

        guard let recordingEventTap else { return }
        recordingEventRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, recordingEventTap, 0)
        if let recordingEventRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), recordingEventRunLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: recordingEventTap, enable: true)
    }

    private func removeRecordingEventTap() {
        if let recordingEventTap {
            CGEvent.tapEnable(tap: recordingEventTap, enable: false)
            CFMachPortInvalidate(recordingEventTap)
        }
        if let recordingEventRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), recordingEventRunLoopSource, .commonModes)
        }
        recordingEventTap = nil
        recordingEventRunLoopSource = nil
    }

    private func removeFunctionEventTap() {
        if let functionEventTap {
            CGEvent.tapEnable(tap: functionEventTap, enable: false)
            CFMachPortInvalidate(functionEventTap)
        }
        if let functionEventRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), functionEventRunLoopSource, .commonModes)
        }
        functionEventTap = nil
        functionEventRunLoopSource = nil
    }

    private func currentExternalApplication() -> NSRunningApplication? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        return isExternalApplication(application) ? application : nil
    }

    private func isExternalApplication(_ application: NSRunningApplication) -> Bool {
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        if application.bundleIdentifier == Bundle.main.bundleIdentifier { return false }
        return true
    }

    private func normalizedBubbleFrame(saved: NSRect?, fallback: NSRect) -> NSRect {
        var origin = saved?.origin ?? fallback.origin
        let size = bubbleSize

        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(origin) }) ?? NSScreen.main else {
            return NSRect(origin: origin, size: size)
        }

        let frame = screen.visibleFrame
        origin.x = min(max(origin.x, frame.minX + 4), frame.maxX - size.width - 4)
        origin.y = min(max(origin.y, frame.minY + 4), frame.maxY - size.height - 4)
        return NSRect(origin: origin, size: size)
    }

    private func sendKey(_ keyCode: UInt16, flags: CGEventFlags = [], pid: pid_t? = nil) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true)
        down?.flags = flags

        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false)
        up?.flags = flags

        post(down, pid: pid)
        post(up, pid: pid)
    }

    private func sendCommandShortcut(_ keyCode: UInt16, pid: pid_t? = nil) {
        let source = CGEventSource(stateID: .hidSystemState)
        let commandDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: true)
        commandDown?.flags = .maskCommand
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false)
        keyUp?.flags = .maskCommand
        let commandUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: false)

        post(commandDown, pid: pid)
        post(keyDown, pid: pid)
        post(keyUp, pid: pid)
        post(commandUp, pid: pid)
    }

    private func post(_ event: CGEvent?, pid: pid_t?) {
        guard let event else { return }
        if let pid {
            event.postToPid(pid)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }

    private func showCopyButtonTemporarily() {
        copyButtonWorkItem?.cancel()
        bubbleWindow?.bubbleView.showCopyButton = true
        let item = DispatchWorkItem { [weak self] in
            self?.bubbleWindow?.bubbleView.showCopyButton = false
        }
        copyButtonWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }

    private func setBubbleState(_ state: BubbleState) {
        bubbleWindow?.bubbleView.state = state
        updateStatusImage(state)
    }

    private func showSuccessTick() {
        successResetWorkItem?.cancel()
        setBubbleState(.success)
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.bubbleWindow?.bubbleView.state == .success else { return }
            self.setBubbleState(.idle)
        }
        successResetWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: item)
    }

    private func updateStatusImage(_ state: BubbleState) {
        let symbol: String
        switch state {
        case .idle:
            symbol = "waveform.circle"
        case .listening:
            symbol = "mic.circle.fill"
        case .processing:
            symbol = "sparkles"
        case .success:
            symbol = "checkmark.circle.fill"
        case .error:
            symbol = "exclamationmark.circle"
        }
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Wispry")
    }

    private func presentError(_ message: String) {
        isListening = false
        isProcessingDictation = false
        hotKeys.uninstallRecordingHotKeys()
        removeRecordingEventTap()
        functionKeyLatched = false
        setBubbleState(.error)
        bubbleWindow?.bubbleView.partialTranscript = ""

        let alert = NSAlert()
        alert.messageText = "Wispry could not dictate"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()

        setBubbleState(.idle)
    }

    @objc private func menuToggleDictation() {
        toggleDictation()
    }

    @objc private func menuCopyLast() {
        guard !lastTranscript.isEmpty else { return }
        copyToClipboard(lastTranscript)
    }

    @objc private func menuPasteLast() {
        guard !lastTranscript.isEmpty else { return }
        targetApplication = currentExternalApplication() ?? lastExternalApplication
        pasteOrCopy(lastTranscript, shouldPressEnter: false)
    }

    @objc private func menuRepolishProfessional() {
        repolishSelection(style: .professional)
    }

    @objc private func menuRepolishCasual() {
        repolishSelection(style: .casual)
    }

    @objc private func menuRepolishList() {
        repolishSelection(style: .list)
    }

    @objc private func menuRepolishClean() {
        repolishSelection(style: .clean)
    }

    @objc private func menuOpenHub() {
        if hubWindowController == nil {
            hubWindowController = HubWindowController(appDelegate: self)
        }
        hubWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func menuToggleBubble() {
        setBubbleVisible(!store.bubbleVisible)
    }

    @objc private func menuCheckForUpdates() {
        let alert = NSAlert()
        alert.messageText = "Wispry is up to date"
        alert.informativeText = "This local build does not have an update server yet. Rebuild with ./build.sh after code changes."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func menuOpenShortcuts() {
        menuOpenHub()
    }

    @objc private func menuHelp() {
        let alert = NSAlert()
        alert.messageText = "Wispry shortcuts"
        alert.informativeText = "Click bubble: toggle dictation\nHold Fn: push to talk\nDouble-tap Fn: latch dictation\nEscape: cancel\nControl+Option+Space: toggle\nF13: mouse trigger\nOption+2/3/4/5: repolish selected text"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func menuSendFeedback() {
        let subject = "Wispry feedback"
        let urlString = "mailto:?subject=\(subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Wispry%20feedback")"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: BubbleViewDelegate {
    func bubbleDidRequestToggle() {
        toggleDictation()
    }

    func bubbleDidMove(to frame: NSRect) {
        store.bubbleFrame = frame
    }
}

extension AppDelegate: HotKeyManagerDelegate {
    func hotKeyManagerDidPressToggle() {
        toggleDictation()
    }

    func hotKeyManagerDidPressMouseTrigger() {
        toggleDictation()
    }

    func hotKeyManagerDidPressRepolish(style: TransformStyle) {
        repolishSelection(style: style)
    }

    func hotKeyManagerDidPressEscape() {
        cancelDictation()
    }

    func hotKeyManagerDidPressReturn() {
        stopDictation()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(NSMenuItem(title: "Home", action: #selector(menuOpenHub), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Check for Updates", action: #selector(menuCheckForUpdates), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(
            title: isListening ? "Stop and Paste" : "Start Dictation",
            action: #selector(menuToggleDictation),
            keyEquivalent: ""
        ))

        let paste = NSMenuItem(title: "Paste Last Transcript", action: #selector(menuPasteLast), keyEquivalent: "")
        paste.isEnabled = !lastTranscript.isEmpty
        menu.addItem(paste)

        let copy = NSMenuItem(title: "Copy Last Transcript", action: #selector(menuCopyLast), keyEquivalent: "")
        copy.isEnabled = !lastTranscript.isEmpty
        menu.addItem(copy)

        let repolishMenu = NSMenu()
        repolishMenu.addItem(NSMenuItem(title: "Professional", action: #selector(menuRepolishProfessional), keyEquivalent: ""))
        repolishMenu.addItem(NSMenuItem(title: "Casual", action: #selector(menuRepolishCasual), keyEquivalent: ""))
        repolishMenu.addItem(NSMenuItem(title: "List", action: #selector(menuRepolishList), keyEquivalent: ""))
        repolishMenu.addItem(NSMenuItem(title: "Clean", action: #selector(menuRepolishClean), keyEquivalent: ""))
        let repolish = NSMenuItem(title: "Repolish Selection", action: nil, keyEquivalent: "")
        repolish.submenu = repolishMenu
        menu.addItem(repolish)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Shortcuts", action: #selector(menuOpenShortcuts), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Microphone", action: #selector(menuToggleDictation), keyEquivalent: ""))
        menu.addItem(NSMenuItem(
            title: store.bubbleVisible ? "Hide Bubble" : "Show Bubble",
            action: #selector(menuToggleBubble),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(title: "Accessibility Access", action: #selector(requestAccessibilityPrompt), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Help", action: #selector(menuHelp), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Send Support Feedback", action: #selector(menuSendFeedback), keyEquivalent: ""))

        menu.addItem(NSMenuItem.separator())
        let recent = store.recent.prefix(4)
        if recent.isEmpty {
            let empty = NSMenuItem(title: "No recent dictations", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let label = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            label.isEnabled = false
            menu.addItem(label)
            for item in recent {
                let excerpt = item.text.count > 54 ? String(item.text.prefix(54)) + "..." : item.text
                let menuItem = NSMenuItem(title: excerpt, action: nil, keyEquivalent: "")
                menuItem.isEnabled = false
                menu.addItem(menuItem)
            }
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Wispry", action: #selector(menuQuit), keyEquivalent: "q"))
    }
}
