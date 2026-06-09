#!/bin/bash
# VoiceCoder v4 Startup Script — SenseVoice + DeepSeek LLM correction

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PATH="$HOME/.venv/whisper-env"
SERVICE_SCRIPT="$SCRIPT_DIR/voicecoder_service.py"
HOTKEY_BINARY="$SCRIPT_DIR/hotkey_daemon"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}[VoiceCoder v4]${NC} Starting..."

# Check if service is already running
if [ -S /tmp/voicecoder.sock ]; then
    if "$VENV_PATH/bin/python3" -c "
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(1)
try:
    s.connect('/tmp/voicecoder.sock')
    s.send(b'{\"action\":\"ping\"}')
    r = s.recv(4096)
    print('ok')
except:
    print('fail')
" 2>/dev/null | grep -q ok; then
        echo -e "${YELLOW}[VoiceCoder]${NC} Service already running."
    else
        echo -e "${YELLOW}[VoiceCoder]${NC} Stale socket, removing..."
        rm -f /tmp/voicecoder.sock
    fi
fi

# Check venv
if [ ! -d "$VENV_PATH" ]; then
    echo -e "${RED}[VoiceCoder]${NC} venv not found. Run ./install.sh first."
    exit 1
fi

# Kill existing
pkill -f "voicecoder_service.py" 2>/dev/null || true
pkill -f "hotkey_daemon" 2>/dev/null || true
sleep 1

# LLM correction key (set your own API key)
# Uses New API Gateway → DeepSeek Chat by default
# Get token from: ~/.hermes/api-keys-omnigeo.txt (prod key)
export LLM_CORRECT_KEY="${LLM_CORRECT_KEY:-}"
export LLM_CORRECT_URL="${LLM_CORRECT_URL:-https://new-api-gateway-production-4801.up.railway.app/v1/chat/completions}"
export LLM_CORRECT_MODEL="${LLM_CORRECT_MODEL:-deepseek-chat}"

echo -e "${GREEN}[VoiceCoder]${NC} LLM correction: DeepSeek via New API Gateway"

# Start Python service
echo -e "${GREEN}[VoiceCoder]${NC} Starting transcription service..."
"$VENV_PATH/bin/python3" "$SERVICE_SCRIPT" --model sensevoice --lang zh &
SERVICE_PID=$!
echo -e "${GREEN}[VoiceCoder]${NC} Service PID: $SERVICE_PID"

# Wait and verify
sleep 6
if ! "$VENV_PATH/bin/python3" -c "
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(2)
try:
    s.connect('/tmp/voicecoder.sock')
    s.send(b'{\"action\":\"ping\"}')
    r = s.recv(4096)
    print('ok')
except:
    print('fail')
" 2>/dev/null | grep -q ok; then
    echo -e "${RED}[VoiceCoder]${NC} Service failed to start!"
    exit 1
fi

echo -e "${GREEN}[VoiceCoder]${NC} Service ready!"

# Build hotkey binary if needed
if [ ! -f "$HOTKEY_BINARY" ]; then
    echo -e "${GREEN}[VoiceCoder]${NC} Building hotkey daemon..."
    cd "$SCRIPT_DIR"
    if swiftc -o hotkey_daemon hotkey_daemon.swift 2>&1 | grep -v warning; then
        echo -e "${GREEN}[VoiceCoder]${NC} Hotkey daemon built!"
    fi
fi

# Start hotkey daemon
if [ -f "$HOTKEY_BINARY" ]; then
    echo -e "${GREEN}[VoiceCoder]${NC} Starting hotkey daemon..."
    "$HOTKEY_BINARY" &
    echo -e "${GREEN}[VoiceCoder]${NC} Hotkey daemon started!"
fi

echo ""
echo -e "${GREEN}══════════════════════════════════════════════"
echo -e "  VoiceCoder v4 — SenseVoice + DeepSeek"
echo -e "══════════════════════════════════════════════"
echo ""
echo -e "  ${YELLOW}Trigger:${NC}  鼠标中键 (按住说话，松开转写)"
echo -e "  ${YELLOW}Engine:${NC}   SenseVoice Small (16.9x realtime)"
echo -e "  ${YELLOW}Correction:${NC} 本地字典(0ms) + DeepSeek LLM"
echo -e "  ${YELLOW}Language:${NC} 永远简体中文 + 自带标点"
echo ""
echo -e "  Stop: pkill -f voicecoder_service"
echo -e "  Test: $VENV_PATH/bin/python3 $SCRIPT_DIR/voicecoder_client.py test"
echo -e "${GREEN}══════════════════════════════════════════════${NC}"

wait
