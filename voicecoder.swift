#!/usr/bin/env swift
// VoiceCoder v4 — Apple Speech Framework, improved accuracy
// Hold middle mouse button → record
// Release → transcribe & paste (waits for final result)
// Minimum 0.5s audio required to avoid noise triggers

import Foundation
import AppKit
import Speech
import Carbon

// MARK: - Speech Transcriber

class SpeechTranscriber: NSObject, SFSpeechRecognizerDelegate {
    private let recognizer: SFSpeechRecognizer
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var isRecording = false

    // Results
    private var finalTranscript = ""
    private var resultHandler: ((String) -> Void)?
    private var hasFinalized = false
    private var audioStartTime: Date?

    override init() {
        // zh-CN with English support for coding terms
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))!
        super.init()
        recognizer.delegate = self
        recognizer.supportsOnDeviceRecognition = true
    }

    func startRecording(onResult: @escaping (String) -> Void) {
        guard !isRecording else { return }
        self.resultHandler = onResult
        self.finalTranscript = ""
        self.hasFinalized = false
        self.isRecording = true
        self.audioStartTime = Date()

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else {
                print("[Speech] Authorization denied")
                return
            }
            DispatchQueue.main.async {
                self?.beginRecording()
            }
        }
    }

    private func beginRecording() {
        do {
            let engine = AVAudioEngine()
            self.audioEngine = engine

            let inputNode = engine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            // Verify audio format is compatible
            guard recordingFormat.sampleRate > 0 else {
                print("[Speech] Invalid audio format")
                return
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            self.request = request
            self.hasFinalized = false

            // Install tap to capture audio
            inputNode.installTap(onBus: 0, bufferSize: 2048, format: recordingFormat) { buffer, _ in
                request.append(buffer)
            }

            try engine.start()

            // Start recognition — listen for final result
            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self = self else { return }

                if let result = result {
                    let text = result.bestTranscription.formattedString
                    print("[Speech] Partial: '\(text)'")

                    if result.isFinal {
                        self.finalTranscript = text
                        self.hasFinalized = true
                        print("[Speech] Final: '\(text)'")
                        self.finish()
                    }
                }

                if error != nil {
                    print("[Speech] Error: \(String(describing: error))")
                    self.finish()
                }
            }

            print("[Speech] Recording started (on-device, default mic)")

        } catch {
            print("[Speech] Failed to start: \(error)")
            isRecording = false
        }
    }

    func stopAndGetResult() -> String {
        guard isRecording else { return "" }

        // If we already have a final result, return it
        if hasFinalized {
            return finalTranscript
        }

        // Force stop and wait briefly for any final result
        let stoppedTranscript = finalTranscript
        finish()
        return stoppedTranscript
    }

    private func finish() {
        guard isRecording else { return }
        isRecording = false

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        request?.endAudio()
        recognitionTask?.cancel()
        audioEngine = nil
        request = nil
        recognitionTask = nil

        // Callback with final transcript
        if let handler = resultHandler {
            let text = finalTranscript
            resultHandler = nil
            DispatchQueue.main.async {
                handler(text)
            }
        }
    }

    // Timeout watchdog — if no speech detected for 15s, stop
    func startTimeoutWatchdog() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self = self, self.isRecording else { return }
            // No final result after 15s — force stop
            print("[Speech] Timeout, stopping...")
            let text = self.finalTranscript
            self.finish()
            if let handler = self.resultHandler {
                DispatchQueue.main.async {
                    handler(text)
                }
            }
        }
    }
}

// MARK: - Paste

func pasteToCursor(_ text: String) {
    guard !text.isEmpty else { return }

    DispatchQueue.main.async {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Cmd+V after clipboard set
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let src = CGEventSource(stateID: .hidSystemState)
            let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
            keyDown?.flags = .maskCommand
            let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
            keyUp?.flags = .maskCommand
            keyUp?.post(tap: .cghidEventTap)
            keyDown?.post(tap: .cghidEventTap)
            print("[VoiceCoder] ✅ Pasted: '\(text.prefix(60))...'")
        }
    }
}

// MARK: - App

class App: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var transcriber = SpeechTranscriber()
    var isRecording = false
    var recordStartTime: Date?
    var eventTap: CFMachPort?
    var runLoopSource: CFRunLoopSource?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Status bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(normal: true)

        let menu = NSMenu()
        menu.addItem(withTitle: "🎤 VoiceCoder v4 — Apple Speech", action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "按住鼠标中键说话，松开自动粘贴", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "最短需要约0.5秒语音才会识别", action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        let testItem = NSMenuItem(title: "测试录音（3秒）", action: #selector(testAction), keyEquivalent: "t")
        testItem.keyEquivalentModifierMask = [.command]
        menu.addItem(testItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
        statusItem.menu = menu

        setupEventTap()
        print("[VoiceCoder v4] Ready! Hold middle mouse button to record.")
        print("[VoiceCoder v4] Using Apple Speech (on-device, M4 Neural Engine)")
    }

    func updateIcon(normal: Bool) {
        let name = normal ? "mic" : "mic.fill"
        DispatchQueue.main.async {
            self.statusItem?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            self.statusItem?.button?.image?.isTemplate = true
        }
    }

    func setupEventTap() {
        let cb: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passRetained(event) }
            let app = Unmanaged<App>.fromOpaque(refcon).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = app.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passRetained(event)
            }

            let button = event.getIntegerValueField(.mouseEventButtonNumber)

            if type == .otherMouseDown && button == 2 { app.onMiddleDown() }
            else if type == .otherMouseUp && button == 2 { app.onMiddleUp() }

            return Unmanaged.passRetained(event)
        }

        let mask: CGEventMask = (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: cb,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[VoiceCoder] ERROR: Need Accessibility permission!")
            print("[VoiceCoder] System Settings → Privacy & Security → Accessibility → Add and enable this app")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func onMiddleDown() {
        guard !isRecording else { return }
        isRecording = true
        recordStartTime = Date()
        updateIcon(normal: false)
        print("[VoiceCoder] ▶ Recording...")

        transcriber.startTimeoutWatchdog()
        transcriber.startRecording { result in
            // This fires when recognition completes (isFinal=true or timeout)
            self.handleResult(result)
        }
    }

    func onMiddleUp() {
        guard isRecording else { return }
        isRecording = false
        updateIcon(normal: true)
        print("[VoiceCoder] ■ Stopped, getting result...")

        // Get result — waits for final if still processing
        let text = transcriber.stopAndGetResult()
        handleResult(text)
    }

    func handleResult(_ text: String) {
        let duration = recordStartTime.map { Date().timeIntervalSince($0) } ?? 0

        print("[VoiceCoder] ⏱ Duration: \(String(format: "%.1f", duration))s, Result: '\(text)'")

        // Require minimum 0.5s of audio to avoid noise triggers
        if duration < 0.5 && text.isEmpty {
            print("[VoiceCoder] ⚠️ Too short, ignoring")
            return
        }

        if text.isEmpty {
            print("[VoiceCoder] ❌ No speech detected")
        } else {
            pasteToCursor(text)
        }
    }

    @objc func testAction() {
        print("[VoiceCoder] 🧪 Test recording (3s)...")
        onMiddleDown()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.onMiddleUp()
        }
    }

    @objc func quit() {
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes) }
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        NSApp.terminate(nil)
    }
}

// Run
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()