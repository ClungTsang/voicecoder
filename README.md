# VoiceCoder v4

> 🎙️ 按住鼠标中键说话，松开自动转写并粘贴 — 程序员"动口不动手"的语音输入工具

基于阿里通义 **SenseVoice Small** 模型，专为中英文混合编程场景优化，支持技术名词纠错。

## ✨ 特性

- **🖱️ 鼠标中键触发** — 无需记快捷键，按住说话、松开转写
- **🇨🇳 永远简体中文** — SenseVoice 非自回归架构，零繁体、零幻觉
- **📝 自带标点符号** — 转写结果自带逗号句号，无需后处理
- **⚡ 极速转写** — 16.9x 实时速度，0.2 秒完成转录
- **🔧 技术名词纠错** — 内置 87 个技术名词白名单（GitHub, Railway, Supabase, Cloudflare...）+ DeepSeek LLM 兜底
- **💻 本地运行** — 模型和转写全程本地，不依赖云服务
- **🔄 开机自启** — launchd 守护进程，崩溃自动恢复
- **🪶 轻量低耗** — 空闲时 CPU ~0%，内存 ~290 MB

## 🚀 快速开始

### 环境要求

- macOS 14.0+（Apple Silicon M 系列推荐）
- Python 3.11+
- Xcode Command Line Tools（编译 Swift 热键守护进程）

### 安装

**一行命令安装（推荐）：**

```bash
curl -fsSL https://voicecoder.org/install.sh | bash
```

**或者手动安装：**

```bash
git clone https://github.com/ClungTsang/voicecoder.git ~/workspace/voicecoder
cd ~/workspace/voicecoder
./install.sh
```

### 使用

1. 将光标移到任意文本输入框
2. **按住鼠标中键（滚轮按下）**
3. 对着麦克风说话
4. **松开鼠标中键** → 自动转写并粘贴

> ⚠️ 首次使用需要在 **系统设置 → 隐私与安全性 → 辅助功能** 中授权 VoiceCoder。

## 🧠 技术架构

```
┌─────────────────────────────────────────────────────┐
│                    VoiceCoder v4                      │
├─────────────────────────────────────────────────────┤
│  [鼠标中键]  →  hotkey_daemon (Swift/CGEvent)        │
│       │                                              │
│       ▼                                              │
│  [音频采集]  →  sounddevice InputStream (44.1kHz)    │
│       │                                              │
│       ▼                                              │
│  [归一化放大] → 峰值放大到 0.8（适配 EarPods 低音量） │
│       │                                              │
│       ▼                                              │
│  [语音转写]  →  SenseVoice Small (sherpa-onnx)       │
│       │            ONNX int8 + CoreML 加速            │
│       ▼                                              │
│  [幻觉过滤]  →  正则匹配过滤纯标点/单字输出            │
│       │                                              │
│       ▼                                              │
│  [第1层纠错] →  87 个技术名词字典 (0ms, 免费)         │
│       │                                              │
│       ▼                                              │
│  [第2层纠错] →  DeepSeek LLM (~1s, ¥0.001/次)        │
│       │                                              │
│       ▼                                              │
│  [粘贴到光标] →  osascript Cmd+V                      │
└─────────────────────────────────────────────────────┘
```

## 📦 项目结构

```
voicecoder/
├── voicecoder_service.py    # 核心转写服务（Unix Socket 通信）
├── voicecoder_client.py     # 客户端 CLI（ping/status 命令）
├── hotkey_daemon.swift      # 鼠标中键监听守护进程
├── tech_terms.json          # 技术名词纠错字典（87 个精确匹配 + 11 个正则）
├── install.sh               # 一键安装脚本
├── start.sh                 # 手动启动脚本（含 API key 配置）
├── com.voicecoder.service.plist  # launchd 服务配置（开机自启）
├── com.voicecoder.hotkey.plist   # launchd 热键监听配置
└── README.md                # 本文档
```

## ⚙️ 配置

### 模型

默认使用 **SenseVoice Small int8 ONNX + CoreML** 加速，模型自动下载到 `~/.cache/sherpa-onnx/sense-voice-zh/`（约 1.1 GB）。

### LLM 纠错

默认使用 DeepSeek Chat（通过 New API Gateway，极低成本）。如需更换：

```bash
export LLM_CORRECT_KEY="your-api-key"
export LLM_CORRECT_URL="https://your-endpoint/v1/chat/completions"
export LLM_CORRECT_MODEL="deepseek-chat"
```

### 技术名词字典

编辑 `tech_terms.json` 添加自定义词条，重启服务即生效：

```json
{
  "exact": {
    "误识别文本": "正确文本"
  },
  "regex": [
    ["正则匹配(大小写不敏感)", "正确文本"]
  ]
}
```

## 📊 资源占用

| 指标 | 数值 |
|------|------|
| 空闲内存 | ~290 MB（含 1.1 GB ONNX 模型加载） |
| 空闲 CPU | ~0% |
| 转写时 CPU | 瞬时 ~10%（持续 < 1 秒） |
| 模型加载时 CPU | ~25%（仅启动时 ~25 秒） |
| 24 GB Mac 占比 | ~1.3% |

## 🔧 故障排查

```bash
# 查看服务状态
python3 voicecoder_client.py ping

# 查看服务日志
tail -f /tmp/voicecoder-stderr.log
tail -f /tmp/voicecoder-hotkey-stderr.log

# 手动重启
launchctl unload ~/Library/LaunchAgents/com.voicecoder.service.plist
launchctl unload ~/Library/LaunchAgents/com.voicecoder.hotkey.plist
launchctl load ~/Library/LaunchAgents/com.voicecoder.service.plist
launchctl load ~/Library/LaunchAgents/com.voicecoder.hotkey.plist
```

## 为什么选择 SenseVoice 而非 Whisper？

| 指标 | SenseVoice Small | Whisper Small |
|------|------------------|---------------|
| 中文准确率 (CER) | **~4.2%** | ~10.1% |
| 简繁体 | **永远简体** | 混出繁体 |
| 标点符号 | **自带** | 需后处理 |
| 幻觉 | **非自回归，零幻觉** | 有（"字幕 by 索兰娅"） |
| 速度 | **16.9x 实时** | 2.3x 实时 |
| 模型大小 | 1.1 GB | 500 MB |
| 加载时间 | ~25s (CoreML) | ~5s |

## 📄 许可

MIT License — 自由使用、修改、分发。
