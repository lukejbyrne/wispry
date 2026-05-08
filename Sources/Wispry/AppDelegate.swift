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
    private var functionKeyIsDown = false
    private var functionKeyLatched = false
    private var functionReleaseStopWorkItem: DispatchWorkItem?
    private var pendingFunctionReleaseStop = false
    private var lastFunctionReleaseDate = Date.distantPast
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
                return "Copied. Accessibility is not trusted for this build; re-add Wispry if it is already enabled."
            case .inputControlRequired:
                return "Copied. Allow Wispry to control your computer so it can paste automatically."
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictationEngine.cancel()
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

    func reloadHotKeys() {
        guard !isShortcutCaptureActive else {
            hotKeys.uninstallHotKeys()
            return
        }
        hotKeys.install(shortcuts: store.shortcuts)
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

    private func installMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = WispryIcon.statusImage(for: .idle)
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Wispry"
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
    }

    private func handleFunctionModifierChange(_ event: NSEvent) {
        handleFunctionFlagChange(isDown: event.modifierFlags.contains(.function))
    }

    private func handleFunctionFlagChange(isDown: Bool) {
        guard isDown != functionKeyIsDown else { return }

        functionKeyIsDown = isDown
        logDiagnostic("fn \(isDown ? "down" : "up") listening=\(isListening) processing=\(isProcessingDictation) latched=\(functionKeyLatched)")
        if isDown {
            functionReleaseStopWorkItem?.cancel()
            pendingFunctionReleaseStop = false

            let isDoubleTap = Date().timeIntervalSince(lastFunctionReleaseDate) < 0.42

            if isListening {
                if functionKeyLatched {
                    functionKeyLatched = false
                    stopDictation()
                } else if isDoubleTap {
                    functionKeyLatched = true
                    logDiagnostic("fn latch enabled while listening")
                }
                return
            }

            if isProcessingDictation {
                if isDoubleTap {
                    functionKeyLatched = true
                    logDiagnostic("fn latch pending while starting")
                }
                return
            }

            functionKeyLatched = isDoubleTap
            if functionKeyLatched {
                logDiagnostic("fn latch start")
            }
            if !isProcessingDictation {
                startDictation()
            }
        } else {
            lastFunctionReleaseDate = Date()
            if isListening && !functionKeyLatched {
                scheduleFunctionReleaseStop(after: 0.28)
            } else if isProcessingDictation && !functionKeyLatched {
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
                guard let self else { return }
                self.currentPartialTranscript = text
                self.bubbleWindow?.bubbleView.partialTranscript = text
            }
            dictationEngine.onComplete = { [weak self] result in
                self?.completeDictation(result)
            }
            try dictationEngine.start(contextualStrings: store.dictionaryWords)
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
        pendingFunctionReleaseStop = false
        setBubbleState(.processing)
        FeedbackSound.shared.playStop()
        dictationEngine.stopAndCommit()
        installDictationCompletionWatchdog()
    }

    private func cancelDictation() {
        guard isListening || isProcessingDictation else { return }
        isListening = false
        isProcessingDictation = false
        hotKeys.uninstallRecordingHotKeys()
        removeRecordingEventTap()
        functionKeyLatched = false
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
        dictationCompletionWatchdog?.cancel()
        isListening = false
        isProcessingDictation = false
        hotKeys.uninstallRecordingHotKeys()
        removeRecordingEventTap()
        functionKeyLatched = false
        pendingFunctionReleaseStop = false

        switch result {
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

            let style = store.style(
                for: targetApplication?.bundleIdentifier,
                appName: targetApplication?.localizedName
            )
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
            let fallback = currentPartialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            logDiagnostic("record failure error=\(error.localizedDescription) partialChars=\(fallback.count)")
            if !fallback.isEmpty {
                completeDictation(.success(fallback))
            } else {
                targetTextSnapshot = nil
                currentPartialTranscript = ""
                presentError(error.localizedDescription)
            }
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
        activateTarget(target) {
            self.deliverPaste(text, to: target, preferredSnapshot: preferredSnapshot) { outcome in
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
        NSLog("Wispry %@", message)

        do {
            let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library")
                .appendingPathComponent("Logs")
            try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            let logURL = logsDirectory.appendingPathComponent("Wispry.log")

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
            NSLog("Wispry could not write diagnostics: %@", error.localizedDescription)
        }
    }

    private func repolishSelection(style: TransformStyle) {
        guard AXIsProcessTrusted() else {
            lastOutputStatus = "Repolish needs Accessibility access before Wispry can read selected text."
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
        for application in [targetApplication, currentExternalApplication(), lastExternalApplication] {
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
        hotKeys.uninstallRecordingHotKeys()
        removeRecordingEventTap()
        functionKeyLatched = false
        pendingFunctionReleaseStop = false
        targetTextSnapshot = nil
        currentPartialTranscript = ""
        dictationCompletionWatchdog?.cancel()
        setBubbleState(.error)
        bubbleWindow?.bubbleView.partialTranscript = ""
        lastOutputStatus = message

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
        let snapshot = menuOpenTextSnapshot
        targetApplication = menuOpenTargetApplication ?? preferredDictationTarget(snapshot: snapshot)
        pasteOrCopy(lastTranscript, shouldPressEnter: false, preferredSnapshot: snapshot)
    }

    @objc private func menuTestAutoPaste() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let text = "Wispry auto paste test \(formatter.string(from: Date()))"
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
        alert.messageText = "Wispry local beta"
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
        alert.messageText = "Wispry shortcuts"
        alert.informativeText = "Click bubble: toggle dictation\nHold Fn: push to talk\nDouble-tap Fn: latch dictation\nRelease Fn: stop and paste\nEscape: cancel\nControl+Option+Space: toggle\nF13: mouse trigger\nOption+2/3/4/5: repolish selected text"
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
        menu.addItem(NSMenuItem(title: "Build Info", action: #selector(menuCheckForUpdates), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(
            title: isListening ? "Stop and Paste" : "Start Dictation",
            action: #selector(menuToggleDictation),
            keyEquivalent: ""
        ))

        let paste = NSMenuItem(title: "Paste Last Transcript", action: #selector(menuPasteLast), keyEquivalent: "")
        paste.isEnabled = !lastTranscript.isEmpty
        menu.addItem(paste)

        menu.addItem(NSMenuItem(title: "Test Auto Paste", action: #selector(menuTestAutoPaste), keyEquivalent: ""))

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
