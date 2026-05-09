import AppKit
import ApplicationServices
import Carbon
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SettingsStore.shared
    private let dictationEngine = DictationEngine()
    private let hotKeys = HotKeyManager()

    private var statusItem: NSStatusItem?
    private var bubbleWindow: BubbleWindow?
    private var hubWindowController: HubWindowController?
    private var targetApplication: NSRunningApplication?
    private var targetTextSnapshot: FocusedTextSnapshot?
    private var menuOpenTextSnapshot: FocusedTextSnapshot?
    private var menuOpenTargetApplication: NSRunningApplication?
    private var lastExternalApplication: NSRunningApplication?
    private var targetAppName = "Active App"
    private var lastTranscript = ""
    private var currentPartialTranscript = ""
    private var lastOutputStatus = "No dictation pasted yet."
    private var copyButtonWorkItem: DispatchWorkItem?
    private var hasRequestedAccessibilityThisSession = false
    private var hasRequestedPostEventThisSession = false
    private var isShortcutCaptureActive = false
    private var isListening = false
    private var isProcessingDictation = false
    private var hasCompletedCurrentDictation = false
    private var functionKeyIsDown = false
    private var holdTriggerKeyIsDown = false
    private var pressTriggerKeyIsDown = false
    private var functionKeyLatched = false
    private var functionReleaseStopWorkItem: DispatchWorkItem?
    private var pendingFunctionReleaseStop = false
    private var lastFunctionReleaseDate = Date.distantPast
    private var ignoreNextFunctionRelease = false
    private var successResetWorkItem: DispatchWorkItem?
    private var dictationCompletionWatchdog: DispatchWorkItem?
    private var recordingEventTap: CFMachPort?
    private var recordingEventRunLoopSource: CFRunLoopSource?
    private var functionEventTap: CFMachPort?
    private var functionEventRunLoopSource: CFRunLoopSource?
    private let bubbleSize = NSSize(width: 46, height: 46)

    private enum PasteOutcome {
        case keyboardConfirmed
        case accessibilityInserted
        case keyboardSent
        case clipboardOnly
        case accessibilityRequired
        case inputControlRequired
        case noTarget

        func message(targetName: String) -> String {
            switch self {
            case .keyboardConfirmed:
                return "Pasted into \(targetName)."
            case .accessibilityInserted:
                return "Inserted into \(targetName) with Accessibility fallback."
            case .keyboardSent:
                return "Paste shortcut sent to \(targetName)."
            case .clipboardOnly:
                return "Copied to clipboard."
            case .accessibilityRequired:
                return "Copied. Accessibility is not trusted for this build; re-add TypeLocal if it is already enabled."
            case .inputControlRequired:
                return "Copied. Allow TypeLocal to control your computer so it can paste automatically."
            case .noTarget:
                return "Copied to clipboard. No target app was available to paste into."
            }
        }
    }

    private struct FocusedTextSnapshot {
        let element: AXUIElement
        let value: String
        let selectedRange: CFRange?
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenuBar()
        installBubble()
        installHotKeys()
        installEscapeMonitor()
        installFunctionKeyMonitor()
        installApplicationTracking()
        logDiagnostic(
            "launch bundle=\(Bundle.main.bundleIdentifier ?? "unknown") path=\(Bundle.main.bundlePath) axTrusted=\(AXIsProcessTrusted()) postEvent=\(CGPreflightPostEventAccess()) frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.requestAccessibilityPromptIfNeeded()
        }
        scheduleLaunchSelfTestIfRequested()
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictationEngine.shutdown()
        removeRecordingEventTap()
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
        showAccessibilityPrompt(force: true)
    }

    private func requestAccessibilityPromptIfNeeded() {
        showAccessibilityPrompt(force: false)
    }

    private func showAccessibilityPrompt(force: Bool) {
        guard force || !hasRequestedAccessibilityThisSession else { return }
        guard !AXIsProcessTrusted() else { return }
        hasRequestedAccessibilityThisSession = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func requestPostEventAccessIfNeeded() -> Bool {
        if CGPreflightPostEventAccess() {
            return true
        }
        guard !hasRequestedPostEventThisSession else {
            return false
        }
        hasRequestedPostEventThisSession = true
        return CGRequestPostEventAccess()
    }

    private func scheduleLaunchSelfTestIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let text = environment["WISPRY_SELF_TEST_PASTE_TEXT"],
              !text.isEmpty else {
            return
        }

        let shouldQuit = environment["WISPRY_SELF_TEST_QUIT_AFTER"] == "1"
        logDiagnostic(
            "self-test requested chars=\(text.count) quitAfter=\(shouldQuit) frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")"
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.runLaunchSelfTestPaste(text, shouldQuitAfter: shouldQuit)
        }
    }

    private func runLaunchSelfTestPaste(_ text: String, shouldQuitAfter: Bool) {
        let snapshot = focusedTextSnapshot()
        targetApplication = preferredDictationTarget(snapshot: snapshot)
        logDiagnostic(
            "self-test start target=\(targetApplication?.localizedName ?? "none") snapshot=\(snapshot != nil) frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")"
        )
        pasteOrCopy(text, shouldPressEnter: false, preferredSnapshot: snapshot)

        guard shouldQuitAfter else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            NSApp.terminate(nil)
        }
    }

    func reloadHotKeys() {
        guard !isShortcutCaptureActive else {
            hotKeys.uninstallHotKeys()
            return
        }
        hotKeys.install(shortcuts: store.shortcuts, pressTrigger: store.pressTrigger)
    }

    func setShortcutCaptureActive(_ active: Bool) {
        guard isShortcutCaptureActive != active else { return }
        isShortcutCaptureActive = active
        if active {
            hotKeys.uninstallHotKeys()
            logDiagnostic("shortcut capture started; global hotkeys disabled")
        } else {
            logDiagnostic("shortcut capture ended; global hotkeys reloading")
            reloadHotKeys()
        }
    }

    func outputStatusText() -> String {
        lastOutputStatus
    }

    func shortcutStatusText() -> String {
        hotKeys.registrationFailures.isEmpty
            ? "All shortcuts registered"
            : hotKeys.registrationFailures.joined(separator: " ")
    }

    func copyTextFromHub(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastTranscript = trimmed
        copyToClipboard(trimmed)
        lastOutputStatus = "Copied history item to clipboard."
        showSuccessTick()
    }

    func pasteTextFromHub(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastTranscript = trimmed
        targetApplication = currentExternalApplication() ?? lastExternalApplication
        pasteOrCopy(trimmed, shouldPressEnter: false, preferredSnapshot: nil)
    }

    private func installMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = WispryIcon.statusImage(for: .idle)
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "TypeLocal"
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
        let tapInstalled = installFunctionEventTap()
        logDiagnostic("function monitor installed eventTap=\(tapInstalled)")

        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFunctionModifierChange(event)
        }
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFunctionModifierChange(event)
            return event
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handleTriggerKeyEvent(
                keyCode: UInt32(event.keyCode),
                modifiers: self?.carbonModifiers(from: event.modifierFlags) ?? 0,
                isDown: event.type == .keyDown
            )
        }
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handleTriggerKeyEvent(
                keyCode: UInt32(event.keyCode),
                modifiers: self?.carbonModifiers(from: event.modifierFlags) ?? 0,
                isDown: event.type == .keyDown
            )
            return event
        }
    }

    private func handleFunctionModifierChange(_ event: NSEvent) {
        handleFunctionFlagChange(isDown: event.modifierFlags.contains(.function))
    }

    private func handleFunctionFlagChange(isDown: Bool) {
        guard isDown != functionKeyIsDown else { return }

        functionKeyIsDown = isDown
        guard !isShortcutCaptureActive else { return }
        logDiagnostic("fn \(isDown ? "down" : "up") listening=\(isListening) processing=\(isProcessingDictation) latched=\(functionKeyLatched)")
        if store.holdTrigger.isFunctionKey {
            handleHoldTriggerChange(isDown: isDown)
            return
        }

        if store.pressTrigger.isFunctionKey && isDown {
            toggleDictation()
        }
    }

    private func handleTriggerKeyEvent(keyCode: UInt32, modifiers: UInt32, isDown: Bool) {
        guard !isShortcutCaptureActive else { return }

        if matches(trigger: store.holdTrigger, keyCode: keyCode, modifiers: modifiers) || (holdTriggerKeyIsDown && store.holdTrigger.keyCode == keyCode) {
            guard holdTriggerKeyIsDown != isDown else { return }
            holdTriggerKeyIsDown = isDown
            handleHoldTriggerChange(isDown: isDown)
            return
        }

        if !isDown, store.pressTrigger.keyCode == keyCode {
            pressTriggerKeyIsDown = false
        }
    }

    private func matches(trigger: TriggerShortcut, keyCode: UInt32, modifiers: UInt32) -> Bool {
        guard !trigger.isFunctionKey, trigger.keyCode == keyCode else { return false }
        return trigger.modifiers == modifiers
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private func carbonModifiers(from flags: CGEventFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.maskCommand) { result |= UInt32(cmdKey) }
        if flags.contains(.maskAlternate) { result |= UInt32(optionKey) }
        if flags.contains(.maskControl) { result |= UInt32(controlKey) }
        if flags.contains(.maskShift) { result |= UInt32(shiftKey) }
        return result
    }

    private func handleHoldTriggerChange(isDown: Bool) {
        if isDown {
            functionReleaseStopWorkItem?.cancel()
            pendingFunctionReleaseStop = false
            if functionKeyLatched && isListening {
                ignoreNextFunctionRelease = true
                stopDictation()
            } else if isListening && Date().timeIntervalSince(lastFunctionReleaseDate) < 0.40 {
                functionKeyLatched = true
                lastOutputStatus = "Fn latched. Press Fn again to stop and paste."
                setBubbleState(.listening)
            } else if !isListening && !isProcessingDictation {
                startDictation()
            }
        } else {
            lastFunctionReleaseDate = Date()
            if ignoreNextFunctionRelease {
                ignoreNextFunctionRelease = false
                return
            }
            if functionKeyLatched {
                return
            }
            if isListening {
                scheduleFunctionReleaseStop(after: 0.34)
            } else if isProcessingDictation {
                pendingFunctionReleaseStop = true
            }
        }
    }

    private func scheduleFunctionReleaseStop(after delay: TimeInterval) {
        functionReleaseStopWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.functionKeyIsDown, self.isListening else { return }
            self.stopDictation()
        }
        functionReleaseStopWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func installFunctionEventTap() -> Bool {
        removeFunctionEventTap()
        guard AXIsProcessTrusted() else { return false }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async {
                switch type {
                case .flagsChanged:
                    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                    guard keyCode == UInt16(kVK_Function) else { return }
                    appDelegate.handleFunctionFlagChange(isDown: event.flags.contains(.maskSecondaryFn))
                case .keyDown, .keyUp:
                    appDelegate.handleTriggerKeyEvent(
                        keyCode: UInt32(event.getIntegerValueField(.keyboardEventKeycode)),
                        modifiers: appDelegate.carbonModifiers(from: event.flags),
                        isDown: type == .keyDown
                    )
                default:
                    break
                }
            }
            return Unmanaged.passUnretained(event)
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
        hasCompletedCurrentDictation = false
        targetTextSnapshot = focusedTextSnapshot()
        currentPartialTranscript = ""
        dictationCompletionWatchdog?.cancel()
        targetApplication = preferredDictationTarget(snapshot: targetTextSnapshot)
        targetAppName = targetApplication?.localizedName ?? "Active App"
        logDiagnostic(
            "record start requested target=\(targetAppName) bundle=\(targetApplication?.bundleIdentifier ?? "unknown") startSnapshot=\(targetTextSnapshot != nil) frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")"
        )
        lastOutputStatus = "Preparing to listen in \(targetAppName)."
        setBubbleState(.processing)
        bubbleWindow?.bubbleView.partialTranscript = ""
        bubbleWindow?.bubbleView.showCopyButton = false

        dictationEngine.requestPermissions(model: store.speechModel) { [weak self] result in
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
                guard let self else { return }
                self.currentPartialTranscript = text
                self.bubbleWindow?.bubbleView.partialTranscript = text
            }
            dictationEngine.onComplete = { [weak self] result in
                self?.completeDictation(result)
            }
            try dictationEngine.start(
                model: store.speechModel,
                contextualStrings: store.dictionaryWords,
                languageIdentifier: store.speechLanguageIdentifier,
                microphoneUniqueID: store.microphoneUniqueID
            )
            isListening = true
            hotKeys.installRecordingHotKeys()
            installRecordingEventTap()
            lastOutputStatus = "Listening for \(targetAppName)."
            setBubbleState(.listening)
            FeedbackSound.shared.playStart()
            if pendingFunctionReleaseStop && !functionKeyLatched {
                pendingFunctionReleaseStop = false
                scheduleFunctionReleaseStop(after: 0.08)
            }
        } catch {
            isProcessingDictation = false
            presentError(error.localizedDescription)
        }
    }

    private func stopDictation() {
        guard isListening else { return }
        logDiagnostic("record stop requested target=\(targetAppName)")
        isListening = false
        hotKeys.uninstallRecordingHotKeys()
        removeRecordingEventTap()
        functionKeyLatched = false
        ignoreNextFunctionRelease = false
        pendingFunctionReleaseStop = false
        setBubbleState(.processing)
        FeedbackSound.shared.playStop()
        dictationEngine.stopAndCommit()
        if !dictationEngine.usesDelayedExternalTranscription {
            installDictationCompletionWatchdog()
        }
    }

    private func cancelDictation() {
        guard isListening || isProcessingDictation else { return }
        isListening = false
        isProcessingDictation = false
        hasCompletedCurrentDictation = true
        hotKeys.uninstallRecordingHotKeys()
        removeRecordingEventTap()
        functionKeyLatched = false
        ignoreNextFunctionRelease = false
        pendingFunctionReleaseStop = false
        targetTextSnapshot = nil
        currentPartialTranscript = ""
        dictationCompletionWatchdog?.cancel()
        dictationEngine.cancel()
        setBubbleState(.idle)
        FeedbackSound.shared.playCancel()
        bubbleWindow?.bubbleView.partialTranscript = ""
    }

    private func completeDictation(_ result: Result<String, Error>) {
        guard !hasCompletedCurrentDictation else {
            logDiagnostic("record duplicate completion ignored target=\(targetAppName)")
            return
        }
        hasCompletedCurrentDictation = true
        dictationCompletionWatchdog?.cancel()
        isListening = false
        isProcessingDictation = false
        hotKeys.uninstallRecordingHotKeys()
        removeRecordingEventTap()
        functionKeyLatched = false
        ignoreNextFunctionRelease = false
        pendingFunctionReleaseStop = false

        let finalResult: Result<String, Error>
        switch result {
        case .success(let rawText):
            finalResult = .success(rawText)
        case .failure(let error):
            let fallback = currentPartialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            logDiagnostic("record failure error=\(error.localizedDescription) partialChars=\(fallback.count)")
            if fallback.isEmpty {
                targetTextSnapshot = nil
                currentPartialTranscript = ""
                presentError(error.localizedDescription)
                return
            }
            finalResult = .success(fallback)
        }

        switch finalResult {
        case .success(let rawText):
            let text = (rawText.isEmpty ? currentPartialTranscript : rawText).trimmingCharacters(in: .whitespacesAndNewlines)
            logDiagnostic("record complete chars=\(text.count) autoPaste=\(store.autoPaste) target=\(targetAppName)")
            guard !text.isEmpty else {
                lastOutputStatus = "Nothing was captured."
                targetTextSnapshot = nil
                currentPartialTranscript = ""
                setBubbleState(.idle)
                return
            }

            let style = store.cleanupEnabled
                ? store.style(
                    for: targetApplication?.bundleIdentifier,
                    appName: targetApplication?.localizedName
                )
                : .verbatim
            let processed = TextPipeline.process(text, style: style, snippets: store.snippets)
            if processed.cancelled || processed.text.isEmpty {
                lastOutputStatus = "Dictation cancelled."
                targetTextSnapshot = nil
                setBubbleState(.idle)
                return
            }

            lastTranscript = processed.text
            currentPartialTranscript = ""
            store.addRecent(text: processed.text, appName: targetAppName)
            store.learnLikelyTerms(from: processed.text)
            let startSnapshot = targetTextSnapshot
            targetTextSnapshot = nil

            if store.autoPaste {
                pasteOrCopy(processed.text, shouldPressEnter: processed.shouldPressEnter, preferredSnapshot: startSnapshot)
            } else {
                copyToClipboard(processed.text)
                lastOutputStatus = "Copied to clipboard. Auto paste is off."
                showSuccessTick()
            }
        case .failure(let error):
            presentError(error.localizedDescription)
        }
    }

    private func installDictationCompletionWatchdog() {
        dictationCompletionWatchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isProcessingDictation, !self.isListening else { return }
            let fallback = self.currentPartialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            self.logDiagnostic("record watchdog fired partialChars=\(fallback.count) target=\(self.targetAppName)")
            self.completeDictation(.success(fallback))
        }
        dictationCompletionWatchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2, execute: item)
    }

    private func pasteOrCopy(_ text: String, shouldPressEnter: Bool, preferredSnapshot: FocusedTextSnapshot? = nil) {
        copyToClipboard(text)
        let target = resolvedPasteTarget()
        let targetName = target?.localizedName ?? "the target app"
        targetApplication = target

        guard let target else {
            lastOutputStatus = PasteOutcome.noTarget.message(targetName: targetName)
            logDiagnostic("paste no-target chars=\(text.count)")
            return
        }

        lastOutputStatus = "Copied. Returning focus to \(targetName)."
        logDiagnostic(
            "paste start target=\(targetName) bundle=\(target.bundleIdentifier ?? "unknown") pid=\(target.processIdentifier) chars=\(text.count) axTrusted=\(AXIsProcessTrusted()) frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")"
        )
        let usableSnapshot = preferredSnapshot.flatMap { snapshot -> FocusedTextSnapshot? in
            guard let owner = applicationOwning(snapshot.element),
                  owner.processIdentifier == target.processIdentifier else {
                return nil
            }
            return snapshot
        }
        activateTarget(target) {
            self.deliverPaste(text, to: target, preferredSnapshot: usableSnapshot) { outcome in
                self.lastOutputStatus = outcome.message(targetName: targetName)
                self.logDiagnostic("paste outcome=\(outcome) target=\(targetName) pid=\(target.processIdentifier)")
                self.applyPasteOutcomeState(outcome)

                if shouldPressEnter {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        self.sendKey(UInt16(kVK_Return), pid: target.processIdentifier)
                    }
                }
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func applyPasteOutcomeState(_ outcome: PasteOutcome) {
        switch outcome {
        case .keyboardConfirmed, .accessibilityInserted, .keyboardSent:
            showSuccessTick()
        case .accessibilityRequired, .inputControlRequired, .clipboardOnly, .noTarget:
            setBubbleState(.error)
            showCopyButtonTemporarily()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
                guard let self, self.bubbleWindow?.bubbleView.state == .error else { return }
                self.setBubbleState(.idle)
            }
        }
    }

    private func logDiagnostic(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        NSLog("TypeLocal %@", message)

        do {
            let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library")
                .appendingPathComponent("Logs")
            try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            let logURL = logsDirectory.appendingPathComponent("TypeLocal.log")

            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                try handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
                try handle.close()
            } else {
                try line.write(to: logURL, atomically: true, encoding: .utf8)
            }
        } catch {
            NSLog("TypeLocal could not write diagnostics: %@", error.localizedDescription)
        }
    }

    private func repolishSelection(style: TransformStyle) {
        guard AXIsProcessTrusted() else {
            lastOutputStatus = "Repolish needs Accessibility access before TypeLocal can read selected text."
            requestAccessibilityPromptIfNeeded()
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
                self.lastOutputStatus = "No selected text found to repolish."
                return
            }

            let processed = TextPipeline.process(selectedText, style: style, snippets: self.store.snippets)
            guard !processed.cancelled, !processed.text.isEmpty else { return }

            self.lastTranscript = processed.text
            self.store.addRecent(text: processed.text, appName: target?.localizedName ?? "Selected Text")
            pasteboard.clearContents()
            pasteboard.setString(processed.text, forType: .string)
            target?.activate(options: [])

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                if !self.insertTextIntoFocusedElement(processed.text) {
                    self.sendKey(UInt16(kVK_ANSI_V), flags: .maskCommand)
                    self.lastOutputStatus = "Repolished text pasted with clipboard fallback."
                } else {
                    self.lastOutputStatus = "Repolished selected text in place."
                }
            }
        }
    }

    private func resolvedPasteTarget() -> NSRunningApplication? {
        for application in [currentExternalApplication(), targetApplication, lastExternalApplication] {
            guard let application, !application.isTerminated, isExternalApplication(application) else {
                continue
            }
            return application
        }
        return nil
    }

    private func preferredDictationTarget(snapshot: FocusedTextSnapshot?) -> NSRunningApplication? {
        if let snapshot,
           let focusedOwner = applicationOwning(snapshot.element),
           isExternalApplication(focusedOwner) {
            return focusedOwner
        }
        if let focusedOwner = focusedElementOwnerApplication(),
           isExternalApplication(focusedOwner) {
            return focusedOwner
        }
        return currentExternalApplication() ?? lastExternalApplication
    }

    private func activateTarget(_ target: NSRunningApplication?, attempts: Int = 7, completion: @escaping () -> Void) {
        guard let target, !target.isTerminated else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: completion)
            return
        }

        target.activate(options: [])

        func retry(_ remaining: Int) {
            if frontmostApplicationMatches(target) || remaining <= 0 {
                logDiagnostic(
                    "paste activation target=\(target.localizedName ?? "unknown") matched=\(frontmostApplicationMatches(target)) remaining=\(remaining) frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")"
                )
                completion()
                return
            }

            target.activate(options: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                retry(remaining - 1)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            retry(attempts)
        }
    }

    private func deliverPaste(
        _ text: String,
        to target: NSRunningApplication,
        preferredSnapshot: FocusedTextSnapshot?,
        completion: @escaping (PasteOutcome) -> Void
    ) {
        let isAccessibilityTrusted = AXIsProcessTrusted()
        let hasPostEventAccess = requestPostEventAccessIfNeeded()
        if !isAccessibilityTrusted {
            requestAccessibilityPrompt()
            logDiagnostic("paste axTrusted=false; attempting keyboard fallback anyway")
        }

        let canInspectFocusedText = frontmostApplicationMatches(target)
        let snapshot = preferredSnapshot ?? (isAccessibilityTrusted && canInspectFocusedText ? focusedTextSnapshot() : nil)
        logDiagnostic("paste deliver axTrusted=\(isAccessibilityTrusted) postEvent=\(hasPostEventAccess) canInspect=\(canInspectFocusedText) startSnapshot=\(preferredSnapshot != nil) snapshot=\(snapshot != nil)")

        let sentShortcut = hasPostEventAccess && sendPasteShortcut(to: target)
        logDiagnostic("paste shortcutSent=\(sentShortcut) pid=\(target.processIdentifier)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
            if let snapshot,
               let afterValue = self.focusedTextValue(for: snapshot.element) {
                if self.valueReflectsInsertedText(before: snapshot, after: afterValue, inserted: text) {
                    completion(.keyboardConfirmed)
                    return
                }
            }

            if sentShortcut {
                completion(isAccessibilityTrusted ? .keyboardSent : .accessibilityRequired)
            } else if let snapshot, self.insertText(text, into: snapshot) {
                if let afterValue = self.focusedTextValue(for: snapshot.element),
                   self.valueReflectsInsertedText(before: snapshot, after: afterValue, inserted: text) {
                    self.logDiagnostic("paste directInsert=verified")
                    completion(.accessibilityInserted)
                } else {
                    self.logDiagnostic("paste directInsert=unverified")
                    completion(.clipboardOnly)
                }
            } else if !hasPostEventAccess {
                completion(.inputControlRequired)
            } else {
                completion(.clipboardOnly)
            }
        }
    }

    @discardableResult
    private func sendPasteShortcut(to target: NSRunningApplication?) -> Bool {
        target?.activate(options: [])
        return sendCommandShortcut(UInt16(kVK_ANSI_V))
    }

    private func insertTextIntoFocusedElement(_ text: String) -> Bool {
        guard let snapshot = focusedTextSnapshot() else {
            return false
        }
        return insertText(text, into: snapshot)
    }

    private func insertText(_ text: String, into snapshot: FocusedTextSnapshot) -> Bool {
        let currentValue = focusedTextValue(for: snapshot.element) ?? snapshot.value
        let nsValue = currentValue as NSString
        let range = selectedTextRange(for: snapshot.element)
            ?? snapshot.selectedRange
            ?? CFRange(location: nsValue.length, length: 0)

        guard range.location >= 0,
              range.location <= nsValue.length,
              range.length >= 0,
              range.location + range.length <= nsValue.length else {
            return false
        }

        let nextValue = nsValue.replacingCharacters(
            in: NSRange(location: range.location, length: range.length),
            with: text
        )
        guard AXUIElementSetAttributeValue(snapshot.element, kAXValueAttribute as CFString, nextValue as CFTypeRef) == .success else {
            return false
        }

        var nextRange = CFRange(location: range.location + (text as NSString).length, length: 0)
        if let nextRangeValue = AXValueCreate(.cfRange, &nextRange) {
            AXUIElementSetAttributeValue(snapshot.element, kAXSelectedTextRangeAttribute as CFString, nextRangeValue)
        }
        return true
    }

    private func focusedTextSnapshot() -> FocusedTextSnapshot? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedElement = focusedRef else {
            return nil
        }

        guard CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = focusedElement as! AXUIElement
        guard let value = focusedTextValue(for: element) else {
            return nil
        }

        return FocusedTextSnapshot(
            element: element,
            value: value,
            selectedRange: selectedTextRange(for: element)
        )
    }

    private func focusedElementOwnerApplication() -> NSRunningApplication? {
        guard AXIsProcessTrusted() else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedElement = focusedRef,
              CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
            return nil
        }

        return applicationOwning(focusedElement as! AXUIElement)
    }

    private func applicationOwning(_ element: AXUIElement) -> NSRunningApplication? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid > 0 else {
            return nil
        }

        return NSRunningApplication(processIdentifier: pid)
    }

    private func focusedTextValue(for element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let currentValue = valueRef as? String else {
            return nil
        }
        return currentValue
    }

    private func selectedTextRange(for element: AXUIElement) -> CFRange? {
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeRef {
            guard CFGetTypeID(rangeRef) == AXValueGetTypeID() else {
                return nil
            }
            let rangeValue = rangeRef as! AXValue
            var range = CFRange(location: 0, length: 0)
            AXValueGetValue(rangeValue, .cfRange, &range)
            return range
        }
        return nil
    }

    private func valueReflectsInsertedText(before snapshot: FocusedTextSnapshot, after afterValue: String, inserted text: String) -> Bool {
        guard afterValue != snapshot.value else {
            return false
        }

        if let range = snapshot.selectedRange {
            let nsValue = snapshot.value as NSString
            if range.location >= 0,
               range.location <= nsValue.length,
               range.length >= 0,
               range.location + range.length <= nsValue.length {
                let expected = nsValue.replacingCharacters(
                    in: NSRange(location: range.location, length: range.length),
                    with: text
                )
                if afterValue == expected {
                    return true
                }
            }
        }

        return afterValue.contains(text)
    }

    private func frontmostApplicationMatches(_ target: NSRunningApplication?) -> Bool {
        guard let target else { return true }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
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

    @discardableResult
    private func sendKey(_ keyCode: UInt16, flags: CGEventFlags = [], pid: pid_t? = nil) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false) else {
            return false
        }
        down.flags = flags
        up.flags = flags

        post(down, pid: pid)
        usleep(12_000)
        post(up, pid: pid)
        return true
    }

    @discardableResult
    private func sendCommandShortcut(_ keyCode: UInt16, pid: pid_t? = nil) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let commandDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: true),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: false) else {
            return false
        }
        commandDown.flags = .maskCommand
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        post(commandDown, pid: pid)
        usleep(12_000)
        post(keyDown, pid: pid)
        usleep(12_000)
        post(keyUp, pid: pid)
        usleep(12_000)
        post(commandUp, pid: pid)
        return true
    }

    private func post(_ event: CGEvent, pid: pid_t?) {
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
        statusItem?.button?.image = WispryIcon.statusImage(for: state)
    }

    private func presentError(_ message: String) {
        logDiagnostic("present error=\(message)")
        isListening = false
        isProcessingDictation = false
        hasCompletedCurrentDictation = true
        hotKeys.uninstallRecordingHotKeys()
        removeRecordingEventTap()
        functionKeyLatched = false
        ignoreNextFunctionRelease = false
        pendingFunctionReleaseStop = false
        targetTextSnapshot = nil
        currentPartialTranscript = ""
        dictationCompletionWatchdog?.cancel()
        setBubbleState(.error)
        bubbleWindow?.bubbleView.partialTranscript = ""
        lastOutputStatus = message

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.setBubbleState(.idle)
        }
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
        let snapshot = menuOpenTextSnapshot
        targetApplication = menuOpenTargetApplication ?? preferredDictationTarget(snapshot: snapshot)
        pasteOrCopy(lastTranscript, shouldPressEnter: false, preferredSnapshot: snapshot)
    }

    @objc private func menuPasteRecent(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String, !text.isEmpty else { return }
        lastTranscript = text
        let snapshot = menuOpenTextSnapshot
        targetApplication = menuOpenTargetApplication ?? preferredDictationTarget(snapshot: snapshot)
        pasteOrCopy(text, shouldPressEnter: false, preferredSnapshot: snapshot)
    }

    @objc private func menuTestAutoPaste() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let text = "TypeLocal auto paste test \(formatter.string(from: Date()))"
        lastTranscript = text
        let snapshot = menuOpenTextSnapshot
        targetApplication = menuOpenTargetApplication ?? preferredDictationTarget(snapshot: snapshot)
        pasteOrCopy(text, shouldPressEnter: false, preferredSnapshot: snapshot)
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
        alert.messageText = "TypeLocal local beta"
        alert.informativeText = "Version 0.1.0 is packaged by ./build.sh. Signed, notarized updates should be added before paid release."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func menuOpenShortcuts() {
        if hubWindowController == nil {
            hubWindowController = HubWindowController(appDelegate: self)
        }
        hubWindowController?.showWindow(nil)
        hubWindowController?.showShortcuts()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func menuHelp() {
        let alert = NSAlert()
        alert.messageText = "TypeLocal triggers"
        alert.informativeText = "Hold trigger: record while held, release to paste\nPress trigger: press once to start, press again to stop\nEscape: cancel\nReturn: stop and paste"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func menuSendFeedback() {
        let subject = "TypeLocal feedback"
        let urlString = "mailto:lukebyrnee97@gmail.com?subject=\(subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "TypeLocal%20feedback")"
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
    func menuWillOpen(_ menu: NSMenu) {
        menuOpenTextSnapshot = focusedTextSnapshot()
        menuOpenTargetApplication = preferredDictationTarget(snapshot: menuOpenTextSnapshot)
        logDiagnostic(
            "menu open target=\(menuOpenTargetApplication?.localizedName ?? "none") snapshot=\(menuOpenTextSnapshot != nil) frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")"
        )
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpenTextSnapshot = nil
        menuOpenTargetApplication = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menuOpenTextSnapshot == nil && menuOpenTargetApplication == nil {
            menuOpenTextSnapshot = focusedTextSnapshot()
            menuOpenTargetApplication = preferredDictationTarget(snapshot: menuOpenTextSnapshot)
        }

        menu.removeAllItems()

        menu.addItem(NSMenuItem(title: "Home", action: #selector(menuOpenHub), keyEquivalent: ""))
        menu.addItem(NSMenuItem(
            title: store.bubbleVisible ? "Hide Bubble" : "Show Bubble",
            action: #selector(menuToggleBubble),
            keyEquivalent: ""
        ))

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
                let menuItem = NSMenuItem(title: excerpt, action: #selector(menuPasteRecent(_:)), keyEquivalent: "")
                menuItem.representedObject = item.text
                menu.addItem(menuItem)
            }
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit TypeLocal", action: #selector(menuQuit), keyEquivalent: "q"))
    }
}
