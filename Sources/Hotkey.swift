import AppKit
import Carbon.HIToolbox

/// System-wide shortcut via Carbon's RegisterEventHotKey: no Accessibility
/// permission and no event tap, so it costs nothing while idle.
final class GlobalHotkey {
    struct Combo: Equatable {
        var keyCode: UInt32
        var modifiers: NSEvent.ModifierFlags

        var carbonModifiers: UInt32 {
            var m: UInt32 = 0
            if modifiers.contains(.command) { m |= UInt32(cmdKey) }
            if modifiers.contains(.shift) { m |= UInt32(shiftKey) }
            if modifiers.contains(.option) { m |= UInt32(optionKey) }
            if modifiers.contains(.control) { m |= UInt32(controlKey) }
            return m
        }

        var display: String {
            var s = ""
            if modifiers.contains(.control) { s += "⌃" }
            if modifiers.contains(.option) { s += "⌥" }
            if modifiers.contains(.shift) { s += "⇧" }
            if modifiers.contains(.command) { s += "⌘" }
            return s + Self.keyName(keyCode)
        }

        static func keyName(_ code: UInt32) -> String {
            let names: [UInt32: String] = [51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down", 76: "Enter",
                122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"]
            if let name = names[code] { return name }
            switch Int(code) {
            case kVK_Space: return "Space"
            case kVK_Return: return "↩"
            case kVK_Tab: return "⇥"
            case kVK_Escape: return "⎋"
            default:
                let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
                guard let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
                let layout = unsafeBitCast(data, to: CFData.self)
                var dead: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = CFDataGetBytePtr(layout).withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) {
                    UCKeyTranslate($0, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                   OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
                }
                return status == noErr ? String(utf16CodeUnits: chars, count: length).uppercased() : "?"
            }
        }

        /// Persisted as "keyCode:modifierRawValue".
        var stored: String { "\(keyCode):\(modifiers.rawValue)" }
        var menuKey: String {
            let names: [UInt32: UInt32] = [36: 13, 76: 13, 48: 9, 49: 32, 53: 27, 51: 8, 117: 0xf728, 123: 0xf702, 124: 0xf703, 125: 0xf701, 126: 0xf700, 115: 0xf729, 119: 0xf72b, 116: 0xf72c, 121: 0xf72d]
            if let code = names[keyCode], let scalar = UnicodeScalar(code) { return String(scalar) }
            let name = Self.keyName(keyCode)
            if name.hasPrefix("F"), let number = UInt32(name.dropFirst()), (1...20).contains(number), let scalar = UnicodeScalar(0xf704 + number - 1) { return String(scalar) }
            return name.lowercased()
        }

        /// What the recorder in Settings accepts and `sift hotkey set` therefore too: a key with at least one
        /// modifier, and not shift alone (that would swallow ordinary typing).
        var isUsable: Bool { !modifiers.isEmpty && modifiers != .shift }

        init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
            self.keyCode = keyCode
            self.modifiers = modifiers.intersection([.command, .shift, .option, .control])
        }

        init?(stored: String) {
            let parts = stored.split(separator: ":")
            guard parts.count == 2, let k = UInt32(parts[0]), k < 128, let m = UInt(parts[1]), m & ~NSEvent.ModifierFlags([.command,.shift,.option,.control]).rawValue == 0 else { return nil }
            self.init(keyCode: k, modifiers: NSEvent.ModifierFlags(rawValue: m))
        }
    }

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private static var serial: UInt32 = 0
    private let identifier: UInt32
    private(set) var combo: Combo?
    private(set) var rejected = false
    /// The one combination an isolated run may really register: the lifecycle self-test names an obscure one
    /// here for a moment to see Carbon itself accept and refuse a registration. nil everywhere else.
    static var realInIsolatedRun: Combo?

    init(action: @escaping () -> Void) {
        self.action = action
        Self.serial += 1
        identifier = Self.serial
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, user in
            guard let user, let event else { return OSStatus(eventNotHandledErr) }
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(user).takeUnretainedValue()
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x5346_5448, id.id == hotkey.identifier else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { hotkey.action() }
            return noErr
        }, 1, &spec, me, &handler)
    }

    /// Returns false when another app already owns the combination.
    @discardableResult
    func register(_ combo: Combo) -> Bool {
        if self.combo == combo { rejected = false; return true }
        // An isolated run (the lifecycle self-test) never takes a system-wide key: it only notes what was asked for.
        if Lifecycle.isolated, combo != Self.realInIsolatedRun {
            unregister()
            self.combo = combo
            return true
        }
        let id = EventHotKeyID(signature: OSType(0x5346_5448), id: identifier)
        var replacement: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &replacement)
        if status == noErr {
            unregister()
            ref = replacement
            self.combo = combo
            rejected = false
            return true
        }
        rejected = true
        return false
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        combo = nil
        rejected = false
    }
    deinit { unregister(); if let handler { RemoveEventHandler(handler) } }
}
