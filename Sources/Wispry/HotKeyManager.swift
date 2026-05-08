import Carbon
import Foundation

protocol HotKeyManagerDelegate: AnyObject {
    func hotKeyManagerDidPressToggle()
    func hotKeyManagerDidPressMouseTrigger()
    func hotKeyManagerDidPressRepolish(style: TransformStyle)
    func hotKeyManagerDidPressEscape()
    func hotKeyManagerDidPressReturn()
}

final class HotKeyManager {
    weak var delegate: HotKeyManagerDelegate?

    private var handlerRef: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var recordingHotKeyRefs: [EventHotKeyRef?] = []
    private let signature = FourCharCode("WSPY")
    private(set) var registrationFailures: [String] = []

    func install(shortcuts: ShortcutSettings) {
        uninstallHotKeys()
        registrationFailures.removeAll()
        ensureHandler()
        register(shortcut: shortcuts.toggle, id: 1, label: "Toggle dictation")
        register(keyCode: UInt32(kVK_F13), modifiers: 0, id: 2, label: "Mouse trigger")
        register(shortcut: shortcuts.professional, id: 3, label: "Professional rewrite")
        register(shortcut: shortcuts.casual, id: 4, label: "Casual rewrite")
        register(shortcut: shortcuts.list, id: 5, label: "List rewrite")
        register(shortcut: shortcuts.clean, id: 6, label: "Clean rewrite")
    }

    private func ensureHandler() {
        guard handlerRef == nil else { return }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                switch hotKeyID.id {
                case 1:
                    DispatchQueue.main.async { manager.delegate?.hotKeyManagerDidPressToggle() }
                case 2:
                    DispatchQueue.main.async { manager.delegate?.hotKeyManagerDidPressMouseTrigger() }
                case 3:
                    DispatchQueue.main.async { manager.delegate?.hotKeyManagerDidPressRepolish(style: .professional) }
                case 4:
                    DispatchQueue.main.async { manager.delegate?.hotKeyManagerDidPressRepolish(style: .casual) }
                case 5:
                    DispatchQueue.main.async { manager.delegate?.hotKeyManagerDidPressRepolish(style: .list) }
                case 6:
                    DispatchQueue.main.async { manager.delegate?.hotKeyManagerDidPressRepolish(style: .clean) }
                case 7:
                    DispatchQueue.main.async { manager.delegate?.hotKeyManagerDidPressEscape() }
                case 8, 9:
                    DispatchQueue.main.async { manager.delegate?.hotKeyManagerDidPressReturn() }
                default:
                    break
                }
                return noErr
            },
            1,
            &eventSpec,
            selfPointer,
            &handlerRef
        )
    }

    func uninstallHotKeys() {
        for ref in hotKeyRefs {
            if let ref {
                UnregisterEventHotKey(ref)
            }
        }
        hotKeyRefs.removeAll()
    }

    func installRecordingHotKeys() {
        uninstallRecordingHotKeys()
        register(keyCode: UInt32(kVK_Escape), modifiers: 0, id: 7, label: "Cancel recording", recordingOnly: true)
        register(keyCode: UInt32(kVK_Return), modifiers: 0, id: 8, label: "Commit recording", recordingOnly: true)
        register(keyCode: UInt32(kVK_ANSI_KeypadEnter), modifiers: 0, id: 9, label: "Commit recording", recordingOnly: true)
    }

    func uninstallRecordingHotKeys() {
        for ref in recordingHotKeyRefs {
            if let ref {
                UnregisterEventHotKey(ref)
            }
        }
        recordingHotKeyRefs.removeAll()
    }

    private func register(keyCode: UInt32, modifiers: UInt32, id: UInt32, label: String, recordingOnly: Bool = false) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            if recordingOnly {
                recordingHotKeyRefs.append(ref)
            } else {
                hotKeyRefs.append(ref)
            }
        } else if !recordingOnly {
            registrationFailures.append("\(label) could not register. Choose a different shortcut.")
        }
    }

    private func register(shortcut: KeyShortcut, id: UInt32, label: String) {
        register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, id: id, label: label)
    }
}

private extension FourCharCode {
    init(_ string: String) {
        var result: UInt32 = 0
        for scalar in string.unicodeScalars.prefix(4) {
            result = (result << 8) + scalar.value
        }
        self = result
    }
}
