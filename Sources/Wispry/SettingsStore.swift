import AppKit
import Carbon

enum TransformStyle: String, Codable, CaseIterable {
    case verbatim = "Verbatim"
    case clean = "Clean"
    case professional = "Professional"
    case casual = "Casual"
    case list = "List"
}

enum SpeechModel: String, Codable, CaseIterable {
    case appleOnDevice = "Apple on-device"
    case localWhisper = "Local Whisper"
}

enum StorageMode: String, Codable, CaseIterable {
    case local = "Local"
    case cloud = "Cloud"
}

struct VoiceSnippet: Codable, Equatable {
    var phrase: String
    var expansion: String

    static let defaults: [VoiceSnippet] = [
        VoiceSnippet(phrase: "insert signature", expansion: "Best,\nLuke"),
        VoiceSnippet(phrase: "standup update", expansion: "Yesterday:\n- \n\nToday:\n- \n\nBlocked:\n- None"),
        VoiceSnippet(phrase: "shipping note", expansion: "Implemented, checked locally, and ready for review.")
    ]
}

struct RecentDictation: Codable {
    var date: Date
    var appName: String
    var text: String
}

struct KeyShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String

    static func make(keyCode: UInt32, modifiers: UInt32, display: String) -> KeyShortcut {
        KeyShortcut(keyCode: keyCode, modifiers: modifiers, display: display)
    }
}

struct TriggerShortcut: Codable, Equatable {
    var keyCode: UInt32?
    var modifiers: UInt32
    var display: String
    var isFunctionKey: Bool

    static let function = TriggerShortcut(
        keyCode: nil,
        modifiers: 0,
        display: "Fn",
        isFunctionKey: true
    )

    static func key(_ shortcut: KeyShortcut) -> TriggerShortcut {
        TriggerShortcut(
            keyCode: shortcut.keyCode,
            modifiers: shortcut.modifiers,
            display: shortcut.display,
            isFunctionKey: false
        )
    }

    var keyShortcut: KeyShortcut? {
        guard let keyCode, !isFunctionKey else { return nil }
        return KeyShortcut(keyCode: keyCode, modifiers: modifiers, display: display)
    }
}

enum ShortcutAction: String, Codable, CaseIterable {
    case toggle
    case professional
    case casual
    case list
    case clean

    var title: String {
        switch self {
        case .toggle: return "Hands-free toggle"
        case .professional: return "Professional rewrite"
        case .casual: return "Casual rewrite"
        case .list: return "List rewrite"
        case .clean: return "Clean rewrite"
        }
    }
}

struct ShortcutSettings: Codable, Equatable {
    var toggle: KeyShortcut
    var professional: KeyShortcut
    var casual: KeyShortcut
    var list: KeyShortcut
    var clean: KeyShortcut

    static let defaults = ShortcutSettings(
        toggle: .make(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), display: "Ctrl+Opt+Space"),
        professional: .make(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(optionKey), display: "Opt+2"),
        casual: .make(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(optionKey), display: "Opt+3"),
        list: .make(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(optionKey), display: "Opt+4"),
        clean: .make(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(optionKey), display: "Opt+5")
    )

    func shortcut(for action: ShortcutAction) -> KeyShortcut {
        switch action {
        case .toggle: return toggle
        case .professional: return professional
        case .casual: return casual
        case .list: return list
        case .clean: return clean
        }
    }

    mutating func set(_ shortcut: KeyShortcut, for action: ShortcutAction) {
        switch action {
        case .toggle: toggle = shortcut
        case .professional: professional = shortcut
        case .casual: casual = shortcut
        case .list: list = shortcut
        case .clean: clean = shortcut
        }
    }
}

final class SettingsStore {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard
    private let dictionaryKey = "dictionaryWords"
    private let snippetsKey = "voiceSnippets"
    private let recentKey = "recentDictations"
    private let styleKey = "transformStyle"
    private let bubbleFrameKey = "bubbleFrame"
    private let bubbleVisibleKey = "bubbleVisible"
    private let autoPasteKey = "autoPaste"
    private let shortcutsKey = "shortcuts"
    private let holdTriggerKey = "holdTrigger"
    private let pressTriggerKey = "pressTrigger"
    private let speechModelKey = "speechModel"
    private let speechLanguageKey = "speechLanguage"
    private let microphoneUniqueIDKey = "microphoneUniqueID"
    private let cleanupEnabledKey = "cleanupEnabled"
    private let storageModeKey = "storageMode"
    private let licenseKeyKey = "licenseKey"
    private let lastAutomaticUpdateCheckKey = "lastAutomaticUpdateCheckAt"
    private let lastPromptedUpdateKey = "lastPromptedUpdateIdentifier"

