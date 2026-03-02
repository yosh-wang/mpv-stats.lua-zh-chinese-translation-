### MPV内置代码连接
未翻译的英文原始文件地址:https://github.com/mpv-player/mpv/blob/master/player/lua/stats.lua

### 展示图片
<img width="3837" height="2154" alt="微信图片_2026-03-01_112007_816" src="https://github.com/user-attachments/assets/34541caf-e934-4ef8-84f4-75fa6c37e707" />

### 使用方法

步骤 1：编辑主配置文件
在你的 mpv.conf 文件中，添加或确认以下一行。这行代码会关闭 mpv 内置的英文版统计脚本，为我们的中文版脚本让路。
load-stats-overlay=no                                                          # 启用 mpv 内置的统计信息脚本 [stats.lua]，默认 yes

步骤 2：放置中文版脚本
将我们的翻译 stats.lua 文件放入 mpv 的 scripts 文件夹。

目标位置: portable_config/scripts/

步骤 3：开始享用
按 i 键：临时查看全中文的播放统计信息。
按 I (大写) 键：让统计信息常驻屏幕。
按 Shift + I: 让统计信息常驻屏幕。
按 1-5 或 0 键：在不同信息页面间切换。
