import Carbon
import Foundation

protocol HotKeyManagerDelegate: AnyObject {
    func hotKeyManagerDidPressToggle()
    func hotKeyManagerDidPressMouseTrigger()
    func hotKeyManagerDidPressRepolish(style: TransformStyle)
    func hotKeyManagerDidPressEscape()
}

final class HotKeyManager {
    weak var delegate: HotKeyManagerDelegate?

    private var handlerRef: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private let signature = FourCharCode("WSPY")

    func install() {
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

        register(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), id: 1)
        register(keyCode: UInt32(kVK_F13), modifiers: 0, id: 2)
        register(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(optionKey), id: 3)
        register(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(optionKey), id: 4)
        register(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(optionKey), id: 5)
        register(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(optionKey), id: 6)
        register(keyCode: UInt32(kVK_Escape), modifiers: 0, id: 7)
    }

    private func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) {
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
            hotKeyRefs.append(ref)
        }
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
