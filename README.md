<div align="center">

# ◉ VoiceCoder

**开源语音输入工具 · 核心后端**

SenseVoice Small 语音引擎 · HTTP API Bridge · 热键守护 · 技术名词纠错

[![Release](https://img.shields.io/github/v/release/ClungTsang/voicecoder?style=flat-square&color=0d9488)](https://github.com/ClungTsang/voicecoder/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)
[![Python 3.10+](https://img.shields.io/badge/Python-3.10+-blue?style=flat-square&logo=python)]()

</div>

---

## 架构

```
┌──────────────────┐     HTTP (port 19642)     ┌────────────────────┐
│  VoiceCoder      │ ◄────────────────────────► │  voicecoder_api.py │
│  Desktop (Tauri) │                            │  (HTTP API Bridge) │
└──────────────────┘                            └────────┬───────────┘
                                                         │ Socket / TCP
                                                ┌────────▼───────────┐
                                                │ voicecoder_service │
                                                │ (SenseVoice STT)   │
                                                └────────▲───────────┘
                                                         │
                                                ┌────────┴───────────┐
                                                │ voicecoder_daemon  │
                                                │ (热键守护进程)      │
                                                └────────────────────┘
```

| 组件 | 说明 |
|------|------|
| `voicecoder_api.py` | HTTP REST API Bridge，16+ 端点，SQLite 持久化 |
| `voicecoder_service.py` | 语音转写引擎 (SenseVoice Small ONNX/CoreML) |
| `voicecoder_daemon.py` | 热键守护进程 (监听鼠标中键) |
| `tech_terms.json` | 技术名词纠错字典 |

## 安装

### 一键安装（macOS）

```bash
curl -fsSL https://raw.githubusercontent.com/ClungTsang/voicecoder/main/install.sh | bash
```

### 手动安装

```bash
git clone https://github.com/ClungTsang/voicecoder.git
cd voicecoder

# 创建虚拟环境
python3 -m venv venv
source venv/bin/activate

# 安装依赖
pip install -r requirements.txt

# 启动
python voicecoder_api.py  # HTTP API Bridge (port 19642)
python voicecoder_daemon.py  # 热键守护 (需要另一个终端)
```

## 配置

### 环境变量

创建 `.env` 文件（不提交到 git）：

```bash
# GitHub OAuth (桌面端登录)
GITHUB_CLIENT_ID=your_client_id
GITHUB_CLIENT_SECRET=your_client_secret

# Perplexity API (搜索功能，可选)
PERPLEXITY_API_KEY=pplx-xxx
```

### GitHub OAuth 配置

1. 前往 https://github.com/settings/developers
2. 创建 OAuth App
3. Authorization callback URL: `http://127.0.0.1:19642/api/auth/github/callback`
4. 将 Client ID 和 Client Secret 写入 `.env`

## API 文档

HTTP API Bridge 运行在 `http://127.0.0.1:19642`

### 服务状态

| 方法 | 端点 | 说明 |
|------|------|------|
| `GET` | `/api/ping` | 服务状态（代理到后端 Socket） |

### 转写历史

| 方法 | 端点 | 说明 |
|------|------|------|
| `GET` | `/api/transcriptions` | 列表（支持 `q`, `from`, `to`, `limit` 参数） |
| `POST` | `/api/transcriptions` | 新增记录 |
| `GET` | `/api/transcriptions/:id` | 单条查看 |
| `DELETE` | `/api/transcriptions/:id` | 删除 |
| `PATCH` | `/api/transcriptions/:id/star` | 收藏/取消 |

### 设置

| 方法 | 端点 | 说明 |
|------|------|------|
| `GET` | `/api/settings` | 读取所有设置 |
| `PATCH` | `/api/settings` | 更新设置（JSON body） |

### 模型 & 设备

| 方法 | 端点 | 说明 |
|------|------|------|
| `GET` | `/api/models` | 可用模型列表 + 当前标记 |
| `GET` | `/api/devices` | 音频输入设备列表 |
| `GET` | `/api/devices/test` | 录音 2 秒测试音量（支持 `?device=N`） |

### 技术名词

| 方法 | 端点 | 说明 |
|------|------|------|
| `GET` | `/api/terms` | 读取纠错字典 |
| `POST` | `/api/terms` | 添加词条 (`{wrong, correct}`) |
| `DELETE` | `/api/terms/:id` | 删除词条 |

### 服务管理

| 方法 | 端点 | 说明 |
|------|------|------|
| `POST` | `/api/service/start` | 启动转写服务 + 热键守护 |
| `POST` | `/api/service/stop` | 停止所有服务 |

### 认证

| 方法 | 端点 | 说明 |
|------|------|------|
| `GET` | `/api/auth/github/url` | 获取 OAuth 授权 URL |
| `GET` | `/api/auth/github/callback` | OAuth 回调（自动交换 token） |
| `GET` | `/api/auth/user` | 当前登录用户 |
| `POST` | `/api/auth/logout` | 登出 |

### 更新

| 方法 | 端点 | 说明 |
|------|------|------|
| `GET` | `/api/updates/check` | 检查 GitHub Releases 更新 |

## SQLite Schema

```sql
-- 转写历史
CREATE TABLE transcriptions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    text TEXT NOT NULL,
    created_at TEXT DEFAULT (datetime('now')),
    duration_ms INTEGER,
    word_count INTEGER,
    model TEXT,
    starred INTEGER DEFAULT 0
);

-- 设置（key-value）
CREATE TABLE settings (
    key TEXT PRIMARY KEY,
    value TEXT
);

-- 用户（GitHub OAuth）
CREATE TABLE users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    github_id INTEGER UNIQUE,
    login TEXT,
    name TEXT,
    avatar_url TEXT,
    access_token TEXT,
    created_at TEXT DEFAULT (datetime('now'))
);
```

## 相关仓库

| 仓库 | 说明 |
|------|------|
| [voicecoder](https://github.com/ClungTsang/voicecoder) | 本仓库：核心后端 |
| [voicecoder-desktop](https://github.com/ClungTsang/voicecoder-desktop) | 桌面端 UI (Tauri v2 + Vue 3) |
| [voicecoder-site](https://github.com/ClungTsang/voicecoder-site) | 官网 |

## License

[MIT](LICENSE)

---

<div align="center">
Made with ♥ by <a href="https://github.com/ClungTsang">ClungTsang</a>
</div>
