-- 显示一些统计信息。
--
-- 请查阅 readme 了解使用和配置信息：
-- https://github.com/Argon-/mpv-stats
--
-- 请注意：并非所有属性始终可用，因此并非始终可见。

local mp = require 'mp'
local utils = require 'mp.utils'
local input = require 'mp.input'

-- 选项配置
local o = {
    -- 默认按键绑定
    key_page_1 = "1",
    key_page_2 = "2",
    key_page_3 = "3",
    key_page_4 = "4",
    key_page_5 = "5",
    key_page_0 = "0",
    -- 支持滚动的页面
    key_scroll_up = "UP",
    key_scroll_down = "DOWN",
    key_search = "/",
    key_exit = "ESC",
    scroll_lines = 1,

    duration = 4,
    redraw_delay = 1,                -- 切换模式下的持续时间
    ass_formatting = true,
    persistent_overlay = false,      -- 统计信息是否可被其他输出覆盖
    filter_params_max_length = 100,  -- 如果过滤器列表超过此长度，每行显示一个
    file_tag_max_length = 128,       -- 只显示短于此字节数的文件标签
    file_tag_max_count = 16,         -- 只显示前 x 个文件标签
    show_frame_info = false,         -- 是否显示当前帧信息
    term_clip = true,
    track_info_selected_only = true, -- 只显示选中的轨道信息
    debug = false,

    -- 图表选项和样式
    plot_perfdata = false,
    plot_vsync_ratio = false,
    plot_vsync_jitter = false,
    plot_cache = true,
    plot_tonemapping_lut = false,
    skip_frames = 5,
    global_max = true,
    flush_graph_data = true,         -- 切换时清除数据缓冲区
    plot_bg_border_color = "0000FF",
    plot_bg_color = "262626",
    plot_color = "FFFFFF",
    plot_bg_border_width = 1.25,

    -- 文本样式
    font = "",
    font_mono = "monospace",   -- 等宽字体用于数字显示
    font_size = 20,
    font_color = "",
    border_size = 1.65,
    border_color = "",
    shadow_x_offset = math.huge,
    shadow_y_offset = math.huge,
    shadow_color = "",
    alpha = "11",
    vidscale = "auto",

    -- 自定义 ASS 标签头部，用于设置文本输出样式
    -- 指定此项将忽略上面的文本样式值，直接使用此字符串
    custom_header = "",

    -- 文本格式化
    -- 使用 ASS 时
    ass_nl = "\\N",
    ass_indent = "\\h\\h\\h\\h\\h",
    ass_prefix_sep = "\\h\\h",
    ass_b1 = "{\\b1}",
    ass_b0 = "{\\b0}",
    ass_it1 = "{\\i1}",
    ass_it0 = "{\\i0}",
    -- 不使用 ASS 时
    no_ass_nl = "\n",
    no_ass_indent = "    ",
    no_ass_prefix_sep = " ",
    no_ass_b1 = "\027[1m",
    no_ass_b0 = "\027[0m",
    no_ass_it1 = "\027[3m",
    no_ass_it0 = "\027[0m",

    bindlist = "no",  -- 启动时在终端打印第4页并退出 mpv
}

local update_scale
require "mp.options".read_options(o, nil, function ()
    update_scale()
end)

local format = string.format
local max = math.max
local min = math.min

-- 缩放后的度量值
local font_size = o.font_size
local border_size = o.border_size
local shadow_x_offset = o.shadow_x_offset
local shadow_y_offset = o.shadow_y_offset
local plot_bg_border_width = o.plot_bg_border_width
-- 用于记录性能数据的函数
local recorder = nil
-- 用于重绘（切换）和清除屏幕（一次性）的定时器
local display_timer = nil
-- 用于更新缓存统计的定时器
local cache_recorder_timer
-- 当前页面和 <页面键>:<页面函数> 映射
local curr_page = o.key_page_1
local pages = {}
local scroll_bound = false
local searched_text
local tm_viz_prev = nil
-- 保存这些序列，因为我们会经常用到它们
local ass_start = mp.get_property_osd("osd-ass-cc/0")
local ass_stop = mp.get_property_osd("osd-ass-cc/1")
-- 用于构建图表的环形缓冲区
-- .pos 表示当前位置，.len 是缓冲区长度
-- .max 是缓冲区中的最大值
local vsratio_buf, vsjitter_buf
local function init_buffers()
    vsratio_buf = {0, pos = 1, len = 50, max = 0}
    vsjitter_buf = {0, pos = 1, len = 50, max = 0}
end
local cache_ahead_buf, cache_speed_buf
local perf_buffers = {}
local process_key_binding

local property_cache = {}

local function get_property_cached(name, def)
    if property_cache[name] ~= nil then
        return property_cache[name]
    end
    return def
end

local function graph_add_value(graph, value)
    graph.pos = (graph.pos % graph.len) + 1
    graph[graph.pos] = value
    graph.max = max(graph.max, value)
end

local function no_ASS(t)
    if not o.use_ass then
        return t
    elseif not o.persistent_overlay then
        -- mp.osd_message 使用 osd-ass-cc/{0|1} 支持 ass 转义
        return ass_stop .. t .. ass_start
    else
        return mp.command_native({"escape-ass", tostring(t)})
    end
end


local function bold(t)
    return o.b1 .. t .. o.b0
end


local function it(t)
    return o.it1 .. t .. o.it0
end


local function text_style()
    if not o.use_ass then
        return ""
    end
    if o.custom_header and o.custom_header ~= "" then
        return o.custom_header
    else
        local style = "{\\r\\an7\\fs" .. font_size .. "\\bord" .. border_size

        if o.font ~= "" then
            style = style .. "\\fn" .. o.font
        end

        if o.font_color ~= "" then
            style = style .. "\\1c&H" .. o.font_color .. "&\\1a&H" .. o.alpha .. "&"
        end

        if o.border_color ~= "" then
            style = style .. "\\3c&H" .. o.border_color .. "&\\3a&H" .. o.alpha .. "&"
        end

        if o.shadow_color ~= "" then
            style = style .. "\\4c&H" .. o.shadow_color .. "&\\4a&H" .. o.alpha .. "&"
        end

        if o.shadow_x_offset < math.huge then
            style = style .. "\\xshad" .. shadow_x_offset
        end

        if o.shadow_y_offset < math.huge then
            style = style .. "\\yshad" .. shadow_y_offset
        end

        return style .. "}"
    end
end


local function has_vo_window()
    return mp.get_property_native("vo-configured") and mp.get_property_native("video-osd")
end


