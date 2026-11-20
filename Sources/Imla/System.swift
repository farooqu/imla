import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ImlaCore

/// Global hotkeys through Carbon, which needs no Accessibility permission and
/// reports both press and release (for hold-to-talk).
///
/// Carbon hotkeys fire on the Mac the keyboard is attached to, even while
/// Universal Control is sending the keyboard to another Mac, and swallow the
/// keys so that Mac never sees them. Universal Control becomes the frontmost
/// app while it has the pointer, so the hotkeys are released for that time:
/// the keys then go through to the other Mac, where its own Imla picks them up.
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var hotkeys: [UInt32: Hotkey] = [:]
    private var actions: [UInt32: (pressed: () -> Void, released: () -> Void)] = [:]
    private var suspended = false

    private init() {
        NotificationCenter.default.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                               object: NSWorkspace.shared, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            HotkeyCenter.shared.setSuspended(app?.bundleIdentifier == "com.apple.universalcontrol")
        }
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async {
                guard let action = HotkeyCenter.shared.actions[id.id] else { return }
                pressed ? action.pressed() : action.released()
            }
            return noErr
        }, specs.count, &specs, nil, nil)
    }

    @discardableResult
    func register(_ id: UInt32, _ hotkey: Hotkey, pressed: @escaping () -> Void, released: @escaping () -> Void = {}) -> Bool {
        unregister(id)
        guard suspended || install(id, hotkey) else { return false }
        hotkeys[id] = hotkey
        actions[id] = (pressed, released)
        return true
    }

    func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        hotkeys[id] = nil
        actions[id] = nil
    }

    private func install(_ id: UInt32, _ hotkey: Hotkey) -> Bool {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, EventHotKeyID(signature: OSType(0x53435242), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        return true
    }

    private func setSuspended(_ suspend: Bool) {
        guard suspend != suspended else { return }
        suspended = suspend
        if suspend {
            refs.values.forEach { UnregisterEventHotKey($0) }
            refs.removeAll()
        } else {
            for (id, hotkey) in hotkeys { _ = install(id, hotkey) }
        }
    }
}

extension Hotkey {
    static let escape = Hotkey(keyCode: UInt32(kVK_Escape), modifiers: 0)

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        let isFunctionKey = (96...122).contains(Int(event.keyCode))
        guard mods != 0 || isFunctionKey else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods)
    }

    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Self.keyName(Int(keyCode))
    }

    private static func keyName(_ code: Int) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
            kVK_F19: "F19",
        ]
        if let name = special[code] { return name }
        // Ask the current keyboard layout what the key types.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let layout = unsafeBitCast(raw, to: CFData.self)
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = UCKeyTranslate(unsafeBitCast(CFDataGetBytePtr(layout), to: UnsafePointer<UCKeyboardLayout>.self),
                                    UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
        guard status == noErr, length > 0 else { return "#\(code)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// Types text into the app that had focus when dictation started.
enum Paster {
    static var canPaste: Bool { AXIsProcessTrusted() }

    /// What System Settings calls the Accessibility permission: macOS 27 renamed it.
    static let permissionName = ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: 27, minorVersion: 0, patchVersion: 0))
        ? "Device Control and Data Access" : "Accessibility"

    static func openPermissionSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Leaves the text on the clipboard for the user to paste themselves.
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Pastes into `app`, or into whatever has focus when `app` is nil. Returns
    /// false when the text was only copied because Accessibility is off.
    @discardableResult
    static func insert(_ text: String, into app: NSRunningApplication?) -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // Ask clipboard managers not to record dictations (nspasteboard.org).
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        pasteboard.writeObjects([item])
        guard canPaste else { return false }

        if let app, app != NSRunningApplication.current, !app.isActive { app.activate() }
        let changeCount = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let v = CGKeyCode(kVK_ANSI_V)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: down)
                event?.flags = .maskCommand
                event?.post(tap: .cghidEventTap)
            }
            // Give the target time to read the pasteboard, then put back what was there.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard pasteboard.changeCount == changeCount, !saved.isEmpty else { return }
                pasteboard.clearContents()
                pasteboard.writeObjects(saved.map { pairs in
                    let restored = NSPasteboardItem()
                    for (type, data) in pairs { restored.setData(data, forType: type) }
                    return restored
                })
            }
        }
        return true
    }
}
