#!/usr/bin/env python3
"""
VoiceCoder Streaming Service v4
- 按住鼠标中键：持续录音
- 松开鼠标中键：转录全部音频 → 粘贴
- 引擎: SenseVoice Small (阿里通义, 非自回归架构)
- 音频处理: WebRTC VAD 前端过滤 + 归一化放大 + 后端幻觉过滤
"""
import os
import sys
import time
import socket
import threading
import signal
import argparse
import json
import subprocess
import re
import numpy as np

# --- State ---
_recording = False
_recording_lock = threading.Lock()
_audio_chunks = []       # List of byte arrays (16kHz 16-bit PCM)
_audio_lock = threading.Lock()
_full_transcript = ""    # Final transcript

_model = None            # sherpa_onnx.OfflineRecognizer
_socket_path = ""

# Config
SAMPLE_RATE = 16000
CHUNK_DURATION_MS = 30
CHUNK_SAMPLES = int(SAMPLE_RATE * CHUNK_DURATION_MS / 1000)
PERPLEXITY_API_KEY = os.environ.get('PERPLEXITY_API_KEY', '')

# LLM correction config — uses DeepSeek via New API Gateway (cheap, fast)
LLM_CORRECT_URL = os.environ.get('LLM_CORRECT_URL', 'https://new-api-gateway-production-4801.up.railway.app/v1/chat/completions')
LLM_CORRECT_KEY = os.environ.get('LLM_CORRECT_KEY', '')
LLM_CORRECT_MODEL = os.environ.get('LLM_CORRECT_MODEL', 'deepseek-chat')

_use_llm_correct = LLM_CORRECT_KEY != ''
if _use_llm_correct:
    print(f"[VoiceCoder] LLM correction: {LLM_CORRECT_MODEL} via New API Gateway", file=sys.stderr)

# SenseVoice model path
SENSEVOICE_MODEL_DIR = os.path.expanduser('~/.cache/sherpa-onnx/sense-voice-zh')

# Tech terms correction dictionary
TECH_TERMS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'tech_terms.json')
_tech_terms_exact = {}    # {lowercase_wrong: correct}
_tech_terms_regex = []    # [(compiled_regex, correct)]

def load_tech_terms():
    global _tech_terms_exact, _tech_terms_regex
    if not os.path.exists(TECH_TERMS_PATH):
        print(f"[VoiceCoder] No tech_terms.json found, skipping correction", file=sys.stderr)
        return
    try:
        with open(TECH_TERMS_PATH, 'r', encoding='utf-8') as f:
            data = json.load(f)
        _tech_terms_exact = {k.lower(): v for k, v in data.get('exact', {}).items()}
        for pattern, replacement in data.get('regex', []):
            _tech_terms_regex.append((re.compile(pattern, re.IGNORECASE), replacement))
        print(f"[VoiceCoder] Loaded {len(_tech_terms_exact)} exact + {len(_tech_terms_regex)} regex tech terms", file=sys.stderr)
    except Exception as e:
        print(f"[VoiceCoder] Failed to load tech_terms.json: {e}", file=sys.stderr)

def correct_tech_terms(text):
    """Apply tech terms correction dictionary to transcription"""
    if not text or (not _tech_terms_exact and not _tech_terms_regex):
        return text

    original = text
    corrected = text

    # Layer 1: exact phrase replacement (case-insensitive)
    for wrong, right in _tech_terms_exact.items():
        if wrong in corrected.lower():
            # Find the actual case-matched occurrence and replace
            idx = corrected.lower().find(wrong)
            while idx != -1:
                corrected = corrected[:idx] + right + corrected[idx + len(wrong):]
                idx = corrected.lower().find(wrong, idx + len(right))

    # Layer 2: regex pattern replacement
    for pattern, right in _tech_terms_regex:
        corrected = pattern.sub(right, corrected)

    if corrected != original:
        print(f"[VoiceCoder] Tech correction: \"{original}\" → \"{corrected}\"", file=sys.stderr)

    return corrected


