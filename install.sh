#!/bin/bash
# VoiceCoder v4 — 一键安装脚本
# Usage: curl -fsSL https://voicecoder-site-production.up.railway.app/install.sh | bash
#   or: curl -fsSL https://clungtsang.github.io/voicecoder-site/install.sh | bash

set -e

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;2m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()  { echo -e "  ${GREEN}▸${NC} $1"; }
warn()  { echo -e "  ${DIM}⚠${NC} $1"; }
fail()  { echo -e "  ${RED}✗${NC} $1"; exit 1; }

INSTALL_DIR="$HOME/workspace/voicecoder"
VENV_PATH="$HOME/.venv/whisper-env"
REPO_URL="https://github.com/ClungTsang/voicecoder.git"
MODEL_DIR="$HOME/.cache/sherpa-onnx/sense-voice-zh"

echo ""
echo -e "  ${BOLD}VoiceCoder v4${NC} ${DIM}— 按住说话，松开转写${NC}"
echo -e "  ${DIM}─────────────────────────────────────${NC}"
echo ""

# ── 0. Pre-flight checks ──
info "检查系统环境..."

[[ "$(uname)" != "Darwin" ]] && fail "VoiceCoder 仅支持 macOS"
[[ "$(uname -m)" != "arm64" ]] && warn "推荐 Apple Silicon (M 系列芯片)，Intel 也可运行但速度较慢"
command -v python3 >/dev/null 2>&1 || fail "需要 Python 3.11+，请先安装: brew install python3"
command -v swiftc >/dev/null 2>&1 || fail "需要 Xcode Command Line Tools，请先运行: xcode-select --install"

PYTHON_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
PYTHON_OK=$(python3 -c 'import sys; exit(0 if sys.version_info >= (3,11) else 1)')
[[ $? -ne 0 ]] && fail "Python 版本 $PYTHON_VER 太低，需要 3.11+"

info "macOS ✓ · Python $PYTHON_VER ✓ · Swift ✓"

# ── 1. Clone repo ──
if [ -d "$INSTALL_DIR/.git" ]; then
    info "仓库已存在，更新到最新版..."
    cd "$INSTALL_DIR"
    git pull --ff-only 2>/dev/null || warn "git pull 失败，使用现有版本"
else
    info "克隆仓库 → $INSTALL_DIR"
    mkdir -p "$(dirname "$INSTALL_DIR")"
    git clone "$REPO_URL" "$INSTALL_DIR" --depth 1
    cd "$INSTALL_DIR"
fi

# ── 2. Create venv & install deps ──
if [ ! -d "$VENV_PATH" ]; then
    info "创建 Python 虚拟环境..."
    python3 -m venv "$VENV_PATH"
fi

info "安装依赖 (sounddevice, sherpa-onnx, httpx)..."
$VENV_PATH/bin/pip install --upgrade pip -q 2>/dev/null
$VENV_PATH/bin/pip install sounddevice numpy sherpa-onnx httpx -q 2>/dev/null

# ── 3. Download model ──
if [ -f "$MODEL_DIR/model.int8.onnx" ]; then
    info "SenseVoice 模型已存在 ✓"
else
    info "下载 SenseVoice Small 模型 (~1.1 GB，首次需要)..."
    mkdir -p "$MODEL_DIR"
    $VENV_PATH/bin/pip install huggingface_hub -q 2>/dev/null
    $VENV_PATH/bin/python3 -c "
from huggingface_hub import snapshot_download
snapshot_download(
    'csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17',
    local_dir='$MODEL_DIR',
    local_dir_use_symlinks=False
)
" || warn "模型下载失败，首次启动时会自动重试"
fi

# ── 4. Compile Swift hotkey daemon ──
info "编译热键守护进程..."
if swiftc -o "$INSTALL_DIR/hotkey_daemon" "$INSTALL_DIR/hotkey_daemon.swift" 2>/dev/null; then
    info "hotkey_daemon 编译成功 ✓"
