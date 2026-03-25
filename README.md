# mpv 中文统计脚本 (stats.lua)

[![GitHub发布（按日期最新）](https://img.shields.io/github/v/release/yosh-wang/mpv-stats-zh-or-mpv-stats-chinese-stats.lua)](https://github.com/yosh-wang/mpv-stats-zh-or-mpv-stats-chinese-stats.lua/releases)
[![GitHub 星标](https://img.shields.io/github/stars/yosh-wang/mpv-stats-zh-or-mpv-stats-chinese-stats.lua)](https://github.com/yosh-wang/mpv-stats-zh-or-mpv-stats-chinese-stats.lua/stargazers)
[![GitHub 许可证](https://img.shields.io/github/license/yosh-wang/mpv-stats-zh-or-mpv-stats-chinese-stats.lua)](https://github.com/yosh-wang/mpv-stats-zh-or-mpv-stats-chinese-stats.lua/blob/main/LICENSE)
[![GitHub 最新提交](https://img.shields.io/github/last-commit/yosh-wang/mpv-stats-zh-or-mpv-stats-chinese-stats.lua)](https://github.com/yosh-wang/mpv-stats-zh-or-mpv-stats-chinese-stats.lua/commits/main)

本项目是 mpv 播放器内置统计脚本 `stats.lua` 的**完整中文翻译版**。  
原版英文文件位于：[mpv-player/mpv/player/lua/stats.lua](https://github.com/mpv-player/mpv/blob/master/player/lua/stats.lua)

##✨ 特性

- **中文界面**：所有统计信息、菜单选项、提示文字均翻译为中文
- **功能完整**：与原版保持同步，支持所有快捷键和页面切换
- **开箱即用**：简单两步安装，无需额外配置
- **轻量高效**：单文件，不占用额外资源

<p align="center">
  <img width="600" alt="统计信息界面" src="screenshot.png">
</p>

## 📥 安装


### 1. 禁用原版英文脚本
在 mpv.conf 中添加一行：
``` ini 
加载统计覆盖=否

