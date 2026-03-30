# 🎬 mpv 中文版统计脚本 (stats.lua)

[![GitHub release (latest by date)](https://img.shields.io/github/v/release/yosh-wang/mpv-stats-zh-or-mpv-stats-chinese-stats.lua)](https://github.com/yosh-wang/mpv-stats-zh-or-mpv-stats-chinese-stats.lua/releases)
[![GitHub stars](https://img.shields.io/github/stars/yosh-wang/mpv-stats-zh-or-mpv-stats-chinese-stats.lua)](https://github.com/yosh-wang/mpv-stats-zh-or-mpv-stats-chinese-stats.lua/stargazers)
[![GitHub license](https://img.shields.io/github/license/yosh-wang/mpv-stats-zh-or-mpv-stats-chinese-stats.lua)](https://github.com/yosh-wang/mpv-stats-zh-or-mpv-stats-chinese-stats.lua/blob/main/LICENSE)
[![GitHub last commit](https://img.shields.io/github/last-commit/yosh-wang/mpv-stats-zh-or-mpv-stats-chinese-stats.lua)](https://github.com/yosh-wang/mpv-stats-zh-or-mpv-stats-chinese-stats.lua/commits/main)

> **mpv 内置统计脚本 `stats.lua` 的完整中文翻译版**  
> **Fully translated Chinese version** of mpv's built-in stats script `stats.lua`
>
> – 将 mpv 内置统计脚本 `stats.lua` 的所有界面、提示和菜单全部中文化，让你更轻松地查看播放信息。

📄 原版英文文件：[stats.lua](https://github.com/mpv-player/mpv/blob/master/player/lua/stats.lua)  
📄 Original English file：[stats.lua](https://github.com/mpv-player/mpv/blob/master/player/lua/stats.lua)  
---
## ✨ 特性 / Features

- **中文界面** – 所有统计信息、菜单选项、按键提示均完整翻译  
  **Chinese UI** – All stats info, menus, and tooltips are fully translated
- **功能同步** – 与原版保持同步，支持所有快捷键和页面切换  
  **Feature‑complete** – Synchronized with upstream, supports all hotkeys and page toggles
- **即装即用** – 两步安装，无需额外配置  
  **Plug and play** – Simple two‑step installation, no extra configuration
- **轻量高效** – 单文件，不占用额外资源  
  **Lightweight** – Single file, minimal overhead
---
## 📥 安装 / Installation

**禁用内置英文脚本**  
Disable the built‑in English script

在你的 `mpv.conf` 文件中添加以下一行：  
Add the following line to your `mpv.conf`:

```ini
load-stats-overlay=no
```