def load_model(model_size='sensevoice'):
    global _model
    import sherpa_onnx

    model_path = os.path.join(SENSEVOICE_MODEL_DIR, 'model.int8.onnx')
    tokens_path = os.path.join(SENSEVOICE_MODEL_DIR, 'tokens.txt')

    if not os.path.exists(model_path):
        print(f'[VoiceCoder] ERROR: SenseVoice model not found at {model_path}', file=sys.stderr)
        sys.exit(1)

    print(f"[VoiceCoder] Loading SenseVoice Small model...", file=sys.stderr)
    t0 = time.time()

    _model = sherpa_onnx.OfflineRecognizer.from_sense_voice(
        model=model_path,
        tokens=tokens_path,
        num_threads=4,
        provider='CoreML',
        language='zh',
        use_itn=True,
    )

    elapsed = time.time() - t0
    print(f"[VoiceCoder] SenseVoice loaded in {elapsed:.1f}s (int8 ONNX + CoreML)", file=sys.stderr)


def correct_terms(text):
    """Use cheap LLM (DeepSeek) to correct technical terms — only if local dict didn't fix everything"""
    if not _use_llm_correct or not text.strip():
        return text
    try:
        import httpx
        resp = httpx.post(
            LLM_CORRECT_URL,
            headers={
                'Authorization': f'Bearer {LLM_CORRECT_KEY}',
                'Content-Type': 'application/json'
            },
            json={
                'model': LLM_CORRECT_MODEL,
                'messages': [{
                    'role': 'system',
                    'content': '你是语音转写纠错助手。只修正技术/编程相关名词的语音识别错误（如GitHub/Supabase/Railway/Vercel/Cloudflare/DeepSeek/Claude/Docker/TypeScript/Nuxt/Vue/React等）。保持简体中文，不改变语义，不加解释。只输出纠错后的文本。'
                }, {
                    'role': 'user',
                    'content': text
                }],
                'max_tokens': 500,
                'temperature': 0
            },
            timeout=8
        )
        if resp.status_code == 200:
            corrected = resp.json()['choices'][0]['message']['content'].strip()
            if corrected:
                print(f"[VoiceCoder] LLM correction: \"{text}\" → \"{corrected}\"", file=sys.stderr)
                return corrected
    except Exception as e:
        print(f"[VoiceCoder] LLM correction error: {e}", file=sys.stderr)
    return text


# Hallucination filter: SenseVoice can output short garbage on very quiet audio
_HALLUCINATION_BLACKLIST = {'。', '，', '！', '？', '嗯。', '。 ', ' ', ''}

def is_hallucination(text):
    """Check if transcription result is a hallucination (gibberish from silence)"""
    text = text.strip()
    if not text:
        return True
    if text in _HALLUCINATION_BLACKLIST:
        return True
    return False


def is_speech_chunk(audio_bytes):
    """Use WebRTC VAD to check if chunk contains speech"""
    try:
        import webrtcvad
        vad = webrtcvad.Vad(0)  # 0 = least aggressive
        if len(audio_bytes) < 960:
            return False
        frame = audio_bytes[:960]
        return vad.is_speech(frame, SAMPLE_RATE)
    except Exception:
        return True


_capture_device = None  # None = default device
_stream = None          # Persistent sounddevice InputStream
_native_rate = 44100    # Will be updated to device's native rate

def audio_callback(indata, frames, time_info, status):
    """Callback for continuous audio capture via InputStream"""
    if status:
        pass  # Ignore overflow/underflow
    if _recording:
        with _audio_lock:
            _audio_chunks.append(indata.flatten().tobytes())

