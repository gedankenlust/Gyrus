import SwiftUI
import Carbon

struct HotkeyRecorder: View {
    @Binding var hotkey: HotkeyConfig
    let onChange: () -> Void
    
    @State private var isRecording = false
    @State private var localMonitor: Any?

    var body: some View {
        Button(action: startRecording) {
            Text(isRecording ? "Recording... (Press shortcut)" : hotkey.displayString)
                .frame(minWidth: 120, alignment: .center)
        }
        .onChange(of: isRecording) { _, recording in
            if !recording { stopRecording() }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func startRecording() {
        guard !isRecording else { return } // Prevent duplicate monitors
        isRecording = true
        
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Handle Escape key (keyCode 53) without modifiers as cancellation
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53 && mods.isEmpty {
                self.isRecording = false
                return nil // Consume event
            }
            
            // Require at least one modifier to prevent binding simple letters
            if mods.isEmpty || mods == .shift { return event }

            var carbonModifiers: UInt32 = 0
            if mods.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
            if mods.contains(.option) { carbonModifiers |= UInt32(optionKey) }
            if mods.contains(.control) { carbonModifiers |= UInt32(controlKey) }
            if mods.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }

            // Extract a display string
            var keyStr = event.charactersIgnoringModifiers?.uppercased() ?? ""
            if event.keyCode == 49 { keyStr = "Space" }
            else if event.keyCode == 36 { keyStr = "Return" }
            else if event.keyCode == 53 { keyStr = "Esc" }

            self.hotkey = HotkeyConfig(keyCode: UInt32(event.keyCode), modifiers: carbonModifiers, keyString: keyStr)
            self.isRecording = false
            self.onChange()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }
}
