#!/usr/bin/env python3
"""
VoiceCoder Cross-Platform Hotkey Daemon
Replaces hotkey_daemon.swift for Windows/Linux, optional on macOS.

Trigger: Hold middle mouse button → record, release → transcribe + paste.
Uses pynput for cross-platform mouse event monitoring.
"""

import json
import socket
import sys
import platform
import threading
import time

SOCKET_PATH = "/tmp/voicecoder.sock"
HOST = "127.0.0.1"
PORT = 19641  # Windows uses TCP, macOS uses Unix socket


def get_socket_path():
    """Return the appropriate socket address for the platform."""
    if platform.system() == "Windows":
        return (HOST, PORT)
    return SOCKET_PATH


def send_command(cmd):
    """Send a JSON command to VoiceCoder service and return the response."""
    try:
        addr = get_socket_path()
        if platform.system() == "Windows":
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        else:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(30)
        s.connect(addr)

        s.sendall((json.dumps(cmd) + "\n").encode("utf-8"))
        buf = b""
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
        s.close()

        if buf:
            return json.loads(buf.decode("utf-8"))
    except Exception as e:
        print(f"[Daemon] Connection error: {e}", file=sys.stderr)
    return None


class VoiceCoderDaemon:
    def __init__(self):
        self.is_recording = False
        self.last_press_time = 0
        self.debounce = 0.5  # seconds

    def on_middle_press(self):
        now = time.time()
        if now - self.last_press_time < self.debounce:
            return
        self.last_press_time = now

        print("[Daemon] Middle button pressed → recording...", file=sys.stderr)
        self.is_recording = True
        threading.Thread(
            target=lambda: send_command({"action": "start_streaming", "auto_paste": False, "seconds": 0}),
            daemon=True,
        ).start()

    def on_middle_release(self):
        if not self.is_recording:
            return
        print("[Daemon] Middle button released → transcribing...", file=sys.stderr)
        self.is_recording = False
        threading.Thread(
            target=lambda: send_command({"action": "stop_streaming", "auto_paste": True, "seconds": 0}),
            daemon=True,
        ).start()

    def run(self):
        """Start monitoring mouse events using pynput."""
        try:
            from pynput import mouse
        except ImportError:
            print("[Daemon] pynput not installed. Run: pip install pynput", file=sys.stderr)
            sys.exit(1)

        print(f"[Daemon] VoiceCoder Hotkey Daemon ({platform.system()})", file=sys.stderr)
        print("[Daemon] Hold middle mouse button to record, release to transcribe", file=sys.stderr)

        # Check service connectivity
        resp = send_command({"action": "ping"})
        if resp and resp.get("status") == "ok":
            print("[Daemon] ✓ Service connected", file=sys.stderr)
        else:
            print("[Daemon] ⚠ Service not responding — will retry on trigger", file=sys.stderr)

        def on_click(x, y, button, pressed):
            if button == mouse.Button.middle:
                if pressed:
                    self.on_middle_press()
                else:
                    self.on_middle_release()

        with mouse.Listener(on_click=on_click) as listener:
            listener.join()


if __name__ == "__main__":
    daemon = VoiceCoderDaemon()
    daemon.run()
