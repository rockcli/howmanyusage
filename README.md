<div align="center">

<img src="docs/icon.png" alt="HowManyUsage icon" width="76" height="76" />

# HowManyUsage

**A lightweight macOS menu bar monitor for your AI coding & compute quotas.**

[![macOS](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white)](https://github.com/rockcli/howmanyusage)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&logoColor=white)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

English | [简体中文](README.zh-CN.md)

<br />

<img src="docs/screenshot.png" alt="HowManyUsage popover screenshot" width="420" />

</div>

## Features

- 🔍 **Auto-detection** — Only shows providers installed on your Mac (CLI, desktop app, local config, or the `colab-operator` skill). Uninstalled tools stay hidden.
- 📊 **Quotas & forecasts** — Weekly/5-hour progress bars with today's burn marker, exhaustion warnings, unused-quota hints, burn-spike alerts, and API-equivalent plan value.
- 📈 **Summary & speed** — 7-day stacked token chart, 14-week activity heatmap, and 4-hour average model speed (`TTFT`, `Output tok/s`, `Cache %`).
- 🔒 **Local & read-only** — Reuses existing local login state and logs. Zero telemetry, zero external backend, and never refreshes or modifies OAuth tokens.

## Supported Providers

| Provider | Auto-Detected Via | Source |
|----------|-------------------|--------|
| **Codex** | `codex` CLI, `Codex.app`, `~/.codex` | `chatgpt.com/backend-api/wham/usage` + local sessions |
| **Claude** | `claude` CLI, `Claude.app`, `~/.claude`, Claude Desktop config | `api.anthropic.com/api/oauth/usage` + local projects |
| **Google (Antigravity)** | `agy` / `antigravity`, `Antigravity.app`, `~/.gemini/antigravity*` | Local Antigravity daemon RPC + transcripts |
| **DeepSeek** | `dsh` / `pi`, `DeepSeek.app`, `DEEPSEEK_API_KEY` | `api.deepseek.com/user/balance` + local `pi`/`dsh` logs |
| **Colab** | `colab-operator` skill, `colab` CLI, `~/.config/colab-cli` | `colab.research.google.com/tun/m/ccu-info` |

## Quick Start

Requires **macOS 13+** and **Xcode Command Line Tools** (`xcode-select --install`).

```bash
git clone https://github.com/rockcli/howmanyusage.git
cd howmanyusage
./scripts/install.sh
```

`./scripts/install.sh` builds locally, installs `/Applications/HowManyUsage.app`, enables login autostart via LaunchAgent, and launches the menu bar icon.

**Uninstall:**

```bash
launchctl unload ~/Library/LaunchAgents/com.local.howmanyusage.plist
rm -f ~/Library/LaunchAgents/com.local.howmanyusage.plist
rm -rf /Applications/HowManyUsage.app
```

## CLI & Development

```bash
swift test --package-path app                # run unit tests
./app/.build/debug/HowManyUsage --once       # print one-shot text report
./app/.build/debug/HowManyUsage --speed      # print 4h model speed table
```

## Disclaimer

All requests go directly from your Mac to each provider's endpoint using your local credentials. Some quota endpoints and desktop storage formats are unofficial/internal interfaces and may change with upstream updates.

## License

[MIT](LICENSE) © [rockcli](https://github.com/rockcli)
