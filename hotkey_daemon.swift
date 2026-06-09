#!/usr/bin/env swift

// VoiceCoder Mouse Daemon v2
// Hold middle mouse button → continuous recording
// Release → transcribe + paste

import Foundation
import AppKit
import Carbon

// MARK: - Socket Client

class SocketClient {
    let path: String

    init(path: String) {
        self.path = path
    }

    func send(_ cmd: [String: Any]) -> [String: Any]? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { (cstr: UnsafePointer<CChar>) in
            withUnsafeMutablePointer(to: &addr.sun_path) { dest in
                dest.withMemoryRebound(to: CChar.self, capacity: 104) { destC in
                    strncpy(destC, cstr, 104)
                }
            }
        }

        let ret: Int32 = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ret >= 0 else { return nil }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: cmd),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return nil }

        _ = jsonStr.withCString { ptr in
            Darwin.write(fd, ptr, strlen(ptr))
        }
        _ = Darwin.write(fd, [UInt8]("\n".utf8), 1)

        var buf = [UInt8](repeating: 0, count: 4096)
        let bytesRead = Darwin.read(fd, &buf, 4096)
        guard bytesRead > 0 else { return nil }

        let data = Data(buf[0..<Int(bytesRead)])
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func ping() -> Bool {
        if let resp = send(["action": "ping"]) {
            return resp["status"] as? String == "ok"
        }
        return false
    }
}

// MARK: - Mouse Monitor

class MouseMonitor {
    var tap: CFMachPort?
    var runLoopSource: CFRunLoopSource?
    var statusItem: NSStatusItem?
    var pingTimer: Timer?
    var isRecording = false
    var lastClickTime: Date = Date.distantPast
    let debounceInterval: TimeInterval = 1.0

    static var shared = MouseMonitor()

    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem?.button {
            btn.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "VoiceCoder")
            btn.image?.isTemplate = true
        }

        let menu = NSMenu()

        let statusMenuItem = NSMenuItem(title: "VoiceCoder: Checking...", action: nil, keyEquivalent: "")
        statusMenuItem.tag = 100
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Trigger: Hold Middle Mouse Button", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Hold to record, release to transcribe", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let testItem = NSMenuItem(title: "Test", action: #selector(testAction), keyEquivalent: "t")
        testItem.keyEquivalentModifierMask = [.command]
        menu.addItem(testItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem?.menu = menu

        pingTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
    }

    func updateStatus() {
        let client = SocketClient(path: "/tmp/voicecoder.sock")
        let running = client.ping()
        if let item = statusItem?.menu?.item(withTag: 100) {
            item.title = running ? "VoiceCoder: Ready" : "VoiceCoder: Service Offline"
        }
    }

    func startMonitoring() {
        let callback: CGEventTapCallBack = { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            guard let refcon = refcon else {
                return Unmanaged.passRetained(event)
            }

            let monitor = Unmanaged<MouseMonitor>.fromOpaque(refcon).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = monitor.tap {
                    CGEvent.tapEnable(tap: t, enable: true)
                }
                return Unmanaged.passRetained(event)
            }

            if type == .otherMouseDown {
                let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
                if buttonNumber == 2 {
                    monitor.handleButtonDown()
                }
            }

            if type == .otherMouseUp {
                let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
                if buttonNumber == 2 {
                    monitor.handleButtonUp()
                }
            }

            return Unmanaged.passRetained(event)
        }

        // Monitor both button down and button up
        let eventMask: CGEventMask = (
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue)
        )

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[MouseMonitor] Failed to create event tap.")
            showAccessibilityPrompt()
            return
        }

        tap = eventTap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        print("[MouseMonitor] Middle mouse button monitoring started!")
        print("[MouseMonitor] Hold middle button to record, release to transcribe")
    }

    func showAccessibilityPrompt() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "VoiceCoder 需要辅助功能权限"
            alert.informativeText = "请在 系统设置 → 隐私与安全性 → 辅助功能 中添加并启用 VoiceCoder，然后重新启动。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "退出")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            NSApp.terminate(nil)
        }
    }

    func handleButtonDown() {
        let now = Date()
        guard now.timeIntervalSince(lastClickTime) > debounceInterval else {
            print("[MouseMonitor] Debounced")
            return
        }
        lastClickTime = now

        print("[MouseMonitor] Middle button pressed - starting recording...")
        isRecording = true

        DispatchQueue.global(qos: .userInitiated).async {
            let client = SocketClient(path: "/tmp/voicecoder.sock")
            if let resp = client.send(["action": "start_streaming", "auto_paste": false, "seconds": 0]) {
                print("[MouseMonitor] start_streaming response: \(resp)")
            }
        }

        flashRecording()
    }

    func handleButtonUp() {
        guard isRecording else { return }
        print("[MouseMonitor] Middle button released - stopping and transcribing...")
        isRecording = false

        DispatchQueue.global(qos: .userInitiated).async {
            let client = SocketClient(path: "/tmp/voicecoder.sock")
            if let resp = client.send(["action": "stop_streaming", "auto_paste": true, "seconds": 0]) {
                if let result = resp["result"] as? String, !result.isEmpty {
                    print("[MouseMonitor] ✅ Transcribed: \(result)")
                } else if let error = resp["error"] as? String {
                    print("[MouseMonitor] ❌ Error: \(error)")
                } else {
                    print("[MouseMonitor] No speech detected")
                }
            }
        }
    }

    func flashRecording() {
        DispatchQueue.main.async {
            if let btn = self.statusItem?.button {
                let origImage = btn.image
                // Show recording indicator
                btn.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: nil)
                btn.image?.isTemplate = true

                // Pulse animation while recording
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if self.isRecording {
                        self.flashRecording()  // Keep pulsing while recording
                    } else {
                        btn.image = origImage
                        btn.image?.isTemplate = true
                    }
                }
            }
        }
    }

    @objc func testAction() {
        print("[App] Test triggered")
        // Simulate a press-hold-release cycle
        handleButtonDown()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.handleButtonUp()
        }
    }

    @objc func quit() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
        }
        if let t = tap {
            CGEvent.tapEnable(tap: t, enable: false)
        }
        NSApp.terminate(nil)
    }
}

// MARK: - Main

let app = NSApplication.shared
let monitor = MouseMonitor()
MouseMonitor.shared = monitor

monitor.setupStatusBar()
monitor.startMonitoring()

app.setActivationPolicy(.accessory)
app.run()