else
    warn "Swift 编译有警告（仍可正常使用）"
fi

# ── 5. Generate launchd plists ──
info "配置开机自启..."

mkdir -p "$HOME/Library/LaunchAgents"

# Service plist
cat > "$HOME/Library/LaunchAgents/com.voicecoder.service.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.voicecoder.service</string>
    <key>ProgramArguments</key>
    <array>
        <string>${VENV_PATH}/bin/python3</string>
        <string>${INSTALL_DIR}/voicecoder_service.py</string>
        <string>--model</string>
        <string>sensevoice</string>
        <string>--lang</string>
        <string>zh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/voicecoder-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/voicecoder-stderr.log</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
PLIST

# Hotkey plist
cat > "$HOME/Library/LaunchAgents/com.voicecoder.hotkey.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.voicecoder.hotkey</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_DIR}/hotkey_daemon</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/voicecoder-hotkey-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/voicecoder-hotkey-stderr.log</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
PLIST

# Stop old instances
pkill -f voicecoder_service.py 2>/dev/null || true
pkill -f hotkey_daemon 2>/dev/null || true
sleep 1

launchctl unload "$HOME/Library/LaunchAgents/com.voicecoder.service.plist" 2>/dev/null || true
launchctl unload "$HOME/Library/LaunchAgents/com.voicecoder.hotkey.plist" 2>/dev/null || true
sleep 1
launchctl load "$HOME/Library/LaunchAgents/com.voicecoder.service.plist"
launchctl load "$HOME/Library/LaunchAgents/com.voicecoder.hotkey.plist"

# ── 6. Verify ──
info "等待服务启动（模型加载约 25 秒）..."
sleep 8

echo ""
if $VENV_PATH/bin/python3 "$INSTALL_DIR/voicecoder_client.py" ping 2>/dev/null; then
    echo ""
    echo -e "  ${BOLD}✓ VoiceCoder v4 安装成功${NC}"
else
    echo ""
    echo -e "  ${DIM}⏳ 模型仍在加载中，请等待约 30 秒后执行:${NC}"
    echo -e "  ${DIM}  $VENV_PATH/bin/python3 $INSTALL_DIR/voicecoder_client.py ping${NC}"
fi

echo ""
echo -e "  ${DIM}─────────────────────────────────────${NC}"
echo -e "  ${BOLD}触发方式:${NC} 按住鼠标中键说话，松开转写"
echo -e "  ${BOLD}检查状态:${NC} $VENV_PATH/bin/python3 $INSTALL_DIR/voicecoder_client.py ping"
echo -e "  ${BOLD}查看日志:${NC} tail -f /tmp/voicecoder-stderr.log"
echo -e "  ${BOLD}卸载:${NC}     $INSTALL_DIR/install.sh --uninstall"
echo -e "  ${DIM}─────────────────────────────────────${NC}"
echo ""

# ── Uninstall ──
if [[ "${1:-}" == "--uninstall" ]]; then
    echo ""
    info "卸载 VoiceCoder..."

    launchctl unload "$HOME/Library/LaunchAgents/com.voicecoder.service.plist" 2>/dev/null || true
    launchctl unload "$HOME/Library/LaunchAgents/com.voicecoder.hotkey.plist" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/com.voicecoder.service.plist"
    rm -f "$HOME/Library/LaunchAgents/com.voicecoder.hotkey.plist"

    echo ""
    echo -e "  ${BOLD}✓ VoiceCoder 已卸载${NC}"
    echo -e "  ${DIM}仓库和模型未删除:${NC}"
    echo -e "  ${DIM}  $INSTALL_DIR${NC}"
    echo -e "  ${DIM}  $MODEL_DIR${NC}"
    echo -e "  ${DIM}  $VENV_PATH${NC}"
    echo ""
    exit 0
fi
