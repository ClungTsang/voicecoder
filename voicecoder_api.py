#!/usr/bin/env python3
"""
VoiceCoder HTTP API Bridge
REST API on port 19642 for the Desktop app (Tauri/Vue).
Communicates with voicecoder_service.py via Unix Socket / TCP.
Manages SQLite for transcriptions, settings, and user data.
"""

import json
import os
import platform
import re
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler
from socket import socket, AF_UNIX, AF_INET, SOCK_STREAM

API_PORT = 19642
SOCKET_PATH = '/tmp/voicecoder.sock'
TCP_HOST = '127.0.0.1'
TCP_PORT = 19641

DB_DIR = os.path.expanduser('~/Library/Application Support/VoiceCoder')
if platform.system() == 'Windows':
    DB_DIR = os.path.join(os.environ.get('APPDATA', '~'), 'VoiceCoder')
elif platform.system() == 'Linux':
    DB_DIR = os.path.expanduser('~/.local/share/voicecoder')
DB_PATH = os.path.join(DB_DIR, 'voicecoder.db')

GITHUB_CLIENT_ID = 'Ov23ct8qzWOi7eQCDh36'
GITHUB_CLIENT_SECRET = 'REDACTED_GITHUB_SECRET'

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TERMS_PATH = os.path.join(SCRIPT_DIR, 'tech_terms.json')


# ── SQLite ──────────────────────────────────────────────

def get_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute('PRAGMA journal_mode=WAL')
    return conn


def init_db():
    db = get_db()
    db.executescript('''
        CREATE TABLE IF NOT EXISTS transcriptions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            text TEXT NOT NULL,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            duration_ms INTEGER DEFAULT 0,
            model TEXT DEFAULT '',
            language TEXT DEFAULT 'zh',
            char_count INTEGER DEFAULT 0,
            starred INTEGER DEFAULT 0,
            device TEXT DEFAULT ''
        );
        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT DEFAULT '',
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE IF NOT EXISTS user (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            github_id INTEGER,
            username TEXT DEFAULT '',
            avatar_url TEXT DEFAULT '',
            html_url TEXT DEFAULT '',
            access_token TEXT DEFAULT '',
            logged_in_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        CREATE INDEX IF NOT EXISTS idx_trans_created ON transcriptions(created_at DESC);
    ''')
    db.commit()
    db.close()


init_db()


# ── Backend Socket ──────────────────────────────────────

def send_to_backend(action):
    system = platform.system()
    try:
        if system == 'Windows':
            s = socket(AF_INET, SOCK_STREAM)
            s.settimeout(5)
            s.connect((TCP_HOST, TCP_PORT))
        else:
            s = socket(AF_UNIX, SOCK_STREAM)
            s.settimeout(5)
            s.connect(SOCKET_PATH)
        s.sendall(json.dumps(action).encode('utf-8'))
        data = s.recv(65536)
        s.close()
        return json.loads(data.decode('utf-8'))
    except FileNotFoundError:
        return {'error': 'Backend not running (socket not found)'}
    except ConnectionRefusedError:
        return {'error': 'Backend not running (connection refused)'}
    except Exception as e:
        return {'error': str(e)}


def is_backend_running():
    return send_to_backend({'action': 'ping'}).get('status') == 'ok'


def get_setting(key, default=None):
    db = get_db()
    row = db.execute('SELECT value FROM settings WHERE key = ?', (key,)).fetchone()
    db.close()
    if row:
        try:
            return json.loads(row['value'])
        except Exception:
            return row['value']
    return default


def set_setting(key, value):
    db = get_db()
    db.execute(
        'INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, datetime("now"))',
        (key, json.dumps(value))
    )
    db.commit()
    db.close()


def load_terms():
    if os.path.exists(TERMS_PATH):
        with open(TERMS_PATH, 'r', encoding='utf-8') as f:
            raw = json.load(f)
        if isinstance(raw, dict):
            return [{'wrong': k, 'correct': v} for k, v in raw.items()]
        return raw
    return []


def save_terms(terms_dict):
    with open(TERMS_PATH, 'w', encoding='utf-8') as f:
        json.dump(terms_dict, f, ensure_ascii=False, indent=2)


