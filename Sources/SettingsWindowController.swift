import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// Records a shortcut: click, then press the combination (Esc cancels).
final class HotkeyRecorder: NSButton {
    var combo: GlobalHotkey.Combo? { didSet { refresh() } }
    var onChange: ((GlobalHotkey.Combo?) -> Void)?
    private var monitor: Any?

    override init(frame: NSRect) {
        super.init(frame: frame)
        bezelStyle = .rounded
        target = self
        action = #selector(startRecording)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        title = monitor != nil ? "Press shortcut…" : (combo?.display ?? "Not set")
    }

    @objc private func startRecording() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.stop(); return nil } // Esc
            let combo = GlobalHotkey.Combo(keyCode: UInt32(event.keyCode), modifiers: event.modifierFlags)
            guard combo.isUsable else { NSSound.beep(); return nil }
            self.stop()
            self.combo = combo
            self.onChange?(combo)
            return nil
        }
        refresh()
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        refresh()
    }
}

final class SettingsWindowController: NSWindowController {
    private let engine: Engine
    private let hotkey: GlobalHotkey
    private let recorder = HotkeyRecorder()
    private let hotkeyNote = NSTextField(labelWithString: "")
    private let rootField = NSTextField()
    private let ignoreText = NSTextView()
    private let includeText = NSTextView()
    private let loginCheck = NSButton(checkboxWithTitle: "Open Sift at login", target: nil, action: nil)
    private let message = NSTextField(labelWithString: "")

    init(engine: Engine, hotkey: GlobalHotkey) {
        self.engine = engine
        self.hotkey = hotkey
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "Sift Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        load()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Offscreen render for docs (`--snapshot out.png --settings`); never shown.
    func writeSnapshot(to url: URL) throws {
        load()
        guard let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// `--ui-self-test`: loads the fields as `present()` does, without showing the window.
    func stateForTesting() -> (root: String, ignore: [String], recorderTitle: String, recorderInWindow: Bool) {
        load()
        window?.contentView?.layoutSubtreeIfNeeded()
        let ignore = ignoreText.string.split(whereSeparator: \.isNewline).map(String.init)
        return (rootField.stringValue, ignore, recorder.title, recorder.window === window && !recorder.isHidden)
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        return l
    }

    private func note(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func textArea(_ view: NSTextView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        scroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        return scroll
    }

    private func build() {
        guard let content = window?.contentView else { return }
        recorder.onChange = { [weak self] combo in self?.applyHotkey(combo) }
        loginCheck.target = self
        loginCheck.action = #selector(toggleLogin)
        rootField.placeholderString = "/"
        message.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: 11)

        let save = NSButton(title: "Save & Re-index", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let access = NSButton(title: "Full Disk Access…", target: self, action: #selector(openAccess))

        let clear = NSButton(title: "Clear", target: self, action: #selector(clearHotkey))
        let cardinal = NSButton(title: "Use ⇧⌘Space (as in Cardinal)", target: self, action: #selector(useCardinalHotkey))
        let hotkeyRow = NSStackView(views: [label("Show/hide Sift from any app"), recorder, clear, hotkeyNote])
        hotkeyRow.spacing = 10
        let rootRow = NSStackView(views: [label("Index root"), rootField])
        rootRow.spacing = 10
        let buttons = NSStackView(views: [access, NSView(), message, save])
        buttons.spacing = 10

        let stack = NSStackView(views: [
            hotkeyRow, cardinal,
            note("Off by default so Sift never takes a shortcut another app uses. Click the button and press a combination to turn it on."),
            loginCheck,
            rootRow,
            label("Skip these folders (one per line, ~ allowed)"), textArea(ignoreText),
            label("But still include (inside skipped folders)"), textArea(includeText),
            note("Skipping caches, logs and temporary folders keeps the index small and quiet. Changing these re-indexes from scratch."),
            buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        for v in stack.arrangedSubviews where v is NSScrollView || v === buttons || v === rootRow {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
        ])
    }

    /// The shortcut row and the login checkbox as they are right now. Also called when `sift hotkey …` or
    /// `sift login-item …` changed them while this window is open (AppActions); the index fields, which the owner
    /// may be editing, are left alone.
    func showSystemSettings() {
        let shortcut = HotkeySetting.state(hotkey)
        recorder.combo = shortcut.stored
        hotkeyNote.stringValue = shortcut.inUse ? HotkeySetting.inUseNote : ""
        hotkeyNote.textColor = .systemOrange
        loginCheck.state = LoginItem.enabled ? .on : .off
    }

    /// `--lifecycle-self-test`: what the shortcut row and the checkbox show, without reloading them first.
    var systemSettingsForTesting: (recorderTitle: String, note: String, loginChecked: Bool) {
        (recorder.title, hotkeyNote.stringValue, loginCheck.state == .on)
    }

    private func load() {
        showSystemSettings()
        message.stringValue = ""
        guard let data = engine.settingsJSON(),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        rootField.stringValue = json["root"] as? String ?? "/"
        let home = NSHomeDirectory()
        let lines = { (key: String) -> String in
            ((json[key] as? [String]) ?? [])
                .filter { $0 != "/System/Volumes/Data" }
                .map { $0.hasPrefix(home + "/") ? "~" + $0.dropFirst(home.count) : $0 }
                .joined(separator: "\n")
        }
        ignoreText.string = lines("ignore_paths")
        includeText.string = lines("include_paths")
    }

    @objc private func useCardinalHotkey() {
        recorder.combo = HotkeySetting.cardinal
        applyHotkey(HotkeySetting.cardinal)
    }

    @objc private func clearHotkey() {
        recorder.combo = nil
        applyHotkey(nil)
    }

    private func applyHotkey(_ combo: GlobalHotkey.Combo?) {
        hotkeyNote.stringValue = HotkeySetting.apply(combo, to: hotkey).inUse ? HotkeySetting.inUseNote : ""
    }

    @objc private func toggleLogin() {
        do {
            try LoginItem.set(loginCheck.state == .on)
        } catch {
            message.stringValue = error.localizedDescription
            loginCheck.state = LoginItem.enabled ? .on : .off
        }
    }

    @objc private func openAccess() { Permissions.openFullDiskAccessSettings() }

    @objc private func save() {
        let split = { (text: String) -> [String] in
            text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        let root = rootField.stringValue.trimmingCharacters(in: .whitespaces)
        let payload: [String: Any] = [
            "root": root.isEmpty ? "/" : root,
            "ignore_paths": split(ignoreText.string),
            "include_paths": split(includeText.string),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        if let error = engine.updateSettings(data) {
            message.stringValue = error
            message.textColor = .systemRed
        } else {
            Prefs.didSaveIndexSettings?()
            message.stringValue = "Saved. Re-indexing in the background."
            message.textColor = .secondaryLabelColor
            load()
        }
    }
}

enum AppSettings {
    /// nil (the default) means no system-wide shortcut is registered.
    static var hotkey: GlobalHotkey.Combo? {
        get {
            UserDefaults.standard.string(forKey: "hotkey").flatMap(GlobalHotkey.Combo.init(stored:))
        }
        set {
            if let newValue { Prefs.set(newValue.stored, forKey: "hotkey") } else { Prefs.remove("hotkey") }
        }
    }
}
