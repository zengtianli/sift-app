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

        /// What the recorder in Settings accepts and `sift hotkey set` therefore too: a key with at least one
        /// modifier, and not shift alone (that would swallow ordinary typing).
        var isUsable: Bool { !modifiers.isEmpty && modifiers != .shift }

        init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
            self.keyCode = keyCode
            self.modifiers = modifiers.intersection([.command, .shift, .option, .control])
        }

        init?(stored: String) {
            let parts = stored.split(separator: ":")
            guard parts.count == 2, let k = UInt32(parts[0]), let m = UInt(parts[1]) else { return nil }
            self.init(keyCode: k, modifiers: NSEvent.ModifierFlags(rawValue: m))
        }
    }

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private(set) var combo: Combo?
    /// The one combination an isolated run may really register: the lifecycle self-test names an obscure one
    /// here for a moment to see Carbon itself accept and refuse a registration. nil everywhere else.
    static var realInIsolatedRun: Combo?

    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, user in
            guard let user else { return noErr }
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(user).takeUnretainedValue()
            DispatchQueue.main.async { hotkey.action() }
            return noErr
        }, 1, &spec, me, &handler)
    }

    /// Returns false when another app already owns the combination.
    @discardableResult
    func register(_ combo: Combo) -> Bool {
        unregister()
        // An isolated run (the lifecycle self-test) never takes a system-wide key: it only notes what was asked for.
        if Lifecycle.isolated, combo != Self.realInIsolatedRun {
            self.combo = combo
            return true
        }
        let id = EventHotKeyID(signature: OSType(0x5346_5448), id: 1) // 'SFTH'
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            self.combo = combo
            return true
        }
        ref = nil
        self.combo = nil
        return false
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        combo = nil
    }
}
