import Cocoa
import Carbon

// PasteHelper: reads from stdin, sets clipboard, simulates Cmd+V
// Usage: echo "text" | paste_helper

let input = FileHandle.standardInput
let data = input.readDataToEndOfFile()
guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
    fputs("Usage: echo 'text' | paste_helper\n", stderr)
    exit(1)
}

// Set clipboard
let pasteboard = NSPasteboard.general
pasteboard.clearContents()
pasteboard.setString(text, forType: .string)

// Simulate Cmd+V
Thread.sleep(forTimeInterval: 0.05)

let source = CGEventSource(stateID: .hidSystemState)

// Cmd down
let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true)
cmdDown?.flags = .maskCommand
cmdDown?.post(tap: .cghidEventTap)

// V down
let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
vDown?.flags = .maskCommand
vDown?.post(tap: .cghidEventTap)

// V up
let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
vUp?.flags = .maskCommand
vUp?.post(tap: .cghidEventTap)

// Cmd up
let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)
cmdUp?.flags = .maskCommand
cmdUp?.post(tap: .cghidEventTap)

fputs("✅ Pasted: \(text.prefix(50))\n", stderr)
