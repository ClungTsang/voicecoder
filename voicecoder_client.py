#!/usr/bin/env python3
"""VoiceCoder Client - Test and control the transcription service"""
import socket
import json
import sys
import argparse

SOCKET_PATH = '/tmp/voicecoder.sock'

def send_cmd(action, auto_paste=False, seconds=3):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    try:
        s.connect(SOCKET_PATH)
        cmd = {'action': action, 'auto_paste': auto_paste, 'seconds': seconds}
        s.send(json.dumps(cmd).encode())
        resp = s.recv(4096)
        return json.loads(resp.decode())
    except Exception as e:
        return {'error': str(e)}
    finally:
        s.close()

def main():
    parser = argparse.ArgumentParser(description='VoiceCoder Client')
    parser.add_argument('action', choices=['ping', 'transcribe', 'test', 'status'])
    parser.add_argument('--seconds', '-s', type=int, default=3)
    args = parser.parse_args()

    if args.action == 'ping':
        resp = send_cmd('ping', auto_paste=False, seconds=1)
        if resp.get('status') == 'ok':
            print(f"✅ Service ready | Model: {resp.get('model')} | Transcribing: {resp.get('transcribing')}")
        else:
            print(f"❌ Service error: {resp}")

    elif args.action == 'transcribe':
        print("🎤 Recording... (speak now)")
        resp = send_cmd('transcribe_and_paste', auto_paste=False, seconds=args.seconds)
        if 'result' in resp:
            print(f"📝 {resp['result']}")
        else:
            print(f"❌ {resp.get('error', 'Unknown error')}")

    elif args.action == 'test':
        print("🧪 Testing transcription pipeline...")
        resp = send_cmd('transcribe_and_paste', auto_paste=False, seconds=1)
        if 'result' in resp:
            print(f"✅ Transcribed: '{resp['result']}'")
        else:
            print(f"❌ Test failed: {resp}")

    elif args.action == 'status':
        resp = send_cmd('ping', auto_paste=False, seconds=1)
        if resp.get('status') == 'ok':
            print(f"Model: {resp.get('model')}")
            print(f"Transcribing: {resp.get('transcribing')}")
        else:
            print("Service not running")

if __name__ == '__main__':
    main()