def github_exchange_code(code):
    """Exchange GitHub OAuth code for user info."""
    token_req = urllib.request.Request(
        'https://github.com/login/oauth/access_token',
        data=json.dumps({
            'client_id': GITHUB_CLIENT_ID,
            'client_secret': GITHUB_CLIENT_SECRET,
            'code': code,
        }).encode(),
        headers={'Accept': 'application/json'}
    )
    token_resp = json.loads(urllib.request.urlopen(token_req, timeout=10).read().decode())
    access_token = token_resp.get('access_token', '')

    user_req = urllib.request.Request(
        'https://api.github.com/user',
        headers={'Authorization': f'token {access_token}', 'User-Agent': 'VoiceCoder'}
    )
    user_info = json.loads(urllib.request.urlopen(user_req, timeout=10).read().decode())

    db = get_db()
    db.execute(
        '''INSERT OR REPLACE INTO user (id, github_id, username, avatar_url, html_url, access_token, logged_in_at)
           VALUES (1, ?, ?, ?, ?, ?, datetime("now"))''',
        (user_info.get('id'), user_info.get('login'),
         user_info.get('avatar_url'), user_info.get('html_url'), access_token)
    )
    db.commit()
    db.close()
    return {
        'id': user_info.get('id'),
        'username': user_info.get('login'),
        'avatar_url': user_info.get('avatar_url'),
        'html_url': user_info.get('html_url'),
    }