-- 根据给定值生成图表
-- 返回 ASS 格式的矢量图形字符串
--
-- values: 数字数组/表，代表数据。像环形缓冲区一样使用
--         从位置 i 开始向后迭代 `len` 次
-- i     : `values` 中最新数据值的索引
-- len   : `values` 中数字的数量/长度
-- v_max : `values` 中的最大值。用于将所有数据值缩放到 0 到 `v_max` 的范围
-- v_avg : `values` 中的平均值。用于尽可能居中显示图表。可以为 nil
-- scale : 与所有数据值相乘的值
-- x_tics: 步长的水平宽度乘数
local function generate_graph(values, i, len, v_max, v_avg, scale, x_tics)
    -- 检查是否至少有一个值
    if not values[i] then
        return ""
    end

    local x_max = (len - 1) * x_tics
    local y_offset = border_size
    local y_max = font_size * 0.66
    local x = 0

    if v_max > 0 then
        -- 尝试居中显示图表，但要避免超过 `scale`
        if v_avg and v_avg > 0 then
            scale = min(scale, v_max / (2 * v_avg))
        end
        scale = scale * y_max / v_max
    end  -- 否则如果 v_max==0，则所有值都是 0，scale 无关紧要

    local s = {format("m 0 0 n %f %f l ", x, y_max - scale * values[i])}
    i = ((i - 2) % len) + 1

    for _ = 1, len - 1 do
        if values[i] then
            x = x - x_tics
            s[#s+1] = format("%f %f ", x, y_max - scale * values[i])
        end
        i = ((i - 2) % len) + 1
    end

    s[#s+1] = format("%f %f %f %f", x, y_max, 0, y_max)

    local bg_box = format("{\\bord%f}{\\3c&H%s&}{\\1c&H%s&}m 0 %f l %f %f %f 0 0 0",
                          plot_bg_border_width, o.plot_bg_border_color, o.plot_bg_color,
                          y_max, x_max, y_max, x_max)
    return format("%s{\\rDefault}{\\pbo%f}{\\shad0}{\\alpha&H00}{\\p1}%s{\\p0}" ..
                  "{\\bord0}{\\1c&H%s}{\\p1}%s{\\p0}%s",
                  o.prefix_sep, y_offset, bg_box, o.plot_color, table.concat(s), text_style())
end


local function append(s, str, attr)
    if not str then
        return false
    end
    attr.prefix_sep = attr.prefix_sep or o.prefix_sep
    attr.indent = attr.indent or o.indent
    attr.nl = attr.nl or o.nl
    attr.suffix = attr.suffix or ""
    attr.prefix = attr.prefix or ""
    attr.no_prefix_markup = attr.no_prefix_markup or false
    attr.prefix = attr.no_prefix_markup and attr.prefix or bold(attr.prefix)

    local index = #s + (attr.nl == "" and 0 or 1)
    s[index] = s[index] or ""
    s[index] = s[index] .. format("%s%s%s%s%s%s", attr.nl, attr.indent,
                     attr.prefix, attr.prefix_sep, no_ASS(str), attr.suffix)
    return true
end


-- 格式化和添加属性
-- 值为 nil 或空（以下简称"无效"）的属性将被跳过，不添加
-- 如果没有添加任何内容返回 false，否则返回 true
--
-- s      : 包含字符串的表
-- prop   : 要查询和格式化的属性（基于其 OSD 表示）
-- attr   : 可选表，用于覆盖该属性的某些（格式化）属性
-- exclude: 可选表，包含该属性被视为无效值的键
--          指定此项将替换默认的无效值空字符串（nil 始终无效）
-- cached : 如果为 true，使用 get_property_cached 而不是 get_property_osd
local function append_property(s, prop, attr, excluded, cached)
    excluded = excluded or {[""] = true}
    local ret
    if cached then
        ret = get_property_cached(prop)
    else
        ret = mp.get_property_osd(prop)
    end
    if not ret or excluded[ret] then
        if o.debug then
            print("属性无值: " .. prop)
        end
        return false
    end
    return append(s, ret, attr)
end

local function sorted_keys(t, comp_fn)
    local keys = {}
    for k,_ in pairs(t) do
        keys[#keys+1] = k
    end
    table.sort(keys, comp_fn)
    return keys
end

local function scroll_hint(search)
    local hint = format("(提示: 用 %s/%s 滚动", o.key_scroll_up, o.key_scroll_down)
    if search then
        hint = hint .. "，用 " .. o.key_search .. " 搜索"
    end
    hint = hint .. ")"
    if not o.use_ass then return " " .. hint end
    return format(" {\\fs%s}%s{\\fs%s}", font_size * 0.66, hint, font_size)
end

local function append_perfdata(header, s, dedicated_page)
    local vo_p = mp.get_property_native("vo-passes")
    if not vo_p then
        return
    end

    -- 所有 last/avg/peak 值的总和
    local last_s, avg_s, peak_s = {}, {}, {}
    for frame, data in pairs(vo_p) do
        last_s[frame], avg_s[frame], peak_s[frame] = 0, 0, 0
        for _, pass in ipairs(data) do
            last_s[frame] = last_s[frame] + pass["last"]
            avg_s[frame]  = avg_s[frame]  + pass["avg"]
            peak_s[frame] = peak_s[frame] + pass["peak"]
        end
    end

    -- 美化显示测量时间
    local function pp(i)
        -- 重新缩放到微秒以便更合理的显示
        return format("%5d", i / 1000)
    end

    -- 根据比率格式化 n/m 并设置字体粗细
    local function p(n, m)
        local i = 0
        if m > 0 then
            i = tonumber(n) / m
        end
        -- 计算字体粗细。100 是最小值，400 是正常，700 是粗体，900 是最大值
        local w = (700 * math.sqrt(i)) + 200
        if not o.use_ass then
            local str = format("%3d%%", i * 100)
            return w >= 700 and bold(str) or str
        end
        return format("{\\b%d}%3d%%{\\b0}", w, i * 100)
    end

    local font_small = o.use_ass and format("{\\fs%s}", font_size * 0.66) or ""
    local font_normal = o.use_ass and format("{\\fs%s}", font_size) or ""
    local font = o.use_ass and format("{\\fn%s}", o.font) or ""
    local font_mono = o.use_ass and format("{\\fn%s}", o.font_mono) or ""
    local indent = o.use_ass and "\\h" or " "

    -- 确保固定的标题是一个元素，每个可滚动的行也是一个单独的元素
    local h = dedicated_page and header or s
    h[#h+1] = format("%s%s%s%s%s%s%s%s",
                     dedicated_page and "" or o.nl, dedicated_page and "" or o.indent,
                     bold("帧时间:"), o.prefix_sep, font_small,
                     "(最后/平均/峰值 μs)", font_normal,
                     dedicated_page and scroll_hint() or "")

    for _,frame in ipairs(sorted_keys(vo_p)) do  -- 确保固定的显示顺序
        local data = vo_p[frame]
        local f = "%s%s%s%s%s / %s / %s %s%s%s%s%s%s"

        if dedicated_page then
            s[#s+1] = format("%s%s%s:", o.nl, o.indent,
                             bold(frame:gsub("^%l", string.upper)))

            for _, pass in ipairs(data) do
                s[#s+1] = format(f, o.nl, o.indent, o.indent,
                                 font_mono, pp(pass["last"]),
                                 pp(pass["avg"]), pp(pass["peak"]),
                                 o.prefix_sep .. indent, p(pass["last"], last_s[frame]),
                                 font, o.prefix_sep, o.prefix_sep, pass["desc"])

                if o.plot_perfdata and o.use_ass then
                    -- 使用本次迭代已经开始的同一行
                    s[#s] = s[#s] ..
                              generate_graph(pass["samples"], pass["count"],
                                             pass["count"], pass["peak"],
                                             pass["avg"], 0.9, 0.25)
                end
            end

            -- 打印时间值总和作为"总计"
            s[#s+1] = format(f, o.nl, o.indent, o.indent,
                             font_mono, pp(last_s[frame]),
                             pp(avg_s[frame]), pp(peak_s[frame]),
                             o.prefix_sep, bold("总计"), font, "", "", "")
        else
            -- 对于简化视图，我们只打印每次传递的总和
            s[#s+1] = format(f, o.nl, o.indent, o.indent, font_mono,
                            pp(last_s[frame]), pp(avg_s[frame]), pp(peak_s[frame]),
                            "", "", font, o.prefix_sep, o.prefix_sep,
                            frame:gsub("^%l", string.upper))
        end
    end
end

-- 要剥离的命令前缀标记 - 包括通用属性命令
local cmd_prefixes = {
    osd_auto=1, no_osd=1, osd_bar=1, osd_msg=1, osd_msg_bar=1, raw=1, sync=1,
    async=1, expand_properties=1, repeatable=1, nonrepeatable=1, nonscalable=1,
    set=1, add=1, multiply=1, toggle=1, cycle=1, cycle_values=1, ["!reverse"]=1,
    change_list=1,
}
-- 命令/可写属性的前缀子词（后面跟着 -）要剥离
local name_prefixes = {
    define=1, delete=1, enable=1, disable=1, dump=1, write=1, drop=1, revert=1,
    ab=1, hr=1, secondary=1, current=1,
}
-- 从命令字符串中提取命令"主题"，通过移除所有通用前缀标记
-- 然后返回下一个标记的第一个有趣的子词。对于目标脚本名称，我们还检查另一个标记。
-- 分词器对我们关心的东西效果很好 - 有效的 mpv 命令、属性和脚本名，可能带引号，空格分隔。
-- 在实践中效果不错，最坏的情况是"不正确"的主题。
local function cmd_subject(cmd)
    cmd = cmd:gsub(";.*", ""):gsub("%-", "_")  -- 只取第一个命令，将 - 替换为 _
    local TOKEN = '^%s*["\']?([%w_!]*)'  -- 捕获并在可能的最终引号前结束
    local tok, sname, subw

    repeat tok, cmd = cmd:match(TOKEN .. '["\']?(.*)')
    until not cmd_prefixes[tok]
    -- tok 是第一个非通用命令/属性名标记，cmd 是剩下的

    sname = tok == "script_message_to" and cmd:match(TOKEN)
         or tok == "script_binding" and cmd:match(TOKEN .. "/")
    if sname and sname ~= "" then
        return "脚本: " .. sname
    end

    -- 返回 tok 的第一个不是无用前缀的子词
    repeat subw, tok = tok:match("([^_]*)_?(.*)")
    until tok == "" or not name_prefixes[subw]
    return subw:len() > 1 and subw or "[未知]"
end

-- 键名是有效的 UTF-8，除了最后一个/唯一码点外都是 ascii7
-- 我们计算码点数并忽略 wcwidth。不需要处理字素簇
-- 如果最后一个码点是双宽度的，我们的对齐误差最多为一个单元格
--（如果 k 有效但任意：我们会计数所有字节 <0x80 或 >=0xc0）
local function keyname_cells(k)
    local klen = k:len()
    if klen > 1 and k:byte(klen) >= 0x80 then  -- 最后一个/唯一码点不是 ascii7
        repeat klen = klen-1
        until klen == 1 or k:byte(klen) >= 0xc0  -- 最后一个码点从 klen 开始
    end
    return klen
end

local function get_kbinfo_lines()
    -- 活动键：只取每个键的最高优先级，不包括我们的（stats）键
    local bindings = mp.get_property_native("input-bindings", {})
    local active = {}  -- 映射：键名 -> 绑定信息
    for _, bind in pairs(bindings) do
        if bind.priority >= 0 and (
               not active[bind.key] or
               (active[bind.key].is_weak and not bind.is_weak) or
               (bind.is_weak == active[bind.key].is_weak and
                bind.priority > active[bind.key].priority)
           ) and not bind.cmd:find("script-binding stats/__forced_", 1, true)
           and bind.section ~= "input_forced_console"
           and (
               searched_text == nil or
               (bind.key .. bind.cmd .. (bind.comment or "")):lower():find(searched_text, 1, true)
           )
        then
            active[bind.key] = bind
        end
    end

    -- 创建数组，找到最大键长度，添加排序键（.subject/.mods[_count]）
    local ordered = {}
    local kspaces = ""  -- 与最长键名一样多的空格
    for _, bind in pairs(active) do
        bind.subject = cmd_subject(bind.cmd)
        if bind.subject ~= "ignore" then
            ordered[#ordered+1] = bind
            _,_, bind.mods = bind.key:find("(.*)%+.")
            _, bind.mods_count = bind.key:gsub("%+.", "")
            if bind.key:len() > kspaces:len() then
                kspaces = string.rep(" ", bind.key:len())
            end
        end
    end

    local function align_right(key)
        return kspaces:sub(keyname_cells(key)) .. key
    end

    -- 排序方式：主题、修饰键数量、修饰键、键长度、小写键、键
    table.sort(ordered, function(a, b)
        if a.subject ~= b.subject then
            return a.subject < b.subject
        elseif a.mods_count ~= b.mods_count then
            return a.mods_count < b.mods_count
        elseif a.mods ~= b.mods then
            return a.mods < b.mods
        elseif a.key:len() ~= b.key:len() then
            return a.key:len() < b.key:len()
        elseif a.key:lower() ~= b.key:lower() then
            return a.key:lower() < b.key:lower()
        else
            return a.key > b.key  -- 只有大小写不同，小写优先
        end
    end)

    -- 终端/ASS 的键/主题前后格式化
    -- 键/主题对齐使用空格（如果是 ass 则用等宽字体）
    -- 对于 ass 禁用自动换行，对于终端最多截断到 79 个字符
    local LTR = string.char(0xE2, 0x80, 0x8E)  -- U+200E 从左到右标记
    local term = not o.use_ass
    local kpre = term and "" or format("{\\q2\\fn%s}%s", o.font_mono, LTR)
    local kpost = term and " " or format(" {\\fn%s}", o.font)
    local spre = term and kspaces .. "   "
                       or format("{\\q2\\fn%s}%s   {\\fn%s}{\\fs%d\\u1}",
                                 o.font_mono, kspaces, o.font, 1.3*font_size)
    local spost = term and "" or format("{\\u0\\fs%d}%s", font_size, text_style())

    -- 创建显示行
    local info_lines = {}
    local subject = nil
    for _, bind in ipairs(ordered) do
        if bind.subject ~= subject then  -- 新主题（标题）
            subject = bind.subject
            append(info_lines, "", {})
            append(info_lines, "", { prefix = spre .. subject .. spost })
        end
        if bind.comment then
            bind.cmd = bind.cmd .. "  # " .. bind.comment
        end
        append(info_lines, bind.cmd, { prefix = kpre .. no_ASS(align_right(bind.key)) .. kpost })
    end
    return info_lines
end

local function append_general_perfdata(s)
    for i, data in ipairs(mp.get_property_native("perf-info") or {}) do
        append(s, data.text or data.value, {prefix="["..tostring(i).."] "..data.name..":"})

        if o.plot_perfdata and o.use_ass and data.value then
            local buf = perf_buffers[data.name]
            if not buf then
                buf = {0, pos = 1, len = 50, max = 0}
                perf_buffers[data.name] = buf
            end
            graph_add_value(buf, data.value)
            s[#s] = s[#s] .. generate_graph(buf, buf.pos, buf.len, buf.max, nil, 0.8, 1)
        end
    end
end

local function append_display_sync(s)
    if not mp.get_property_bool("display-sync-active", false) then
        return
    end

    local vspeed = append_property(s, "video-speed-correction", {prefix="显示同步:"})
    if vspeed then
        append_property(s, "audio-speed-correction",
                        {prefix="/", nl="", indent=" ", prefix_sep=" ", no_prefix_markup=true})
    else
        append_property(s, "audio-speed-correction",
                        {prefix="显示同步:" .. o.prefix_sep .. " - / ", prefix_sep=""})
    end

    append_property(s, "mistimed-frame-count", {prefix="时间错误:", nl="",
                                                indent=o.prefix_sep .. o.prefix_sep})
    append_property(s, "vo-delayed-frame-count", {prefix="延迟:", nl="",
                                                  indent=o.prefix_sep .. o.prefix_sep})

    -- 由于需要绘制一些图表，我们将抖动和比率打印在单独的行上
    if not display_timer.oneshot and (o.plot_vsync_ratio or o.plot_vsync_jitter) and o.use_ass then
        local ratio_graph = ""
        local jitter_graph = ""
        if o.plot_vsync_ratio then
            ratio_graph = generate_graph(vsratio_buf, vsratio_buf.pos,
                                         vsratio_buf.len, vsratio_buf.max, nil, 0.8, 1)
        end
        if o.plot_vsync_jitter then
            jitter_graph = generate_graph(vsjitter_buf, vsjitter_buf.pos,
                                          vsjitter_buf.len, vsjitter_buf.max, nil, 0.8, 1)
        end
        append_property(s, "vsync-ratio", {prefix="垂直同步比率:",
                                           suffix=o.prefix_sep .. ratio_graph})
        append_property(s, "vsync-jitter", {prefix="垂直同步抖动:",
                                            suffix=o.prefix_sep .. jitter_graph})
    else
        -- 由于不需要图表，我们可以将比率/抖动打印在同一行以节省空间
        local vr = append_property(s, "vsync-ratio", {prefix="垂直同步比率:"})
        append_property(s, "vsync-jitter", {prefix="垂直同步抖动:",
                            nl=vr and "" or o.nl,
                            indent=vr and o.prefix_sep .. o.prefix_sep})
    end
end


local function append_filters(s, prop, prefix)
    local length = 0
    local filters = {}

    for _,f in ipairs(mp.get_property_native(prop, {})) do
        local n = f.name
        if f.enabled ~= nil and not f.enabled then
            n = n .. " (已禁用)"
        end

        if f.label ~= nil then
            n = "@" .. f.label .. ": " .. n
        end

        local p = {}
        for _,key in ipairs(sorted_keys(f.params)) do
            p[#p+1] = key .. "=" .. f.params[key]
        end
        if #p > 0 then
            p = " [" .. table.concat(p, " ") .. "]"
        else
            p = ""
        end

        length = length + n:len() + p:len()
        filters[#filters+1] = no_ASS(n) .. it(no_ASS(p))
    end

    if #filters > 0 then
        local ret
        if length < o.filter_params_max_length then
            ret = table.concat(filters, ", ")
        else
            local sep = o.nl .. o.indent .. o.indent
            ret = sep .. table.concat(filters, sep)
        end
        s[#s+1] = o.nl .. o.indent .. bold(prefix) .. o.prefix_sep .. ret
    end
end


local function add_header(s)
    s[#s+1] = text_style()
end


local function add_file(s, print_cache, print_tags)
    append(s, "", {prefix="文件:", nl="", indent=""})
    append_property(s, "filename", {prefix_sep="", nl="", indent=""})
    if mp.get_property_osd("filename") ~= mp.get_property_osd("media-title") then
        append_property(s, "media-title", {prefix="标题:"})
    end

    if print_tags then
        append_property(s, "duration", {prefix="时长:"})
        local tags = mp.get_property_native("display-tags")
        local tags_displayed = 0
        for _, tag in ipairs(tags) do
            local value = mp.get_property("metadata/by-key/" .. tag)
            if tag ~= "Title" and tags_displayed < o.file_tag_max_count
               and value and value:len() < o.file_tag_max_length then
                append(s, value, {prefix=string.gsub(tag, "_", " ") .. ":"})
                tags_displayed = tags_displayed + 1
            end
        end
    end

    local editions = mp.get_property_number("editions")
    local edition = mp.get_property_number("current-edition")
    local ed_cond = (edition and editions > 1)
    if ed_cond then
        append_property(s, "edition-list/" .. tostring(edition) .. "/title",
                       {prefix="版本:"})
        append_property(s, "edition-list/count",
                        {prefix="(" .. tostring(edition + 1) .. "/", suffix=")", nl="",
                         indent=" ", prefix_sep=" ", no_prefix_markup=true})
    end

    local ch_index = mp.get_property_number("chapter")
    if ch_index and ch_index >= 0 then
        append_property(s, "chapter-list/" .. tostring(ch_index) .. "/title", {prefix="章节:",
                        nl=ed_cond and "" or o.nl})
        append_property(s, "chapter-list/count",
                        {prefix="(" .. tostring(ch_index + 1) .. " /", suffix=")", nl="",
                         indent=" ", prefix_sep=" ", no_prefix_markup=true})
    end

    local fs = append_property(s, "file-size", {prefix="大小:"})
    append_property(s, "file-format", {prefix="格式/协议:",
                                       nl=fs and "" or o.nl,
                                       indent=fs and o.prefix_sep .. o.prefix_sep})

    if not print_cache then
        return
    end

    local demuxer_cache = mp.get_property_native("demuxer-cache-state", {})
    if demuxer_cache["fw-bytes"] then
        demuxer_cache = demuxer_cache["fw-bytes"] -- 返回字节数
    else
        demuxer_cache = 0
    end
    local demuxer_secs = mp.get_property_number("demuxer-cache-duration", 0)
    if demuxer_cache + demuxer_secs > 0 then
        append(s, utils.format_bytes_humanized(demuxer_cache), {prefix="总缓存:"})
        append(s, format("%.1f", demuxer_secs), {prefix="(", suffix=" 秒)", nl="",
               no_prefix_markup=true, prefix_sep="", indent=o.prefix_sep})
    end
end


local function crop_noop(w, h, r)
    return r["crop-x"] == 0 and r["crop-y"] == 0 and
           r["crop-w"] == w and r["crop-h"] == h
end


local function crop_equal(r, ro)
    return r["crop-x"] == ro["crop-x"] and r["crop-y"] == ro["crop-y"] and
           r["crop-w"] == ro["crop-w"] and r["crop-h"] == ro["crop-h"]
end


local function append_resolution(s, r, prefix, w_prop, h_prop, video_res)
    if not r then
        return
    end
    w_prop = w_prop or "w"
    h_prop = h_prop or "h"
    if append(s, r[w_prop], {prefix=prefix}) then
        append(s, r[h_prop], {prefix="x", nl="", indent=" ", prefix_sep=" ",
                           no_prefix_markup=true})
        if r["aspect"] ~= nil and not video_res then
            append(s, format("%.2f:1", r["aspect"]), {prefix="", nl="", indent="",
                                                      no_prefix_markup=true})
            append(s, r["aspect-name"], {prefix="(", suffix=")", nl="", indent=" ",
                                         prefix_sep="", no_prefix_markup=true})
        end
        if r["sar"] ~= nil and video_res then
            append(s, format("%.2f:1", r["sar"]), {prefix="", nl="", indent="",
                                                      no_prefix_markup=true})
            append(s, r["sar-name"], {prefix="(", suffix=")", nl="", indent=" ",
                                         prefix_sep="", no_prefix_markup=true})
        end
        if r["s"] then
            append(s, format("%.2f", r["s"]), {prefix="(", suffix="x)", nl="",
                                               indent=o.prefix_sep, prefix_sep="",
                                               no_prefix_markup=true})
        end
        -- 如果裁剪与视频解码分辨率相同，可以跳过
        if r["crop-w"] and (not video_res or
                            not crop_noop(r[w_prop], r[h_prop], r)) then
            append(s, format("[x: %d, y: %d, w: %d, h: %d]",
                            r["crop-x"], r["crop-y"], r["crop-w"], r["crop-h"]),
                            {prefix="", nl="", indent="", no_prefix_markup=true})
        end
    end
end


local function pq_eotf(x)
    if not x then
        return x;
    end

    local PQ_M1 = 2610.0 / 4096 * 1.0 / 4
    local PQ_M2 = 2523.0 / 4096 * 128
    local PQ_C1 = 3424.0 / 4096
    local PQ_C2 = 2413.0 / 4096 * 32
    local PQ_C3 = 2392.0 / 4096 * 32

    x = x ^ (1.0 / PQ_M2)
    x = max(x - PQ_C1, 0.0) / (PQ_C2 - PQ_C3 * x)
    x = x ^ (1.0 / PQ_M1)
    x = x * 10000.0

    return x
end


local function append_hdr(s, hdr, video_out)
    if not hdr then
        return
    end

    local function has(val, target)
        return val and math.abs(val - target) > 1e-4
    end

    -- 如果打印视频输出参数，那是显示参数，不是母版参数
    local display_prefix = video_out and "显示:" or "母版显示:"

    local indent = ""
    local has_dml = has(hdr["min-luma"], 0.203) or has(hdr["max-luma"], 203)
    local has_cll = hdr["max-cll"] and hdr["max-cll"] > 0
    local has_fall = hdr["max-fall"] and hdr["max-fall"] > 0

    if has_dml or has_cll or has_fall then
        append(s, "", {prefix=video_out and "" or "HDR10:", prefix_sep=video_out and "" or nil})
        if has_dml then
            -- libplacebo 使用接近零的值作为"定义的零"
            hdr["min-luma"] = hdr["min-luma"] <= 1e-6 and 0 or hdr["min-luma"]
            append(s, format("%.2g / %.0f", hdr["min-luma"], hdr["max-luma"]),
                {prefix=display_prefix, suffix=" cd/m²", nl="", indent=indent})
            indent = o.prefix_sep .. o.prefix_sep
        end
        if has_cll then
            append(s, string.format("%.0f", hdr["max-cll"]), {prefix="最大CLL:",
                                    suffix=" cd/m²", nl="", indent=indent})
            indent = o.prefix_sep .. o.prefix_sep
        end
        if has_fall then
            append(s, hdr["max-fall"], {prefix="最大FALL:", suffix=" cd/m²", nl="",
                                        indent=indent})
        end
    end

    indent = o.prefix_sep .. o.prefix_sep

    if hdr["scene-max-r"] or hdr["scene-max-g"] or
       hdr["scene-max-b"] or hdr["scene-avg"] then
        append(s, "", {prefix="HDR10+:"})
        append(s, format("%.1f / %.1f / %.1f", hdr["scene-max-r"] or 0,
                         hdr["scene-max-g"] or 0, hdr["scene-max-b"] or 0),
               {prefix="最大RGB:", suffix=" cd/m²", nl="", indent=""})
        append(s, format("%.1f", hdr["scene-avg"] or 0),
               {prefix="平均:", suffix=" cd/m²", nl="", indent=indent})
    end

    if hdr["max-pq-y"] and hdr["avg-pq-y"] then
        append(s, "", {prefix="PQ(Y):"})
        append(s, format("%.2f cd/m² (%.2f%% PQ)", pq_eotf(hdr["max-pq-y"]),
                         hdr["max-pq-y"] * 100), {prefix="最大:", nl="",
                         indent=""})
        append(s, format("%.2f cd/m² (%.2f%% PQ)", pq_eotf(hdr["avg-pq-y"]),
                         hdr["avg-pq-y"] * 100), {prefix="平均:", nl="",
                         indent=indent})
    end
end


local function append_img_params(s, r, ro)
    if not r then
        return
    end

    append_resolution(s, r, "分辨率:", "w", "h", true)
    if ro and (r["w"] ~= ro["dw"] or r["h"] ~= ro["dh"]) then
        if ro["crop-w"] and (crop_noop(r["w"], r["h"], ro) or crop_equal(r, ro)) then
            ro["crop-w"] = nil
        end
        append_resolution(s, ro, "输出分辨率:", "dw", "dh")
    end

    local indent = o.prefix_sep .. o.prefix_sep
    r = ro or r

    local pixel_format = r["hw-pixelformat"] or r["pixelformat"]
    append(s, pixel_format, {prefix="格式:"})
    append(s, r["colorlevels"], {prefix="色阶:", nl="", indent=indent})
    if r["chroma-location"] and r["chroma-location"] ~= "unknown" then
        append(s, r["chroma-location"], {prefix="色度位置:", nl="", indent=indent})
    end

    -- 将这些组合在一起以节省垂直空间
    append(s, r["colormatrix"], {prefix="色彩矩阵:"})
    if r["prim-red-x"] or r["prim-red-y"] or
       r["prim-green-x"] or r["prim-green-y"] or
       r["prim-blue-x"] or r["prim-blue-y"] or
       r["prim-white-x"] or r["prim-white-y"] then
        append(s, string.format("[%.3f %.3f, %.3f %.3f, %.3f %.3f, %.3f %.3f]",
                                r["prim-red-x"] or 0, r["prim-red-y"] or 0,
                                r["prim-green-x"] or 0, r["prim-green-y"] or 0,
                                r["prim-blue-x"] or 0, r["prim-blue-y"] or 0,
                                r["prim-white-x"] or 0, r["prim-white-y"] or 0),
            {prefix="基色:", nl="", indent=indent})
        append(s, r["primaries"], {prefix="内", nl="", indent=" ", prefix_sep=" ",
                                   no_prefix_markup=true})
    else
        append(s, r["primaries"], {prefix="基色:", nl="", indent=indent})
    end
    append(s, r["gamma"], {prefix="传输:", nl="", indent=indent})
end


local function append_fps(s, prop, eprop)
    local fps = mp.get_property_osd(prop)
    local efps = mp.get_property_osd(eprop)
    local single = eprop == "" or (fps ~= "" and efps ~= "" and fps == efps)
    local unit = prop == "display-fps" and " Hz" or " fps"
    local suffix = single and "" or " (指定)"
    local esuffix = single and "" or " (估计)"
    local prefix = prop == "display-fps" and "刷新率:" or "帧率:"
    local nl = o.nl
    local indent = o.indent

    if fps ~= "" and append(s, fps, {prefix=prefix, suffix=unit .. suffix}) then
        prefix = ""
        nl = ""
        indent = ""
    end

    if not single and efps ~= "" then
        append(s, efps,
               {prefix=prefix, suffix=unit .. esuffix, nl=nl, indent=indent})
    end
end


local function add_video_out(s)
    local vo = mp.get_property_native("current-vo")
    if not vo then
        return
    end

    append(s, "", {prefix="显示:", nl=o.nl .. o.nl, indent=""})
    append(s, vo, {prefix_sep="", nl="", indent=""})

    append_property(s, "display-names", {prefix_sep="", prefix="(", suffix=")",
                    no_prefix_markup=true, nl="", indent=" "}, nil, true)
    append(s, mp.get_property_native("current-gpu-context"),
           {prefix="上下文:", nl="", indent=o.prefix_sep .. o.prefix_sep})
    append_property(s, "avsync", {prefix="音视频同步:"})
    append_fps(s, "display-fps", "estimated-display-fps")
    if append_property(s, "decoder-frame-drop-count",
                       {prefix="丢帧:", suffix=" (解码器)"}) then
        append_property(s, "frame-drop-count", {suffix=" (输出)", nl="", indent=""})
    end
    append_display_sync(s)
    append_perfdata(nil, s, false)

    if mp.get_property_native("deinterlace-active") then
        append_property(s, "deinterlace", {prefix="去隔行:"})
    end

    local scale = nil
    if not mp.get_property_native("fullscreen") then
        scale = get_property_cached("current-window-scale")
    end

    local od = mp.get_property_native("osd-dimensions")
    local rt = mp.get_property_native("video-target-params")
    local r = rt or {}

    -- 添加窗口缩放
    r["s"] = scale
    r["crop-x"] = od["ml"]
    r["crop-y"] = od["mt"]
    r["crop-w"] = od["w"] - od["ml"] - od["mr"]
    r["crop-h"] = od["h"] - od["mt"] - od["mb"]

    if not rt then
        r["w"] = r["crop-w"]
        r["h"] = r["crop-h"]
        append_resolution(s, r, "分辨率:", "w", "h", true)
        return
    end

    append_img_params(s, r)
    append_hdr(s, r, true)
end


local function add_video(s)
    local r = mp.get_property_native("video-params")
    local ro = mp.get_property_native("video-out-params")
    -- 如果是 lavfi-complex 等情况，可能没有输入视频，只有输出
    if not r then
        r = ro
    end
    if not r then
        return
    end

    local track = mp.get_property_native("current-tracks/video")
    local track_type = (track and track.image) and "图像:" or "视频:"
    append(s, "", {prefix=track_type, nl=o.nl .. o.nl, indent=""})
    if track and append(s, track["codec-desc"], {prefix_sep="", nl="", indent=""}) then
        append(s, track["codec-profile"], {prefix="[", nl="", indent=" ", prefix_sep="",
               no_prefix_markup=true, suffix="]"})
        if track["codec"] ~= track["decoder"] then
            append(s, track["decoder"], {prefix="[", nl="", indent=" ", prefix_sep="",
                   no_prefix_markup=true, suffix="]"})
        end
        append_property(s, "hwdec-current", {prefix="硬解:", nl="",
                        indent=o.prefix_sep .. o.prefix_sep,
                        no_prefix_markup=false, suffix=""}, {no=true, [""]=true}, true)
    end
    local has_prefix = false
    if o.show_frame_info then
        if append_property(s, "estimated-frame-number", {prefix="帧:"}) then
            append_property(s, "estimated-frame-count", {indent=" / ", nl="",
                                                        prefix_sep=""})
            has_prefix = true
        end
        local frame_info = mp.get_property_native("video-frame-info")
        if frame_info and frame_info["picture-type"] then
            local attrs = has_prefix and {prefix="(", suffix=")", indent=" ", nl="",
                                          prefix_sep="", no_prefix_markup=true}
                                      or {prefix="画面类型:"}
            append(s, frame_info["picture-type"], attrs)
            has_prefix = true
        end
        if frame_info and frame_info["interlaced"] then
            local attrs = has_prefix and {indent=" ", nl="", prefix_sep=""}
                                      or {prefix="画面类型:"}
            append(s, "隔行扫描", attrs)
        end

        local timecodes = {
            ["gop-timecode"] = "GOP",
            ["smpte-timecode"] = "SMPTE",
            ["estimated-smpte-timecode"] = "估计SMPTE",
        }
        for prop, name in pairs(timecodes) do
            if frame_info and frame_info[prop] then
                local attrs = has_prefix and {prefix=name .. " 时间码:",
                                              indent=o.prefix_sep .. o.prefix_sep, nl=""}
                                          or {prefix=name .. " 时间码:"}
                append(s, frame_info[prop], attrs)
                break
            end
        end
    end

    if mp.get_property_native("current-tracks/video/image") == false then
        append_fps(s, "container-fps", "estimated-vf-fps")
    end
    append_img_params(s, r, ro)
    append_hdr(s, ro)
    append_property(s, "video-bitrate", {prefix="码率:"})
    append_filters(s, "vf", "滤镜:")
end


local function add_audio(s)
    local r = mp.get_property_native("audio-params")
    -- 如果是 lavfi-complex 等情况，可能没有输入音频，只有输出
    local ro = mp.get_property_native("audio-out-params") or r
    r = r or ro
    if not r then
        return
    end

    local merge = function(rr, rro, prop)
        local a = rr[prop] or rro[prop]
        local b = rro[prop] or rr[prop]
        return (a == b or a == nil) and a or (a .. " ➜ " .. b)
    end

    append(s, "", {prefix="音频:", nl=o.nl .. o.nl, indent=""})
    local track = mp.get_property_native("current-tracks/audio")
    if track then
        append(s, track["codec-desc"], {prefix_sep="", nl="", indent=""})
        append(s, track["codec-profile"], {prefix="[", nl="", indent=" ", prefix_sep="",
               no_prefix_markup=true, suffix="]"})
        if track["codec"] ~= track["decoder"] then
            append(s, track["decoder"], {prefix="[", nl="", indent=" ", prefix_sep="",
                   no_prefix_markup=true, suffix="]"})
        end
    end
    append_property(s, "current-ao", {prefix="音频输出:", nl="",
                                      indent=o.prefix_sep .. o.prefix_sep})
    local dev = append_property(s, "audio-device", {prefix="设备:"})
    local ao_mute = mp.get_property_native("ao-mute") and " (静音)" or ""
    append_property(s, "ao-volume", {prefix="音量:", suffix="%" .. ao_mute,
                                     nl=dev and "" or o.nl,
                                     indent=dev and o.prefix_sep .. o.prefix_sep})
    if math.abs(mp.get_property_native("audio-delay")) > 1e-6 then
        append_property(s, "audio-delay", {prefix="音视频延迟:"})
    end
    local cc = append(s, merge(r, ro, "channel-count"), {prefix="声道数:"})
    append(s, merge(r, ro, "format"), {prefix="格式:", nl=cc and "" or o.nl,
                            indent=cc and o.prefix_sep .. o.prefix_sep})
    append(s, merge(r, ro, "samplerate"), {prefix="采样率:", suffix=" Hz"})
    append_property(s, "audio-bitrate", {prefix="码率:"})
    append_filters(s, "af", "滤镜:")
end


-- 确定是否/可以使用 ASS 格式化并设置格式化序列
local function eval_ass_formatting()
    o.use_ass = o.ass_formatting and has_vo_window()
    if o.use_ass then
        o.nl = o.ass_nl
        o.indent = o.ass_indent
        o.prefix_sep = o.ass_prefix_sep
        o.b1 = o.ass_b1
        o.b0 = o.ass_b0
        o.it1 = o.ass_it1
        o.it0 = o.ass_it0
    else
        o.nl = o.no_ass_nl
        o.indent = o.no_ass_indent
        o.prefix_sep = o.no_ass_prefix_sep
        o.b1 = o.no_ass_b1
        o.b0 = o.no_ass_b0
        o.it1 = o.no_ass_it1
        o.it0 = o.no_ass_it0
    end
end

-- 将字符串分割成表
-- 示例：local t = split(s, "\n")
-- plain：pat 是否为普通字符串（默认为 false - pat 是模式）
local function split(str, pat, plain)
    local init = 1
    local r, i, find, sub = {}, 1, string.find, string.sub
    repeat
        local f0, f1 = find(str, pat, init, plain)
        r[i], i = sub(str, init, f0 and f0 - 1), i+1
        init = f0 and f1 + 1
    until f0 == nil
    return r
end

-- 组合带有页眉和可滚动内容的输出
-- 返回完成的页面字符串和实际选择的偏移量
--
-- header      : 页眉表，每个条目一行
-- content     : 内容表，每个条目一行
-- apply_scroll: 是否滚动内容
local function finalize_page(header, content, apply_scroll)
    local term_height = mp.get_property_native("term-size/h", 24)
    local from, to = 1, #content
    if apply_scroll then
        -- libass 最多 40 行，因为处理太多行（屏幕下方）会给 libass 带来性能负担
        -- 在终端中，为状态行减去 2 行高度（可能多于一行）
        local max_content_lines = (o.use_ass and 40 or term_height - 2) - #header
        -- 在终端中，滚动应在最后一行可见时停止
        local max_offset = o.use_ass and #content or #content - max_content_lines + 1
        from = max(1, min((pages[curr_page].offset or 1), max_offset))
        to = min(#content, from + max_content_lines - 1)
        pages[curr_page].offset = from
    end
    local output = table.concat(header) .. table.concat(content, "", from, to)
    if not o.use_ass and o.term_clip then
        local clip = mp.get_property("term-clip-cc")
        local t = split(output, "\n", true)
        output = clip .. table.concat(t, "\n" .. clip)
    end
    return output, from
end

-- 返回包含"普通"统计信息的 ASS 字符串
local function default_stats()
    local stats = {}
    eval_ass_formatting()
    add_header(stats)
    add_file(stats, true, false)
    add_video_out(stats)
    add_video(stats)
    add_audio(stats)
    return finalize_page({}, stats, false)
end

-- 返回包含扩展 VO 统计信息的 ASS 字符串
local function vo_stats()
    local header, content = {}, {}
    eval_ass_formatting()
    add_header(header)
    append_perfdata(header, content, true)
    header = {table.concat(header)}
    return finalize_page(header, content, true)
end

local kbinfo_lines = nil
local function keybinding_info(after_scroll, bindlist)
    local header = {}
    local page = pages[o.key_page_4]
    eval_ass_formatting()
    add_header(header)
    local prefix = bindlist and page.desc or page.desc .. ":" .. scroll_hint(true)
    append(header, "", {prefix=prefix, nl="", indent=""})
    header = {table.concat(header)}

    if not kbinfo_lines or not after_scroll then
        kbinfo_lines = get_kbinfo_lines()
    end

    return finalize_page(header, kbinfo_lines, not bindlist)
end

local function float2rational(x)
    local max_den = 100000
    local m00, m01, m10, m11 = 1, 0, 0, 1
    local a = math.floor(x)
    local frac = x - a
    while m10 * a + m11 <= max_den do
        local temp = m00 * a + m01
        m01 = m00
        m00 = temp
        temp = m10 * a + m11
        m11 = m10
        m10 = temp

        if frac == 0 then
            break
        end

        x = 1 / frac
        a = math.floor(x)
        frac = x - a
    end
    return m00, m10
end

local function add_track(c, t, i)
    if not t then
        return
    end

    local type = t.image and "图像" or (t["type"]:sub(1, 1):upper() .. t["type"]:sub(2))
    append(c, "", {prefix=type .. ":", nl=o.nl .. o.nl, indent=""})
    append(c, t["title"], {prefix_sep="", nl="", indent=""})
    append(c, t["id"], {prefix="ID:"})
    append(c, t["src-id"], {prefix="解复用器ID:", nl="", indent=o.prefix_sep .. o.prefix_sep})
    append(c, t["program-id"], {prefix="节目ID:", nl="", indent=o.prefix_sep .. o.prefix_sep})
    append(c, t["ff-index"], {prefix="FFmpeg索引:", nl="", indent=o.prefix_sep .. o.prefix_sep})
    append(c, t["external-filename"], {prefix="文件:"})
    append(c, "", {prefix="标志:"})
    local flags = {"default", "forced", "dependent", "visual-impaired",
                   "hearing-impaired", "original", "commentary", "image",
                   "albumart", "external"}
    local any = false
    for _, flag in ipairs(flags) do
        if t[flag] then
            append(c, flag, {prefix=any and ", " or "", nl="", indent="", prefix_sep=""})
            any = true
        end
    end
    if not any then
        table.remove(c)
    end
    if append(c, t["codec-desc"], {prefix="编解码器:"}) then
        append(c, t["codec-profile"], {prefix="[", nl="", indent=" ", prefix_sep="",
               no_prefix_markup=true, suffix="]"})
        if t["codec"] ~= t["decoder"] then
            append(c, t["decoder"], {prefix="[", nl="", indent=" ", prefix_sep="",
                   no_prefix_markup=true, suffix="]"})
        end
    end
    append(c, t["lang"], {prefix="语言:"})
    append(c, t["demux-channel-count"], {prefix="声道数:"})
    append(c, t["demux-channels"], {prefix="声道布局:"})
    append(c, t["demux-samplerate"], {prefix="采样率:", suffix=" Hz"})
    local function B(b) return b and string.format("%.2f", b / 1024) end
    local bitrate = append(c, B(t["demux-bitrate"]), {prefix="码率:", suffix=" kbps"})
    append(c, B(t["hls-bitrate"]), {prefix="HLS码率:", suffix=" kbps",
                                    nl=bitrate and "" or o.nl,
                                    indent=bitrate and o.prefix_sep .. o.prefix_sep})
    append_resolution(c, {w=t["demux-w"], h=t["demux-h"], ["crop-x"]=t["demux-crop-x"],
                          ["crop-y"]=t["demux-crop-y"], ["crop-w"]=t["demux-crop-w"],
                          ["crop-h"]=t["demux-crop-h"]}, "分辨率:")
    if not t["image"] and t["demux-fps"] then
        append_fps(c, "track-list/" .. i .. "/demux-fps", "")
    end
    append(c, t["format-name"], {prefix="格式:"})
    append(c, t["demux-rotation"], {prefix="旋转:"})
    if t["demux-par"] then
        local num, den = float2rational(t["demux-par"])
        append(c, string.format("%d:%d", num, den), {prefix="像素宽高比:"})
    end
    local track_rg = t["replaygain-track-peak"] ~= nil or t["replaygain-track-gain"] ~= nil
    local album_rg = t["replaygain-album-peak"] ~= nil or t["replaygain-album-gain"] ~= nil
    if track_rg or album_rg then
        append(c, "", {prefix="重放增益:"})
    end
    if track_rg then
        append(c, "", {prefix="音轨:", indent=o.indent .. o.prefix_sep, prefix_sep=""})
        append(c, t["replaygain-track-gain"], {prefix="增益:", suffix=" dB",
                                               nl="", indent=o.prefix_sep})
        append(c, t["replaygain-track-peak"], {prefix="峰值:", suffix=" dB",
                                               nl="", indent=o.prefix_sep})
    end
    if album_rg then
        append(c, "", {prefix="专辑:", indent=o.indent .. o.prefix_sep, prefix_sep=""})
        append(c, t["replaygain-album-gain"], {prefix="增益:", suffix=" dB",
                                               nl="", indent=o.prefix_sep})
        append(c, t["replaygain-album-peak"], {prefix="峰值:", suffix=" dB",
                                               nl="", indent=o.prefix_sep})
    end
    if t["dolby-vision-profile"] or t["dolby-vision-level"] then
        append(c, "", {prefix="杜比视界:"})
        append(c, t["dolby-vision-profile"], {prefix="配置文件:", nl="", indent=""})
        append(c, t["dolby-vision-level"], {prefix="级别:", nl="",
                                            indent=t["dolby-vision-profile"] and
                                            o.prefix_sep .. o.prefix_sep or ""})
    end
end

local function track_info()
    local h, c = {}, {}
    eval_ass_formatting()
    add_header(h)
    local desc = pages[o.key_page_5].desc
    append(h, "", {prefix=format("%s:%s", desc, scroll_hint()), nl="", indent=""})
    h = {table.concat(h)}
    table.insert(c, o.nl .. o.nl)
    add_file(c, false, true)
    for i, track in ipairs(mp.get_property_native("track-list")) do
        if track['selected'] or not o.track_info_selected_only then
            add_track(c, track, i - 1)
        end
    end
    return finalize_page(h, c, true)
end

local function perf_stats()
    local header, content = {}, {}
    eval_ass_formatting()
    add_header(header)
    local page = pages[o.key_page_0]
    append(header, "", {prefix=format("%s:%s", page.desc, scroll_hint()), nl="", indent=""})
    append_general_perfdata(content)
    header = {table.concat(header)}
    return finalize_page(header, content, true)
end

local function opt_time(t)
    if type(t) == type(1.1) then
        return mp.format_time(t)
    end
    return "?"
end

-- 返回关于解复用器缓存等的统计信息的 ASS 字符串
local function cache_stats()
    local stats = {}

    eval_ass_formatting()
    add_header(stats)
    append(stats, "", {prefix="缓存信息:", nl="", indent=""})

    local info = mp.get_property_native("demuxer-cache-state")
    if info == nil then
        append(stats, "不可用", {})
        return finalize_page({}, stats, false)
    end

    local a = info["reader-pts"]
    local b = info["cache-end"]

    append(stats, opt_time(a) .. " - " .. opt_time(b), {prefix = "数据包队列:"})

    local r = nil
    if a ~= nil and b ~= nil then
        r = b - a
    end

    local r_graph = nil
    if not display_timer.oneshot and o.use_ass and o.plot_cache then
        r_graph = generate_graph(cache_ahead_buf, cache_ahead_buf.pos,
                                 cache_ahead_buf.len, cache_ahead_buf.max,
                                 nil, 0.8, 1)
        r_graph = o.prefix_sep .. r_graph
    end
    append(stats, opt_time(r), {prefix = "预读:", suffix = r_graph})

    -- 这些状态不一定互斥。它们涉及可能解耦的不同机制的状态。
    local state = "读取中"
    local seek_ts = info["debug-seeking"]
    if seek_ts ~= nil then
        state = "搜索中 (到 " .. mp.format_time(seek_ts) .. ")"
    elseif info["eof"] == true then
        state = "文件末尾"
    elseif info["underrun"] then
        state = "缓存不足"
    elseif info["idle"]  == true then
        state = "空闲"
    end
    append(stats, state, {prefix = "状态:"})

    local speed = info["raw-input-rate"] or 0
    local speed_graph = nil
    if not display_timer.oneshot and o.use_ass and o.plot_cache then
        speed_graph = generate_graph(cache_speed_buf, cache_speed_buf.pos,
                                     cache_speed_buf.len, cache_speed_buf.max,
                                     nil, 0.8, 1)
        speed_graph = o.prefix_sep .. speed_graph
    end
    append(stats, utils.format_bytes_humanized(speed) .. "/s", {prefix="速度:",
        suffix=speed_graph})

    append(stats, utils.format_bytes_humanized(info["total-bytes"]),
           {prefix = "总内存:"})
    append(stats, utils.format_bytes_humanized(info["fw-bytes"]),
           {prefix = "前向内存:"})

    local fc = info["file-cache-bytes"]
    if fc ~= nil then
        fc = utils.format_bytes_humanized(fc)
    else
        fc = "(已禁用)"
    end
    append(stats, fc, {prefix = "磁盘缓存:"})

    append(stats, info["debug-low-level-seeks"], {prefix = "媒体搜索:"})
    append(stats, info["debug-byte-level-seeks"], {prefix = "流搜索:"})

    append(stats, "", {prefix="范围:", nl=o.nl .. o.nl, indent=""})

    append(stats, info["bof-cached"] and "是" or "否",
           {prefix = "开始已缓存:"})
    append(stats, info["eof-cached"] and "是" or "否",
           {prefix = "结束已缓存:"})

    local ranges = info["seekable-ranges"] or {}
    for n, range in ipairs(ranges) do
        append(stats, mp.format_time(range["start"]) .. " - " ..
                      mp.format_time(range["end"]),
               {prefix = format("范围 %s:", n)})
    end

    return finalize_page({}, stats, false)
end

-- 记录缓存统计信息的 1 个样本
-- （与 record_data() 不同，这不返回函数，而是直接运行）
local function record_cache_stats()
    local info = mp.get_property_native("demuxer-cache-state")
    if info == nil then
        return
    end

    local a = info["reader-pts"]
    local b = info["cache-end"]
    if a ~= nil and b ~= nil then
        graph_add_value(cache_ahead_buf, b - a)
    end

    graph_add_value(cache_speed_buf, info["raw-input-rate"] or 0)
end

cache_recorder_timer = mp.add_periodic_timer(0.25, record_cache_stats)
cache_recorder_timer:kill()

-- 当前页面和 <页面键>:<页面函数> 映射
curr_page = o.key_page_1
pages = {
    [o.key_page_1] = { idx = 1, f = default_stats, desc = "默认" },
    [o.key_page_2] = { idx = 2, f = vo_stats, desc = "扩展帧时间", scroll = true },
    [o.key_page_3] = { idx = 3, f = cache_stats, desc = "缓存统计", scroll = true },
    [o.key_page_4] = { idx = 4, f = keybinding_info, desc = "活动按键绑定", scroll = true },
    [o.key_page_5] = { idx = 5, f = track_info, desc = "轨道信息", scroll = true },
    [o.key_page_0] = { idx = 0, f = perf_stats, desc = "内部性能信息", scroll = true },
}


-- 返回一个函数，用于记录指定 `skip` 值的 vsratio/jitter
local function record_data(skip)
    init_buffers()
    skip = max(skip, 0)
    local i = skip
    return function()
        if i < skip then
            i = i + 1
            return
        else
            i = 0
        end

        if o.plot_vsync_jitter then
            local r = mp.get_property_number("vsync-jitter")
            if r then
                vsjitter_buf.pos = (vsjitter_buf.pos % vsjitter_buf.len) + 1
                vsjitter_buf[vsjitter_buf.pos] = r
                vsjitter_buf.max = max(vsjitter_buf.max, r)
            end
        end

        if o.plot_vsync_ratio then
            local r = mp.get_property_number("vsync-ratio")
            if r then
                vsratio_buf.pos = (vsratio_buf.pos % vsratio_buf.len) + 1
                vsratio_buf[vsratio_buf.pos] = r
                vsratio_buf.max = max(vsratio_buf.max, r)
            end
        end
    end
end

-- 调用 `page` 的函数并将其打印到 OSD
local function print_page(page, after_scroll)
    -- 页面函数假定我们在启用 ass 的模式下开始
    -- 这对 mp.set_osd_ass 成立，但对 mp.osd_message 不成立
    local ass_content = pages[page].f(after_scroll)
    if o.persistent_overlay then
        mp.set_osd_ass(0, 0, ass_content)
    else
        mp.osd_message((o.use_ass and ass_start or "") .. ass_content,
                       display_timer.oneshot and o.duration or o.redraw_delay + 1)
    end
end

update_scale = function ()
    local scale_with_video
    if o.vidscale == "auto" then
        scale_with_video = mp.get_property_native("osd-scale-by-window")
    else
        scale_with_video = o.vidscale == "yes"
    end

    -- 计算缩放后的度量值
    -- 使 font_size=n 与 --osd-font-size=n 大小相同
    local scale = 288 / 720
    local osd_height = mp.get_property_native("osd-height")
    if not scale_with_video and osd_height > 0 then
        scale = 288 / osd_height
    end
    font_size = o.font_size * scale
    border_size = o.border_size * scale
    shadow_x_offset = o.shadow_x_offset * scale
    shadow_y_offset = o.shadow_y_offset * scale
    plot_bg_border_width = o.plot_bg_border_width * scale
    if display_timer:is_enabled() then
        print_page(curr_page)
    end
end

local function clear_screen()
    if o.persistent_overlay then mp.set_osd_ass(0, 0, "") else mp.osd_message("", 0) end
end

local function scroll_delta(d)
    if display_timer.oneshot then display_timer:kill() ; display_timer:resume() end
    pages[curr_page].offset = (pages[curr_page].offset or 1) + d
    print_page(curr_page, true)
end
local function scroll_up() scroll_delta(-o.scroll_lines) end
local function scroll_down() scroll_delta(o.scroll_lines) end

local function reset_scroll_offsets()
    for _, page in pairs(pages) do
        page.offset = nil
    end
end
local function bind_scroll()
    if not scroll_bound then
        mp.add_forced_key_binding(o.key_scroll_up, "__forced_" .. o.key_scroll_up,
                                  scroll_up, {repeatable=true})
        mp.add_forced_key_binding(o.key_scroll_down, "__forced_" .. o.key_scroll_down,
                                  scroll_down, {repeatable=true})
        scroll_bound = true
    end
end
local function unbind_scroll()
    if scroll_bound then
        mp.remove_key_binding("__forced_"..o.key_scroll_up)
        mp.remove_key_binding("__forced_"..o.key_scroll_down)
        scroll_bound = false
    end
end

local add_page_bindings
local remove_page_bindings

local function filter_bindings()
    input.get({
        prompt = "过滤绑定:",
        opened = function ()
            -- 这是必要的，如果一次性显示计时器在没有输入任何内容的情况下过期，则关闭控制台
            searched_text = ""

            -- 必须重新绑定以覆盖 console.lua 的绑定
            remove_page_bindings()
            bind_scroll()
        end,
        edited = function (text)
            reset_scroll_offsets()
            searched_text = text:lower()
            print_page(curr_page)
            if display_timer.oneshot then
                display_timer:kill()
                display_timer:resume()
            end
        end,
        closed = function ()
            searched_text = nil
            if display_timer:is_enabled() then
                add_page_bindings()
                print_page(curr_page)
                if display_timer.oneshot then
                    display_timer:kill()
                    display_timer:resume()
                end
            end
        end,
    })
end

local function bind_search()
    mp.add_forced_key_binding(o.key_search, "__forced_"..o.key_search, filter_bindings)
end

local function unbind_search()
    mp.remove_key_binding("__forced_"..o.key_search)
end

local function bind_exit()
    -- 在一次性模式下不绑定，因为如果按下 ESC 正好在统计信息停止显示时，
    -- 会意外触发用户定义的任何 ESC 绑定
    if not display_timer.oneshot then
        mp.add_forced_key_binding(o.key_exit, "__forced_" .. o.key_exit, function ()
            process_key_binding(false)
        end)
    end
end

local function unbind_exit()
    mp.remove_key_binding("__forced_" .. o.key_exit)
end

local function update_scroll_bindings(k)
    if pages[k].scroll then
        bind_scroll()
    else
        unbind_scroll()
    end

    if k == o.key_page_4 then
        bind_search()
    else
        unbind_search()
    end
end

-- 为每个页面添加按键绑定
add_page_bindings = function()
    local function a(k)
        return function()
            reset_scroll_offsets()
            update_scroll_bindings(k)
            curr_page = k
            print_page(k)
            if display_timer.oneshot then display_timer:kill() ; display_timer:resume() end
        end
    end
    for k, _ in pairs(pages) do
        mp.add_forced_key_binding(k, "__forced_"..k, a(k), {repeatable=true})
    end
    update_scroll_bindings(curr_page)
    bind_exit()
end


-- 移除每个页面的按键绑定
remove_page_bindings = function()
    for k, _ in pairs(pages) do
        mp.remove_key_binding("__forced_"..k)
    end
    unbind_scroll()
    unbind_search()
    unbind_exit()
end


process_key_binding = function(oneshot)
    reset_scroll_offsets()
    -- 统计信息已在显示中
    if display_timer:is_enabled() then
        -- 上一个和当前键都是一次性 -> 重启计时器
        if display_timer.oneshot and oneshot then
            display_timer:kill()
            print_page(curr_page)
            display_timer:resume()
        -- 上一个和当前键都是切换 -> 结束切换
        elseif not display_timer.oneshot and not oneshot then
            display_timer:kill()
            cache_recorder_timer:stop()
            if tm_viz_prev ~= nil then
                mp.set_property_native("tone-mapping-visualize", tm_viz_prev)
                tm_viz_prev = nil
            end
            clear_screen()
            remove_page_bindings()
            if recorder then
                mp.unobserve_property(recorder)
                recorder = nil
            end
        end
    -- 还没有显示统计信息
    else
        if not oneshot and (o.plot_vsync_jitter or o.plot_vsync_ratio) then
            recorder = record_data(o.skip_frames)
            -- 依赖 "vsync-ratio" 同时更新的事实
            -- 使用 "none" 在任何时候获取样本，即使它没有变化
            -- 如果 "vsync-jitter" 属性更改通知发生变化，这将停止工作，
            -- 但对于内部脚本来说没问题
            mp.observe_property("vsync-jitter", "none", recorder)
        end
        if not oneshot and o.plot_tonemapping_lut then
            tm_viz_prev = mp.get_property_native("tone-mapping-visualize")
            mp.set_property_native("tone-mapping-visualize", true)
        end
        if not oneshot then
            cache_ahead_buf = {0, pos = 1, len = 50, max = 0}
            cache_speed_buf = {0, pos = 1, len = 50, max = 0}
            cache_recorder_timer:resume()
        end
        display_timer:kill()
        display_timer.oneshot = oneshot
        display_timer.timeout = oneshot and o.duration or o.redraw_delay
        add_page_bindings()
        print_page(curr_page)
        display_timer:resume()
    end
end


-- 创建用于重绘（切换）或清除屏幕（一次性）的定时器
-- 这里的持续时间不重要，总是在 process_key_binding() 中设置
display_timer = mp.add_periodic_timer(o.duration,
    function()
        if display_timer.oneshot then
            display_timer:kill() ; clear_screen() ; remove_page_bindings()
            -- 仅当为搜索绑定打开控制台时才关闭它
            if searched_text then
                input.terminate()
            end
        else
            print_page(curr_page)
        end
    end)
display_timer:kill()

-- 一次性调用按键绑定
mp.add_key_binding(nil, "display-stats", function() process_key_binding(true) end,
    {repeatable=true})

-- 切换按键绑定
mp.add_key_binding(nil, "display-stats-toggle", function() process_key_binding(false) end,
    {repeatable=false})

for k, page in pairs(pages) do
    -- 特定页面的一次性调用按键绑定，例如：
    -- "e script-binding stats/display-page-2"
    mp.add_key_binding(nil, "display-page-" .. page.idx, function()
        curr_page = k
        process_key_binding(true)
    end, {repeatable=true})

    -- 切换特定页面的按键绑定，例如：
    -- "h script-binding stats/display-page-4-toggle"
    mp.add_key_binding(nil, "display-page-" .. page.idx .. "-toggle", function()
        curr_page = k
        process_key_binding(false)
    end, {repeatable=false})
end

-- 当 VO 重新配置时立即重新打印统计信息，仅在切换模式下
mp.register_event("video-reconfig",
    function()
        if display_timer:is_enabled() and not display_timer.oneshot then
            print_page(curr_page)
        end
    end)

if o.bindlist ~= "no" then
    -- 这是一种特殊模式，用于将按键绑定打印到终端
    -- 调整打印格式和级别，使其只打印按键绑定
    mp.set_property("msg-level", "all=no,statusline=status")
    mp.set_property("term-osd", "force")
    mp.set_property_bool("msg-module", false)
    mp.set_property_bool("msg-time", false)
    -- 等待所有其他脚本完成初始化
    mp.add_timeout(0, function()
        if o.bindlist:sub(1, 1) == "-" then
            o.no_ass_b0 = ""
            o.no_ass_b1 = ""
        end
        o.ass_formatting = false
        o.no_ass_indent = " "
        mp.osd_message(keybinding_info(false, true))
        -- 等待下一个 tick 打印状态行并刷新而不清除
        mp.add_timeout(0, function()
            mp.command("flush-status-line no")
            mp.command("quit")
        end)
    end)
end

mp.observe_property("osd-height", "native", update_scale)
mp.observe_property("osd-scale-by-window", "native", update_scale)

local function update_property_cache(name, value)
    property_cache[name] = value
end

mp.observe_property('current-window-scale', 'native', update_property_cache)
mp.observe_property('display-names', 'string', update_property_cache)
mp.observe_property('hwdec-current', 'string', update_property_cache)