    private init() {
        if defaults.object(forKey: snippetsKey) == nil {
            snippets = VoiceSnippet.defaults
        }
        if defaults.object(forKey: styleKey) == nil {
            transformStyle = .clean
        }
        if defaults.object(forKey: bubbleVisibleKey) == nil {
            bubbleVisible = true
        }
        if defaults.object(forKey: autoPasteKey) == nil {
            autoPaste = true
        }
        if defaults.object(forKey: shortcutsKey) == nil {
            shortcuts = .defaults
        }
        if defaults.object(forKey: holdTriggerKey) == nil {
            holdTrigger = .function
        }
        if defaults.object(forKey: pressTriggerKey) == nil {
            pressTrigger = .key(.make(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), display: "Ctrl+Opt+Space"))
        }
        if defaults.object(forKey: speechModelKey) == nil {
            speechModel = Self.defaultSpeechModel(languageIdentifier: Locale.current.identifier)
        }
        if defaults.object(forKey: speechLanguageKey) == nil {
            speechLanguageIdentifier = Locale.current.identifier
        }
        if defaults.object(forKey: cleanupEnabledKey) == nil {
            cleanupEnabled = true
        }
        if defaults.object(forKey: storageModeKey) == nil {
            storageMode = .local
        }
    }

    var dictionaryWords: [String] {
        get { defaults.stringArray(forKey: dictionaryKey) ?? [] }
        set {
            let cleaned = newValue
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            defaults.set(Array(NSOrderedSet(array: cleaned)) as? [String] ?? cleaned, forKey: dictionaryKey)
        }
    }

    var snippets: [VoiceSnippet] {
        get { decode([VoiceSnippet].self, key: snippetsKey) ?? [] }
        set { encode(newValue, key: snippetsKey) }
    }

    var recent: [RecentDictation] {
        get { decode([RecentDictation].self, key: recentKey) ?? [] }
        set { encode(Array(newValue.prefix(30)), key: recentKey) }
    }

    var transformStyle: TransformStyle {
        get {
            guard let raw = defaults.string(forKey: styleKey) else { return .clean }
            return TransformStyle(rawValue: raw) ?? .clean
        }
        set { defaults.set(newValue.rawValue, forKey: styleKey) }
    }

    var bubbleVisible: Bool {
        get { defaults.bool(forKey: bubbleVisibleKey) }
        set { defaults.set(newValue, forKey: bubbleVisibleKey) }
    }

    var autoPaste: Bool {
        get { defaults.bool(forKey: autoPasteKey) }
        set { defaults.set(newValue, forKey: autoPasteKey) }
    }

    var bubbleFrame: NSRect? {
        get {
            guard let raw = defaults.string(forKey: bubbleFrameKey) else { return nil }
            let rect = NSRectFromString(raw)
            return rect == .zero ? nil : rect
        }
        set {
            if let newValue {
                defaults.set(NSStringFromRect(newValue), forKey: bubbleFrameKey)
            } else {
                defaults.removeObject(forKey: bubbleFrameKey)
            }
        }
    }

    var shortcuts: ShortcutSettings {
        get { decode(ShortcutSettings.self, key: shortcutsKey) ?? .defaults }
        set { encode(newValue, key: shortcutsKey) }
    }

    var holdTrigger: TriggerShortcut {
        get { decode(TriggerShortcut.self, key: holdTriggerKey) ?? .function }
        set { encode(newValue, key: holdTriggerKey) }
    }

    var pressTrigger: TriggerShortcut {
        get {
            decode(TriggerShortcut.self, key: pressTriggerKey)
                ?? .key(.make(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), display: "Ctrl+Opt+Space"))
        }
        set { encode(newValue, key: pressTriggerKey) }
    }

    var speechModel: SpeechModel {
        get {
            guard let raw = defaults.string(forKey: speechModelKey) else {
                return Self.defaultSpeechModel(languageIdentifier: speechLanguageIdentifier)
            }
            return SpeechModel(rawValue: raw) ?? .appleOnDevice
        }
        set { defaults.set(newValue.rawValue, forKey: speechModelKey) }
    }

    var speechLanguageIdentifier: String {
        get { defaults.string(forKey: speechLanguageKey) ?? Locale.current.identifier }
        set { defaults.set(newValue, forKey: speechLanguageKey) }
    }

    var microphoneUniqueID: String? {
        get { defaults.string(forKey: microphoneUniqueIDKey) }
        set {
            if let newValue, !newValue.isEmpty {
                defaults.set(newValue, forKey: microphoneUniqueIDKey)
            } else {
                defaults.removeObject(forKey: microphoneUniqueIDKey)
            }
        }
    }

    var cleanupEnabled: Bool {
        get { defaults.bool(forKey: cleanupEnabledKey) }
        set { defaults.set(newValue, forKey: cleanupEnabledKey) }
    }

    var storageMode: StorageMode {
        get {
            guard let raw = defaults.string(forKey: storageModeKey) else { return .local }
            return StorageMode(rawValue: raw) ?? .local
        }
        set { defaults.set(newValue.rawValue, forKey: storageModeKey) }
    }

    var licenseKey: String? {
        get { defaults.string(forKey: licenseKeyKey) }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                defaults.set(trimmed, forKey: licenseKeyKey)
            } else {
                defaults.removeObject(forKey: licenseKeyKey)
            }
        }
    }

    var lastAutomaticUpdateCheckAt: Date? {
        get { defaults.object(forKey: lastAutomaticUpdateCheckKey) as? Date }
        set {
            if let newValue {
                defaults.set(newValue, forKey: lastAutomaticUpdateCheckKey)
            } else {
                defaults.removeObject(forKey: lastAutomaticUpdateCheckKey)
            }
        }
    }

    var lastPromptedUpdateIdentifier: String? {
        get { defaults.string(forKey: lastPromptedUpdateKey) }
        set {
            if let newValue, !newValue.isEmpty {
                defaults.set(newValue, forKey: lastPromptedUpdateKey)
            } else {
                defaults.removeObject(forKey: lastPromptedUpdateKey)
            }
        }
    }

    func setShortcut(_ shortcut: KeyShortcut, for action: ShortcutAction) {
        var settings = shortcuts
        settings.set(shortcut, for: action)
        shortcuts = settings
    }

    func addRecent(text: String, appName: String) {
        let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else { return }

        var items = recent
        let now = Date()
        if let first = items.first,
           first.appName == appName,
           first.text == cleanedText,
           now.timeIntervalSince(first.date) < 15 {
            items[0] = RecentDictation(date: now, appName: appName, text: cleanedText)
            recent = items
            return
        }

        items.insert(RecentDictation(date: now, appName: appName, text: cleanedText), at: 0)
        recent = items
    }

    func learnLikelyTerms(from text: String) {
        let candidates = text
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" })
            .map(String.init)
            .filter { word in
                word.count > 2 && word.rangeOfCharacter(from: .uppercaseLetters) != nil
            }

        guard !candidates.isEmpty else { return }
        dictionaryWords = dictionaryWords + candidates
    }

    func style(for bundleIdentifier: String?, appName: String?) -> TransformStyle {
        let haystack = [bundleIdentifier, appName]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        if haystack.contains("mail") || haystack.contains("outlook") || haystack.contains("gmail") {
            return .professional
        }
        if haystack.contains("messages") || haystack.contains("slack") || haystack.contains("discord") {
            return .casual
        }
        return transformStyle
    }

    private func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func encode<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func defaultSpeechModel(languageIdentifier: String) -> SpeechModel {
        localWhisperIsAvailable(languageIdentifier: languageIdentifier) ? .localWhisper : .appleOnDevice
    }

    private static func localWhisperIsAvailable(languageIdentifier: String) -> Bool {
        let executableCandidates = [
            "/opt/homebrew/bin/whisper-server",
            "/usr/local/bin/whisper-server",
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            "\(NSHomeDirectory())/.local/bin/whisper"
        ]
        guard executableCandidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return false
        }

        let cacheDirectory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cache/whisper.cpp", isDirectory: true)
        let languageCode = Locale(identifier: languageIdentifier).language.languageCode?.identifier
        let modelCandidates = languageCode == "en"
            ? ["ggml-base.en.bin", "ggml-tiny.en.bin", "ggml-base.bin", "ggml-tiny.bin"]
            : ["ggml-base.bin", "ggml-tiny.bin"]
        return modelCandidates
            .map { cacheDirectory.appendingPathComponent($0).path }
            .contains(where: { FileManager.default.fileExists(atPath: $0) })
    }
}
