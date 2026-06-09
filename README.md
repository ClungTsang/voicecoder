<div align="center">

# ◉ VoiceCoder

**开源语音输入工具 · macOS 一键安装 · 不弹终端**

按住鼠标中键说话，松开即输入 — SenseVoice + FireRedASR 双引擎 · 706 条技术名词自动纠错

[![Release](https://img.shields.io/github/v/release/ClungTsang/voicecoder?style=flat-square&color=0d9488)](https://github.com/ClungTsang/voicecoder/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)
[![Platform: macOS](https://img.shields.io/badge/Platform-macOS%20ARM64-black?style=flat-square&logo=apple)]()

</div>

---

## 为什么用 VoiceCoder？

macOS 自带听写 (F5) 识别率低、无法识别技术名词。VoiceCoder 用阿里 SenseVoice Small 引擎，本地运行，识别率远超系统听写，还内置了 706 条编程/技术名词自动纠正。

| 自带听写 F5 | VoiceCoder |
|:--|:--|
| 旧版引擎，中文弱 | SenseVoice / FireRedASR SOTA 引擎 |
| 无技术词修正 | 706 条字典 + LLM 双层纠错 |
| 无热键 | 鼠标中键（可改） |
| 不能离线 | 完全本地，隐私安全 |

## 安装（一键）

```bash
curl -fsSL https://raw.githubusercontent.com/ClungTsang/voicecoder/main/install.sh | bash
```

或手动：克隆仓库 → 编译 → 拖 `VoiceCoder.app` 到登录项。

> ⚠️ 首次启动需去「系统设置 → 隐私与安全性 → 辅助功能」授权 VoiceCoder.app。

## 架构

```
VoiceCoder.app (Swift)
├── 自动拉起 voicecoder_service.py
│   └── SenseVoice Small (ONNX + CoreML, 2.5s冷启)
│       或 FireRedASR-AED (1.1B, 中文 SOTA)
├── Unix Socket /tmp/voicecoder.sock
├── CGEvent 监听鼠标中键
└── CGEvent 模拟 Cmd+V 粘贴
```

**一个 .app 搞定一切**，不需要终端，不需要手动启动服务。

## 引擎

| 引擎 | 参数量 | 中文精度 | 启动速度 | 命令 |
|------|--------|----------|----------|------|
| **SenseVoice Small** (默认) | ~80M | ~5-8% CER | 2.5s | `--model sensevoice` |
| **FireRedASR-AED** | 1.1B | ~3.2% CER | 3.8s | `--model firered` |

预热：首次启动 SenseVoice 自动下载模型到 `~/.cache/sherpa-onnx/`；FireRedASR 需手动下载。

## 技术名词自动纠错

706 条精确匹配 + 35 条正则，覆盖：

| 类别 | 示例 |
|------|------|
| 编程语言 | Python, TypeScript, Rust, Go, Swift... |
| 前端框架 | React, Vue, Nuxt, Next.js, Tailwind... |
| 后端/数据库 | Django, FastAPI, PostgreSQL, Redis... |
| AI/ML | PyTorch, HuggingFace, LangChain, RAG... |
| 云/DevOps | Docker, Kubernetes, Railway, Vercel... |

说 `gthub` → 自动纠正为 `GitHub`，说 `raway` → `Railway`。

## API (HTTP Bridge port 19642)

| 方法 | 端点 | 说明 |
|------|------|------|
| `GET` | `/api/ping` | 服务状态 |
| `GET` | `/api/transcriptions` | 转写历史 |
| `POST` | `/api/service/start` | 启动服务 |
| `POST` | `/api/service/stop` | 停止服务 |
| `GET` | `/api/terms` | 纠错字典 |

完整文档见 [API 参考](#)。

## 从源码编译

```bash
git clone https://github.com/ClungTsang/voicecoder.git
cd voicecoder

# 编译 Swift daemon 到固定路径
swiftc -o ~/Applications/VoiceCoder.app/Contents/MacOS/VoiceCoder hotkey_daemon.swift
codesign --force --deep --sign - ~/Applications/VoiceCoder.app
```

> ⚠️ 编译必须直接写到 `~/Applications/VoiceCoder.app/Contents/MacOS/VoiceCoder`，不要从 workspace cp 替换——macOS 辅助功能权限跟二进制路径绑定，路径变了权限会丢。

## 相关仓库

| 仓库 | 说明 |
|------|------|
| [voicecoder](https://github.com/ClungTsang/voicecoder) | 本仓库：核心引擎 + .app |
| [voicecoder-desktop](https://github.com/ClungTsang/voicecoder-desktop) | Tauri 桌面端（已弃用，推荐 .app） |
| [voicecoder-site](https://github.com/ClungTsang/voicecoder-site) | 官网 Landing Page |

## License

[MIT](LICENSE)

---

<div align="center">
Made with ♥ by <a href="https://github.com/ClungTsang">ClungTsang</a>
</div>
