import Cocoa
import Carbon

class GlobalHotkey {
    static let shared = GlobalHotkey()
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    var onTrigger: (() -> Void)?

    func register(config: HotkeyConfig) {
        unregister() // Clean up existing before registering new

        var hotKeyId = EventHotKeyID()
        hotKeyId.signature = OSType(0x47525953) // 'GRYS'
        hotKeyId.id = 1

        let status = RegisterEventHotKey(
            config.keyCode,
            config.modifiers,
            hotKeyId,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        
        if status != noErr {
            print("Failed to register hotkey: \(status)")
            return
        }

        // Only install the handler once
        if eventHandlerRef == nil {
            let eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            
            InstallEventHandler(GetApplicationEventTarget(), { (nextHandler, theEvent, userData) -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let size = MemoryLayout<EventHotKeyID>.size
                let status = GetEventParameter(theEvent, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, size, nil, &hotKeyID)
                
                if status == noErr && hotKeyID.signature == 0x47525953 && hotKeyID.id == 1 {
                    GlobalHotkey.shared.onTrigger?()
                    return noErr
                }
                
                return CallNextEventHandler(nextHandler, theEvent)
            }, 1, [eventType], nil, &eventHandlerRef)
        }
    }
    
    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
    }
}