# ── HTTP Handler ────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _cors(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, PATCH, DELETE, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type, Authorization')

    def _json(self, data, status=200):
        body = json.dumps(data, ensure_ascii=False, default=str).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self._cors()
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        length = int(self.headers.get('Content-Length', 0))
        if length:
            return json.loads(self.rfile.read(length).decode('utf-8'))
        return {}

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    # ── GET ──

    def do_GET(self):
        try:
            self._handle_get()
        except Exception as e:
            self._json({'error': str(e)}, 500)

    def _handle_get(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip('/')
        params = dict(urllib.parse.parse_qsl(parsed.query))

        if path == '/api/ping':
            result = send_to_backend({'action': 'ping'})
            if 'error' in result:
                self._json({'status': 'error', 'message': result['error']}, 503)
            else:
                self._json(result)
            return

        if path == '/api/transcriptions':
            db = get_db()
            q = 'SELECT * FROM transcriptions WHERE 1=1'
            qp = []
            if params.get('q'):
                q += ' AND text LIKE ?'
                qp.append(f"%{params['q']}%")
            if params.get('from'):
                q += ' AND created_at >= ?'
                qp.append(params['from'])
            if params.get('to'):
                q += ' AND created_at <= ?'
                qp.append(params['to'] + ' 23:59:59')
            q += ' ORDER BY created_at DESC'
            limit = min(int(params.get('limit', 100)), 1000)
            q += f' LIMIT {limit}'
            rows = db.execute(q, qp).fetchall()
            db.close()
            self._json([dict(r) for r in rows])
            return

        m = re.match(r'^/api/transcriptions/(\d+)$', path)
        if m:
            db = get_db()
            row = db.execute('SELECT * FROM transcriptions WHERE id = ?', (int(m.group(1)),)).fetchone()
            db.close()
            self._json(dict(row) if row else {'error': 'Not found'}, 200 if row else 404)
            return

        if path == '/api/settings':
            db = get_db()
            rows = db.execute('SELECT key, value FROM settings').fetchall()
            db.close()
            settings = {}
            for r in rows:
                try:
                    settings[r['key']] = json.loads(r['value'])
                except Exception:
                    settings[r['key']] = r['value']
            self._json(settings)
            return

        if path == '/api/models':
            models = [
                {'id': 'sensevoice-small', 'name': 'SenseVoice Small', 'engine': 'ONNX/CoreML', 'size_mb': 1100,
                 'status': 'downloaded' if os.path.exists(os.path.expanduser('~/.hermes/cache/sherpa-onnx-sensevoice-zh/')) else 'available'},
                {'id': 'whisper-small', 'name': 'Whisper Small', 'engine': 'ONNX', 'size_mb': 461, 'status': 'available'},
                {'id': 'whisper-medium', 'name': 'Whisper Medium', 'engine': 'ONNX', 'size_mb': 1500, 'status': 'available'},
            ]
            ping = send_to_backend({'action': 'ping'})
            current = ping.get('model', '')
            for model in models:
                model['is_current'] = ('SenseVoice' in current and 'sensevoice' in model['id']) or \
                                      ('Whisper' in current and 'whisper' in model['id'])
            self._json(models)
            return

        if path == '/api/devices':
            try:
                import sounddevice as sd
                devices = []
                for i, d in enumerate(sd.query_devices()):
                    if d['max_input_channels'] > 0:
                        devices.append({
                            'id': i,
                            'name': d['name'],
                            'channels': d['max_input_channels'],
                            'sample_rate': int(d['default_samplerate']),
                            'is_default': sd.default.device[0] == i,
                        })
                self._json(devices)
            except Exception as e:
                self._json({'error': str(e)}, 500)
            return

        if path == '/api/devices/test':
            # Capture 2 seconds of audio and return volume stats
            try:
                import sounddevice as sd
                import numpy as np
                device_id = params.get('device', '')
                dev = int(device_id) if device_id and device_id != 'null' else None
                fs = 16000
                duration = 2.0
                audio = sd.rec(int(fs * duration), samplerate=fs, channels=1,
                               dtype='int16', device=dev)
                sd.wait()
                arr = audio.flatten().astype(np.float32) / 32768.0
                peak = float(np.max(np.abs(arr)))
                rms = float(np.sqrt(np.mean(arr ** 2)))
                self._json({
                    'peak': round(peak, 4),
                    'rms': round(rms, 4),
                    'level': 'loud' if peak > 0.3 else ('normal' if peak > 0.05 else 'quiet'),
                    'suggestion': '音量正常' if peak > 0.05 else '音量过低，请靠近麦克风或检查输入设备',
                    'duration_ms': int(duration * 1000),
                })
            except Exception as e:
                self._json({'error': str(e)}, 500)
            return

        if path == '/api/terms':
            self._json(load_terms())
            return

        if path == '/api/auth/github/url':
            if not GITHUB_CLIENT_ID:
                self._json({'url': '', 'note': 'GitHub OAuth not configured. Set GITHUB_CLIENT_ID in voicecoder_api.py'})
                return
            url = f'https://github.com/login/oauth/authorize?client_id={GITHUB_CLIENT_ID}&scope=read:user,user:email&redirect_uri=http://127.0.0.1:{API_PORT}/api/auth/github/callback'
            self._json({'url': url})
            return

        if path == '/api/auth/github/callback':
            code = params.get('code')
            if code and GITHUB_CLIENT_ID and GITHUB_CLIENT_SECRET:
                user = github_exchange_code(code)
                self._cors()
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.end_headers()
                # Auto-redirect back to Tauri app after 2 seconds
                html = '''<html><body style="font-family:system-ui;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;background:#fafaf9">
                <div style="text-align:center">
                <h2 style="color:#0d9488">✓ 登录成功！</h2>
                <p>欢迎，''' + (user.get('username', '') if user else '') + '''</p>
                <p style="color:#78716e;font-size:14px">正在返回 VoiceCoder...</p>
                <script>
                setTimeout(function(){
                  window.location.href = 'tauri://localhost';
                  try { window.close(); } catch(e) {}
                }, 1500);
                </script>
                </div></body></html>'''
                self.wfile.write(html.encode('utf-8'))
            else:
                self._json({'error': 'OAuth not configured'}, 400)
            return

        if path == '/api/auth/user':
            db = get_db()
            row = db.execute('SELECT github_id, username, avatar_url, html_url FROM user WHERE id = 1').fetchone()
            db.close()
            if row and row['github_id']:
                self._json({'id': row['github_id'], 'username': row['username'], 'avatar_url': row['avatar_url'], 'html_url': row['html_url']})
            else:
                self._json(None)
            return

        if path == '/api/updates/check':
            try:
                req = urllib.request.Request(
                    'https://api.github.com/repos/ClungTsang/voicecoder-desktop/releases/latest',
                    headers={'User-Agent': 'VoiceCoder'}
                )
                resp = json.loads(urllib.request.urlopen(req, timeout=5).read().decode())
                latest = resp.get('tag_name', 'v0.0.0').lstrip('v')
                current = '4.0.0'
                self._json({
                    'has_update': latest != current and latest > current,
                    'version': resp.get('tag_name', ''),
                    'notes': resp.get('body', ''),
                    'url': resp.get('html_url', ''),
                })
            except Exception as e:
                self._json({'has_update': False, 'error': str(e)})
            return

        self._json({'error': 'Not found'}, 404)

    # ── POST ──

    def do_POST(self):
        try:
            self._handle_post()
        except Exception as e:
            self._json({'error': str(e)}, 500)

    def _handle_post(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip('/')
        body = self._read_body()

        if path == '/api/service/start':
            service_script = os.path.join(SCRIPT_DIR, 'voicecoder_service.py')
            daemon_script = os.path.join(SCRIPT_DIR, 'voicecoder_daemon.py')
            python_bin = sys.executable
            try:
                # Start the transcription service
                subprocess.Popen(
                    [python_bin, service_script],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    cwd=SCRIPT_DIR
                )
                # Start the hotkey daemon (mouse middle button listener)
                if os.path.exists(daemon_script):
                    subprocess.Popen(
                        [python_bin, daemon_script],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                        cwd=SCRIPT_DIR
                    )
                # On macOS also try the native Swift daemon
                swift_daemon = os.path.join(SCRIPT_DIR, 'daemon.swift')
                compiled_daemon = os.path.join(SCRIPT_DIR, 'VoiceCoderDaemon')
                if platform.system() == 'Darwin' and os.path.exists(compiled_daemon):
                    subprocess.Popen(
                        [compiled_daemon],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                        cwd=SCRIPT_DIR
                    )
                time.sleep(3)
                self._json({'ok': is_backend_running()})
            except Exception as e:
                self._json({'ok': False, 'error': str(e)}, 500)
            return

        if path == '/api/service/stop':
            try:
                subprocess.run(['pkill', '-f', 'voicecoder_service.py'], capture_output=True)
                self._json({'ok': True})
            except Exception as e:
                self._json({'ok': False, 'error': str(e)}, 500)
            return

        if path == '/api/transcriptions':
            text = body.get('text', '').strip()
            if text:
                db = get_db()
                db.execute(
                    'INSERT INTO transcriptions (text, duration_ms, model, language, char_count, device) VALUES (?, ?, ?, ?, ?, ?)',
                    (text, body.get('duration_ms', 0), body.get('model', ''), body.get('language', 'zh'), len(text), body.get('device', ''))
                )
                db.commit()
                db.close()
                self._json({'ok': True})
            else:
                self._json({'error': 'Empty text'}, 400)
            return

        if path == '/api/terms':
            wrong = body.get('wrong', '').strip()
            correct = body.get('correct', '').strip()
            if not wrong or not correct:
                self._json({'error': 'Both wrong and correct required'}, 400)
                return
            terms = load_terms()
            terms_dict = {t['wrong']: t['correct'] for t in terms}
            terms_dict[wrong] = correct
            save_terms(terms_dict)
            self._json({'ok': True})
            return

        m = re.match(r'^/api/models/([^/]+)/download$', path)
        if m:
            self._json({'ok': True, 'message': 'Model download not yet automated'})
            return

        m = re.match(r'^/api/models/([^/]+)/switch$', path)
        if m:
            set_setting('current_model', m.group(1))
            self._json({'ok': True})
            return

        if path == '/api/auth/github/callback':
            code = body.get('code')
            if code and GITHUB_CLIENT_ID and GITHUB_CLIENT_SECRET:
                user = github_exchange_code(code)
                self._json(user)
            else:
                self._json({'error': 'OAuth not configured'}, 400)
            return

        if path == '/api/auth/logout':
            db = get_db()
            db.execute('DELETE FROM user WHERE id = 1')
            db.commit()
            db.close()
            self._json({'ok': True})
            return

        self._json({'error': 'Not found'}, 404)

    # ── PATCH ──

    def do_PATCH(self):
        try:
            self._handle_patch()
        except Exception as e:
            self._json({'error': str(e)}, 500)

    def _handle_patch(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip('/')
        body = self._read_body()

        if path == '/api/settings':
            key = body.get('key')
            value = body.get('value')
            if key:
                set_setting(key, value)
                self._json({'ok': True})
            else:
                self._json({'error': 'Missing key'}, 400)
            return

        m = re.match(r'^/api/transcriptions/(\d+)/star$', path)
        if m:
            tid = int(m.group(1))
            starred = body.get('starred', True)
            db = get_db()
            db.execute('UPDATE transcriptions SET starred = ? WHERE id = ?', (1 if starred else 0, tid))
            db.commit()
            db.close()
            self._json({'ok': True})
            return

        self._json({'error': 'Not found'}, 404)

    # ── DELETE ──

    def do_DELETE(self):
        try:
            self._handle_delete()
        except Exception as e:
            self._json({'error': str(e)}, 500)

    def _handle_delete(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip('/')

        m = re.match(r'^/api/transcriptions/(\d+)$', path)
        if m:
            db = get_db()
            db.execute('DELETE FROM transcriptions WHERE id = ?', (int(m.group(1)),))
            db.commit()
            db.close()
            self._json({'ok': True})
            return

        m = re.match(r'^/api/terms/(\d+)$', path)
        if m:
            idx = int(m.group(1))
            terms = load_terms()
            if 0 <= idx < len(terms):
                terms_dict = {t['wrong']: t['correct'] for t in terms}
                keys = list(terms_dict.keys())
                if 0 <= idx < len(keys):
                    del terms_dict[keys[idx]]
                    save_terms(terms_dict)
                self._json({'ok': True})
            else:
                self._json({'error': 'Not found'}, 404)
            return

        self._json({'error': 'Not found'}, 404)


# ── Run ─────────────────────────────────────────────────

def run():
    server = HTTPServer(('127.0.0.1', API_PORT), Handler)
    print(f'[VoiceCoder API] HTTP Bridge on http://127.0.0.1:{API_PORT}', file=sys.stderr)
    print(f'[VoiceCoder API] Backend socket: {SOCKET_PATH}', file=sys.stderr)
    print(f'[VoiceCoder API] Database: {DB_PATH}', file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.server_close()


if __name__ == '__main__':
    run()
