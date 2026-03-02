MPV built-in code connection
Address of the untranslated English original file:
https://github.com/mpv-player/mpv/blob/master/player/lua/stats.lua


<img width="3837" height="2154" alt="微信图片_2026-03-01_112007_816" src="https://github.com/user-attachments/assets/34541caf-e934-4ef8-84f4-75fa6c37e707" />


步骤 1：编辑主配置文件 Step 1: Edit the Main Configuration File

在你的 mpv.conf 文件中，添加或确认以下一行。这行代码会关闭 mpv 内置的英文版统计脚本，为我们的中文版脚本让路。
 In your mpv.conf file, add or ensure the following line is present.
 This disables the built-in English stats script to make way for our Chinese version.

在 mpv.conf 中添加：
#关闭内置统计脚本 [stats.lua] (默认启用)，以使用外部中文版
#Disable the built-in stats script [stats.lua] (enabled by default) to use the external Chinese version
load-stats-overlay=no

步骤 2：放置中文版脚本 
Step 2: Place the Chinese Script
将我们翻译好的 stats.lua 文件，放入 mpv 的脚本文件夹中。 
Put our translated stats.lua file into mpv's scripts folder.


目标位置 / Destination: portable_config/scripts/
绝对路径示例 / Absolute path example:
Windows: C:\Users\你的用户名\AppData\Roaming\mpv\scripts\
Linux/macOS: ~/.config/mpv/scripts/


步骤 3：开始享用
Step 3: Enjoy!

完成以上两步，你的配置就大功告成了！现在，无论你使用的基础综合配置是什么，都可以：
 Once these two steps are done, your setup is complete! Now, regardless of the base comprehensive config you're using, you can:

按 i 键：临时查看全中文的播放统计信息。 Press i: Temporarily view the playback statistics in full Chinese.

按 I (大写) 键：让统计信息常驻屏幕。 Press Shift + I: Keep the statistics permanently on screen.

按 1-5 或 0 键：在不同信息页面间切换。 Press 1-5 or 0: Switch between different information pages.