def capture_loop():
    """Start a persistent InputStream at native sample rate and keep it alive"""
    import sounddevice as sd

    global _stream, _native_rate

    # Use device's native sample rate to avoid quality loss from resampling
    dev_info = sd.query_devices(_capture_device or sd.default.device[0])
    _native_rate = int(dev_info['default_samplerate'])

    print(f"[VoiceCoder] Capture loop starting (device={_capture_device}, native_rate={_native_rate}Hz)", file=sys.stderr)

    _stream = sd.InputStream(
        samplerate=_native_rate,  # Native rate, sherpa-onnx will resample
        channels=1,
        dtype='int16',
        blocksize=int(_native_rate * 0.1),  # 100ms blocks
        device=_capture_device,
        callback=audio_callback,
    )
    _stream.start()
    print(f"[VoiceCoder] InputStream active: {_stream.samplerate}Hz, device={dev_info['name']}", file=sys.stderr)

    # Keep thread alive
    while True:
        time.sleep(1)


def start_recording():
    global _recording, _audio_chunks, _full_transcript
    with _recording_lock:
        if _recording:
            return
        _recording = True
        _audio_chunks = []
        _full_transcript = ""
    with _audio_lock:
        _audio_chunks = []
    print("[VoiceCoder] Recording started", file=sys.stderr)


