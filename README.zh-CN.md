<div align="center">

<img src="docs/icon.png" alt="HowManyUsage icon" width="76" height="76" />

# HowManyUsage

**轻量级 macOS 菜单栏工具，一站式监控你的 AI 编程与算力额度。**

[![macOS](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white)](https://github.com/rockcli/howmanyusage)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&logoColor=white)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

[English](README.md) | 简体中文

<br />

<img src="docs/screenshot.png" alt="HowManyUsage 菜单栏弹窗截图" width="420" />

</div>

## 核心特性

- 🔍 **自动探测本机工具** — 自动检测本机已安装的 CLI、桌面客户端、本地配置或 `colab-operator` 技能；未安装的工具自动隐藏，不显示空白占位。
- 📊 **额度与消耗预测** — 展示周额度 / 5 小时进度条、今日消耗分割线、耗尽预警、剩余额度提醒、短时突增告警以及按本地日志估算的订阅价值倍数。
- 📈 **汇总图表与模型测速** — 内置近 7 天分平台 Token 柱状图、14 周活跃度热力图，以及近 4 小时模型实测速度表（`TTFT`、`Output tok/s`、`Cache %`）。
- 🔒 **纯本地只读** — 复用各工具本机已有登录态与日志；无第三方服务器、无遥测上报，且绝不刷新或改动原有 OAuth Token。

## 支持平台

| 平台 | 自动探测依据（CLI / 客户端 / 配置） | 数据来源 |
|------|------------------------------------|----------|
| **Codex** | `codex` CLI、`Codex.app`、`~/.codex` | `chatgpt.com/backend-api/wham/usage` + 本地会话日志 |
| **Claude** | `claude` CLI、`Claude.app`、`~/.claude`、Claude Desktop 配置 | `api.anthropic.com/api/oauth/usage` + 本地项目日志 |
| **Google (Antigravity)** | `agy` / `antigravity`、`Antigravity.app`、`~/.gemini/antigravity*` | 本地 Antigravity daemon RPC + 对话日志 |
| **DeepSeek** | `dsh` / `pi`、`DeepSeek.app`、`DEEPSEEK_API_KEY` | `api.deepseek.com/user/balance` + 本地 `pi`/`dsh` 日志 |
| **Colab** | `colab-operator` 技能、`colab` CLI、`~/.config/colab-cli` | `colab.research.google.com/tun/m/ccu-info` |

## 快速开始

环境要求：**macOS 13+** 与 **Xcode Command Line Tools**（`xcode-select --install`，无需安装完整 Xcode）。

```bash
git clone https://github.com/rockcli/howmanyusage.git
cd howmanyusage
./scripts/install.sh
```

`./scripts/install.sh` 会在本机编译 Release 版本、安装到 `/Applications/HowManyUsage.app`、配置 LaunchAgent 开机自启并启动菜单栏图标。

**卸载：**

```bash
launchctl unload ~/Library/LaunchAgents/com.local.howmanyusage.plist
rm -f ~/Library/LaunchAgents/com.local.howmanyusage.plist
rm -rf /Applications/HowManyUsage.app
```

## 命令行与开发

```bash
swift test --package-path app                # 运行单元测试
./app/.build/debug/HowManyUsage --once       # 终端打印单次用量报告
./app/.build/debug/HowManyUsage --speed      # 终端打印近 4 小时模型速度表
```

## 免责声明

所有请求均直接从本机发往对应平台接口，不经过任何中间服务。部分额度接口与客户端本地存储格式属于非公开/内部实现，可能随上游客户端更新而变化。

## 许可证

[MIT](LICENSE) © [rockcli](https://github.com/rockcli)
