import Cocoa
import Carbon

/// Registers system-wide hotkeys via Carbon. Supports multiple independent
/// hotkeys, each identified by a stable id, so the search shortcut and the
/// quick-add shortcut can coexist.
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    /// Stable ids for the app's hotkeys.
    static let searchID: UInt32 = 1
    static let quickAddID: UInt32 = 2

    private struct Registration {
        var ref: EventHotKeyRef?
        var onTrigger: () -> Void
    }

    private var registrations: [UInt32: Registration] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private let signature = OSType(0x47525953) // 'GRYS'

    /// Register (or replace) a hotkey under `id`.
    /// - Returns: `true` on success, `false` if the combination is already taken
    ///   by the system or another app (so the UI can warn the user).
    @discardableResult
    func register(id: UInt32, config: HotkeyConfig, onTrigger: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()

        // Drop any previous registration for this id first.
        if let existing = registrations[id]?.ref {
            UnregisterEventHotKey(existing)
            registrations[id] = nil
        }

        let hotKeyId = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            config.keyCode,
            config.modifiers,
            hotKeyId,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr, ref != nil else {
            return false
        }

        registrations[id] = Registration(ref: ref, onTrigger: onTrigger)
        return true
    }

    /// Re-register an existing hotkey with a new key combination, reusing the
    /// callback supplied at first registration. Used when the user changes the
    /// shortcut in Settings.
    /// - Returns: `true` on success, `false` if the combo is taken (or the id
    ///   was never registered).
    @discardableResult
    func reregister(id: UInt32, config: HotkeyConfig) -> Bool {
        guard let onTrigger = registrations[id]?.onTrigger else { return false }
        return register(id: id, config: config, onTrigger: onTrigger)
    }

    func unregister(id: UInt32) {
        if let ref = registrations[id]?.ref {
            UnregisterEventHotKey(ref)
        }
        registrations[id] = nil
    }

    private func installHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        let eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(GetApplicationEventTarget(), { (nextHandler, theEvent, _) -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let size = MemoryLayout<EventHotKeyID>.size
            let status = GetEventParameter(
                theEvent,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil, size, nil,
                &hotKeyID
            )

            if status == noErr,
               hotKeyID.signature == GlobalHotkey.shared.signature,
               let reg = GlobalHotkey.shared.registrations[hotKeyID.id] {
                reg.onTrigger()
                return noErr
            }

            return CallNextEventHandler(nextHandler, theEvent)
        }, 1, [eventType], nil, &eventHandlerRef)
    }
}