def stop_and_transcribe():
    global _recording, _audio_chunks, _full_transcript, _model

    with _recording_lock:
        if not _recording:
            return {'error': 'not recording'}
        _recording = False

    # Collect audio chunks
    with _audio_lock:
        chunks = list(_audio_chunks)
        _audio_chunks = []

    print(f"[VoiceCoder] Recording stopped. Chunks: {len(chunks)}", file=sys.stderr)

    if not chunks:
        return {'result': ''}

    # Combine all chunks into one audio array
    audio_data = b''.join(chunks)
    audio_i16 = np.frombuffer(audio_data, dtype=np.int16)

    duration_sec = len(audio_i16) / _native_rate
    peak = np.max(np.abs(audio_i16.astype(np.float32))) / 32768.0
    rms = np.sqrt(np.mean((audio_i16.astype(np.float32) / 32768.0)**2))

    print(f"[VoiceCoder] Audio: {duration_sec:.1f}s, peak={peak:.4f}, RMS={rms:.4f}, rate={_native_rate}Hz", file=sys.stderr)

    # Skip if audio is basically silence
    if peak < 0.005:
        print(f"[VoiceCoder] Audio too quiet (peak={peak:.4f}), skipping", file=sys.stderr)
        return {'result': ''}

    # Amplify: normalize peak to 0.8 for better SenseVoice accuracy
    audio_f32 = audio_i16.astype(np.float32) / 32768.0
    if peak > 0.01:
        audio_f32 = audio_f32 * min(0.8 / peak, 15.0)  # Cap at 15x
        audio_f32 = np.clip(audio_f32, -1.0, 1.0)
    # Convert back to int16 for sherpa-onnx (it handles resampling internally)
    audio_out = (audio_f32 * 32767).astype(np.int16)
    new_peak = np.max(np.abs(audio_f32))
    print(f"[VoiceCoder] Amplified: peak {peak:.4f} → {new_peak:.4f} ({0.8/max(peak,0.01):.1f}x)", file=sys.stderr)

    if _model is None:
        return {'error': 'Model not loaded'}

    try:
        t0 = time.time()

        stream = _model.create_stream()
        stream.accept_waveform(_native_rate, audio_out.tolist())
        _model.decode_stream(stream)
        text = stream.result.text.strip()

        elapsed = time.time() - t0
        rtf = duration_sec / elapsed if elapsed > 0 else 0
        print(f"[VoiceCoder] Raw: \"{text}\" ({elapsed:.2f}s, {rtf:.1f}x realtime)", file=sys.stderr)

        # Hallucination filter
        if is_hallucination(text):
            print(f"[VoiceCoder] Filtered hallucination: \"{text}\"", file=sys.stderr)
            return {'result': ''}

        # Tech terms correction (local dictionary, instant)
        text = correct_tech_terms(text)

        # Correct technical terms with LLM (DeepSeek, cheap)
        if text and _use_llm_correct:
            text = correct_terms(text)

        _full_transcript = text
        return {'result': text}

    except Exception as e:
        print(f"[VoiceCoder] Transcription error: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc(file=sys.stderr)
        return {'error': str(e)}


def paste_to_cursor(text):
    """Paste text to active application via clipboard + Cmd+V"""
    if not text.strip():
        return
    try:
        escaped = text.replace('\\', '\\\\').replace('"', '\\"')
        script_set = f'''
        set the clipboard to "{escaped}"
        '''
        subprocess.run(['osascript', '-e', script_set], capture_output=True, timeout=5)
        time.sleep(0.05)
        script_paste = 'tell application "System Events" to keystroke "v" using command down'
        subprocess.run(['osascript', '-e', script_paste], capture_output=True, timeout=5)
        print(f"[VoiceCoder] Pasted: {text[:50]}...", file=sys.stderr)
    except Exception as e:
        print(f"[VoiceCoder] Paste error: {e}", file=sys.stderr)


def handle_client(conn):
    global _recording, _full_transcript
    try:
        data = conn.recv(8192).decode('utf-8').strip()
        if not data:
            return

        cmd = json.loads(data)
        action = cmd.get('action', '')

        print(f"[VoiceCoder] Received: {action}", file=sys.stderr)

        if action == 'start_streaming':
            start_recording()
            conn.sendall(json.dumps({'status': 'recording'}).encode())

        elif action == 'stop_streaming':
            result = stop_and_transcribe()
            if cmd.get('auto_paste', False) and result.get('result'):
                threading.Thread(
                    target=paste_to_cursor,
                    args=(result['result'],),
                    daemon=True
                ).start()
            conn.sendall(json.dumps(result).encode())

        elif action == 'ping':
            conn.sendall(json.dumps({
                'status': 'ok',
                'recording': _recording,
                'model': 'SenseVoice Small (ONNX/CoreML)',
                'lang': 'zh (简体中文)'
            }).encode())

        elif action == 'get_result':
            conn.sendall(json.dumps({
                'result': _full_transcript,
                'recording': _recording
            }).encode())

    except Exception as e:
        print(f"[VoiceCoder] Client error: {e}", file=sys.stderr)
        try:
            conn.sendall(json.dumps({'error': str(e)}).encode())
        except:
            pass
    finally:
        conn.close()


def run_server():
    global _socket_path

    if os.path.exists(_socket_path):
        os.unlink(_socket_path)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(_socket_path)
    server.listen(5)
    os.chmod(_socket_path, 0o600)

    print(f"[VoiceCoder] Server listening on {_socket_path}", file=sys.stderr)
    print(f"[VoiceCoder] Engine: SenseVoice Small | CoreML | Amplification + Hallucination filter", file=sys.stderr)

    def signal_handler(sig, frame):
        print("\n[VoiceCoder] Shutting down...", file=sys.stderr)
        if os.path.exists(_socket_path):
            os.unlink(_socket_path)
        sys.exit(0)

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    while True:
        try:
            conn, _ = server.accept()
            threading.Thread(target=handle_client, args=(conn,), daemon=True).start()
        except Exception as e:
            print(f"[VoiceCoder] Server error: {e}", file=sys.stderr)
            break


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='VoiceCoder v4 (SenseVoice)')
    parser.add_argument('--model', default='sensevoice', choices=['sensevoice'])
    parser.add_argument('--lang', default='zh')
    parser.add_argument('--socket', default='/tmp/voicecoder.sock')
    parser.add_argument('--device', type=int, default=None,
                        help='Audio input device index (None = default)')
    args = parser.parse_args()

    _socket_path = args.socket
    _capture_device = args.device

    if args.device is not None:
        import sounddevice as sd
        device_info = sd.query_devices(args.device)
        print(f"[VoiceCoder] Using audio device {args.device}: {device_info['name']}", file=sys.stderr)

    load_model(args.model)
    load_tech_terms()

    capture_thread = threading.Thread(target=capture_loop, daemon=True)
    capture_thread.start()
    print("[VoiceCoder] Capture loop thread started", file=sys.stderr)

    run_server()
