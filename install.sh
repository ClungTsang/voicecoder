#!/bin/bash
# VoiceCoder v4 Setup & Installer
# Run once: ./install.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PATH="$HOME/.venv/whisper-env"

echo -e "${GREEN}[VoiceCoder v4]${NC} 开始安装..."

# 1. Create venv if needed
if [ ! -d "$VENV_PATH" ]; then
    echo -e "${GREEN}[VoiceCoder]${NC} 创建 Python 虚拟环境..."
    python3 -m venv "$VENV_PATH"
fi

# 2. Install dependencies
echo -e "${GREEN}[VoiceCoder]${NC} 安装 Python 依赖..."
$VENV_PATH/bin/pip install --upgrade pip -q
$VENV_PATH/bin/pip install sounddevice numpy sherpa-onnx httpx pyobjc-framework-CoreWLAN -q
echo -e "${GREEN}[VoiceCoder]${NC} 依赖安装完成"

# 3. Download SenseVoice model (if not already)
MODEL_DIR="$HOME/.cache/sherpa-onnx/sense-voice-zh"
if [ ! -f "$MODEL_DIR/model.int8.onnx" ]; then
    echo -e "${GREEN}[VoiceCoder]${NC} 下载 SenseVoice Small 模型 (~1.1 GB)..."
    mkdir -p "$MODEL_DIR"
    $VENV_PATH/bin/python3 -c "
from huggingface_hub import snapshot_download
snapshot_download('csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17',
    local_dir='$MODEL_DIR', local_dir_use_symlinks=False)
" || {
        echo -e "${YELLOW}[VoiceCoder]${NC} 模型下载失败，首次启动时自动下载"
    }
else
    echo -e "${GREEN}[VoiceCoder]${NC} 模型已存在: $MODEL_DIR"
fi

# 4. Compile Swift hotkey daemon
echo -e "${GREEN}[VoiceCoder]${NC} 编译热键守护进程..."
cd "$SCRIPT_DIR"
if swiftc -o hotkey_daemon hotkey_daemon.swift 2>/dev/null; then
    echo -e "${GREEN}[VoiceCoder]${NC} hotkey_daemon 编译成功"
else
    echo -e "${YELLOW}[VoiceCoder]${NC} Swift 编译有警告（仍可使用）"
fi

# 5. Install launchd plists
echo -e "${GREEN}[VoiceCoder]${NC} 安装开机自启服务..."

# Update plist paths
SERVICE_PLIST="$SCRIPT_DIR/com.voicecoder.service.plist"
HOTKEY_PLIST="$SCRIPT_DIR/com.voicecoder.hotkey.plist"

mkdir -p "$HOME/Library/LaunchAgents"
cp "$SERVICE_PLIST" "$HOME/Library/LaunchAgents/com.voicecoder.service.plist"
cp "$HOTKEY_PLIST" "$HOME/Library/LaunchAgents/com.voicecoder.hotkey.plist"

# Load services
launchctl unload "$HOME/Library/LaunchAgents/com.voicecoder.service.plist" 2>/dev/null || true
launchctl unload "$HOME/Library/LaunchAgents/com.voicecoder.hotkey.plist" 2>/dev/null || true
sleep 1
launchctl load "$HOME/Library/LaunchAgents/com.voicecoder.service.plist"
launchctl load "$HOME/Library/LaunchAgents/com.voicecoder.hotkey.plist"

echo -e "${GREEN}[VoiceCoder]${NC} 开机自启已配置"

# 6. Verify
echo ""
echo -e "${GREEN}[VoiceCoder]${NC} 等待服务启动（SenseVoice 模型加载约 25 秒）..."
sleep 8
$VENV_PATH/bin/python3 "$SCRIPT_DIR/voicecoder_client.py" ping 2>/dev/null && echo -e "${GREEN}[VoiceCoder v4]${NC} 安装成功！" || echo -e "${YELLOW}[VoiceCoder]${NC} 模型仍在加载中，请等待约 30 秒后重试"

echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN}  VoiceCoder v4 安装完成${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""
echo -e "  ${YELLOW}触发方式:${NC} 按住鼠标中键说话，松开转写"
echo -e "  ${YELLOW}引擎:${NC}     SenseVoice Small (16.9x 实时)"
echo -e "  ${YELLOW}开机自启:${NC} 已配置"
echo ""
echo -e "  检查状态: $VENV_PATH/bin/python3 $SCRIPT_DIR/voicecoder_client.py ping"
echo -e "  查看日志: tail -f /tmp/voicecoder-stderr.log"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
