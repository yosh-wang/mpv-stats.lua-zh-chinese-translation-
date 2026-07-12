-- Display some stats.
--
-- Please consult the readme for information about usage and configuration:
-- https://github.com/Argon-/mpv-stats
--
-- Please note: not every property is always available and therefore not always
-- visible.


-- ============================================================
-- 以下是原版文件内容（保持不变）
-- ============================================================

local mp = require 'mp'
local utils = require 'mp.utils'
local input = require 'mp.input'

-- Options
local o = {
    -- Default key bindings
    key_page_1 = "1",
    key_page_2 = "2",
    key_page_3 = "3",
    key_page_4 = "4",
    key_page_5 = "5",
    key_page_0 = "0",
    -- For pages which support scrolling
    key_scroll_up = "UP",
    key_scroll_down = "DOWN",
    key_search = "/",
    key_exit = "ESC",
    scroll_lines = 1,

    duration = 4,
    redraw_delay = 1,                -- acts as duration in the toggling case
    ass_formatting = true,
    persistent_overlay = false,      -- whether the stats can be overwritten by other output
    filter_params_max_length = 100,  -- show one filter per line if list exceeds this length
    file_tag_max_length = 128,       -- only show file tags shorter than this length in bytes
    file_tag_max_count = 16,         -- only show the first x file tags
    show_frame_info = false,         -- whether to show the current frame info
    term_clip = true,
    track_info_selected_only = true, -- only show selected track info
    debug = false,

    -- Graph options and style
    plot_perfdata = false,
    plot_vsync_ratio = false,
    plot_vsync_jitter = false,
    plot_cache = true,
    plot_tonemapping_lut = false,
    skip_frames = 5,
    global_max = true,
    flush_graph_data = true,         -- clear data buffers when toggling
    plot_bg_border_color = "0000FF",
    plot_bg_color = "262626",
    plot_color = "FFFFFF",
    plot_bg_border_width = 1.25,

    -- Text style
    font = "",
    font_mono = "monospace",   -- monospaced digits are sufficient
    font_size = 20,
    font_color = "",
    border_size = 1.65,
    border_color = "",
    shadow_x_offset = math.huge,
    shadow_y_offset = math.huge,
    shadow_color = "",
    alpha = "11",
    vidscale = "auto",

    -- Custom header for ASS tags to style the text output.
    -- Specifying this will ignore the text style values above and just
    -- use this string instead.
    custom_header = "",

    -- Text formatting
    -- With ASS
    ass_nl = "\\N",
    ass_indent = "\\h\\h\\h\\h\\h",
    ass_prefix_sep = "\\h\\h",
    ass_b1 = "{\\b1}",
    ass_b0 = "{\\b0}",
    ass_it1 = "{\\i1}",
    ass_it0 = "{\\i0}",
    -- Without ASS
    no_ass_nl = "\n",
    no_ass_indent = "    ",
    no_ass_prefix_sep = " ",
    no_ass_b1 = "\027[1m",
    no_ass_b0 = "\027[0m",
    no_ass_it1 = "\027[3m",
    no_ass_it0 = "\027[0m",

    bindlist = "no",  -- print page 4 to the terminal on startup and quit mpv
}

local update_scale
require "mp.options".read_options(o, nil, function ()
    update_scale()
end)

local format = string.format
local max = math.max
local min = math.min

-- Scaled metrics
local font_size = o.font_size
local border_size = o.border_size
local shadow_x_offset = o.shadow_x_offset
local shadow_y_offset = o.shadow_y_offset
local plot_bg_border_width = o.plot_bg_border_width
-- Function used to record performance data
local recorder = nil
-- Timer used for redrawing (toggling) and clearing the screen (oneshot)
local display_timer = nil
-- Timer used to update cache stats.
local cache_recorder_timer
-- Current page and <page key>:<page function> mappings
local curr_page = o.key_page_1
local pages = {}
local scroll_bound = false
local searched_text
local tm_viz_prev = nil
-- Save these sequences locally as we'll need them a lot
local ass_start = mp.get_property_osd("osd-ass-cc/0")
local ass_stop = mp.get_property_osd("osd-ass-cc/1")
-- Ring buffers for the values used to construct a graph.
-- .pos denotes the current position, .len the buffer length
-- .max is the max value in the corresponding buffer
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
        -- mp.osd_message supports ass-escape using osd-ass-cc/{0|1}
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


-- Generate a graph from the given values.
-- Returns an ASS formatted vector drawing as string.
--
-- values: Array/table of numbers representing the data. Used like a ring buffer
--         it will get iterated backwards `len` times starting at position `i`.
-- i     : Index of the latest data value in `values`.
-- len   : The length/amount of numbers in `values`.
-- v_max : The maximum number in `values`. It is used to scale all data
--         values to a range of 0 to `v_max`.
-- v_avg : The average number in `values`. It is used to try and center graphs
--         if possible. May be left as nil
-- scale : A value that will be multiplied with all data values.
-- x_tics: Horizontal width multiplier for the steps
local function generate_graph(values, i, len, v_max, v_avg, scale, x_tics)
    -- Check if at least one value exists
    if not values[i] then
        return ""
    end

    local x_max = (len - 1) * x_tics
    local y_offset = border_size
    local y_max = font_size * 0.66
    local x = 0

    if v_max > 0 then
        -- try and center the graph if possible, but avoid going above `scale`
        if v_avg and v_avg > 0 then
            scale = min(scale, v_max / (2 * v_avg))
        end
        scale = scale * y_max / v_max
    end  -- else if v_max==0 then all values are 0 and scale doesn't matter

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


-- Format and append a property.
-- A property whose value is either `nil` or empty (hereafter called "invalid")
-- is skipped and not appended.
-- Returns `false` in case nothing was appended, otherwise `true`.
--
-- s      : Table containing strings.
-- prop   : The property to query and format (based on its OSD representation).
-- attr   : Optional table to overwrite certain (formatting) attributes for
--          this property.
-- exclude: Optional table containing keys which are considered invalid values
--          for this property. Specifying this will replace empty string as
--          default invalid value (nil is always invalid).
-- cached : If true, use get_property_cached instead of get_property_osd
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
            print("No value for property: " .. prop)
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
    local hint = format("(hint: scroll with %s/%s", o.key_scroll_up, o.key_scroll_down)
    if search then
        hint = hint .. " and search with " .. o.key_search
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

    -- Sums of all last/avg/peak values
    local last_s, avg_s, peak_s = {}, {}, {}
    for frame, data in pairs(vo_p) do
        last_s[frame], avg_s[frame], peak_s[frame] = 0, 0, 0
        for _, pass in ipairs(data) do
            last_s[frame] = last_s[frame] + pass["last"]
            avg_s[frame]  = avg_s[frame]  + pass["avg"]
            peak_s[frame] = peak_s[frame] + pass["peak"]
        end
    end

    -- Pretty print measured time
    local function pp(i)
        -- rescale to microseconds for a saner display
        return format("%5d", i / 1000)
    end

    -- Format n/m with a font weight based on the ratio
    local function p(n, m)
        local i = 0
        if m > 0 then
            i = tonumber(n) / m
        end
        -- Calculate font weight. 100 is minimum, 400 is normal, 700 bold, 900 is max
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

    -- ensure that the fixed title is one element and every scrollable line is
    -- also one single element.
    local h = dedicated_page and header or s
    h[#h+1] = format("%s%s%s%s%s%s%s%s",
                     dedicated_page and "" or o.nl, dedicated_page and "" or o.indent,
                     bold("Frame Timings:"), o.prefix_sep, font_small,
                     "(last/average/peak μs)", font_normal,
                     dedicated_page and scroll_hint() or "")

    for _,frame in ipairs(sorted_keys(vo_p)) do  -- ensure fixed display order
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
                    -- use the same line that was already started for this iteration
                    s[#s] = s[#s] ..
                              generate_graph(pass["samples"], pass["count"],
                                             pass["count"], pass["peak"],
                                             pass["avg"], 0.9, 0.25)
                end
            end

            -- Print sum of timing values as "Total"
            s[#s+1] = format(f, o.nl, o.indent, o.indent,
                             font_mono, pp(last_s[frame]),
                             pp(avg_s[frame]), pp(peak_s[frame]),
                             o.prefix_sep, bold("Total"), font, "", "", "")
        else
            -- for the simplified view, we just print the sum of each pass
            s[#s+1] = format(f, o.nl, o.indent, o.indent, font_mono,
                            pp(last_s[frame]), pp(avg_s[frame]), pp(peak_s[frame]),
                            "", "", font, o.prefix_sep, o.prefix_sep,
                            frame:gsub("^%l", string.upper))
        end
    end
end

-- command prefix tokens to strip - includes generic property commands
local cmd_prefixes = {
    osd_auto=1, no_osd=1, osd_bar=1, osd_msg=1, osd_msg_bar=1, raw=1, sync=1,
    async=1, expand_properties=1, repeatable=1, nonrepeatable=1, nonscalable=1,
    set=1, add=1, multiply=1, toggle=1, cycle=1, cycle_values=1, ["!reverse"]=1,
    change_list=1,
}
-- commands/writable-properties prefix sub-words (followed by -) to strip
local name_prefixes = {
    define=1, delete=1, enable=1, disable=1, dump=1, write=1, drop=1, revert=1,
    ab=1, hr=1, secondary=1, current=1,
}
-- extract a command "subject" from a command string, by removing all
-- generic prefix tokens and then returning the first interesting sub-word
-- of the next token. For target-script name we also check another token.
-- The tokenizer works fine for things we care about - valid mpv commands,
-- properties and script names, possibly quoted, white-space[s]-separated.
-- It's decent in practice, and worst case is "incorrect" subject.
local function cmd_subject(cmd)
    cmd = cmd:gsub(";.*", ""):gsub("%-", "_")  -- only first cmd, s/-/_/
    local TOKEN = '^%s*["\']?([%w_!]*)'  -- captures+ends before (maybe) final "
    local tok, sname, subw

    repeat tok, cmd = cmd:match(TOKEN .. '["\']?(.*)')
    until not cmd_prefixes[tok]
    -- tok is the 1st non-generic command/property name token, cmd is the rest

    sname = tok == "script_message_to" and cmd:match(TOKEN)
         or tok == "script_binding" and cmd:match(TOKEN .. "/")
    if sname and sname ~= "" then
        return "script: " .. sname
    end

    -- return the first sub-word of tok which is not a useless prefix
    repeat subw, tok = tok:match("([^_]*)_?(.*)")
    until tok == "" or not name_prefixes[subw]
    return subw:len() > 1 and subw or "[unknown]"
end

-- key names are valid UTF-8, ascii7 except maybe the last/only codepoint.
-- we count codepoints and ignore wcwidth. no need for grapheme clusters.
-- our error for alignment is at most one cell (if last CP is double-width).
-- (if k was valid but arbitrary: we'd count all bytes <0x80 or >=0xc0)
local function keyname_cells(k)
    local klen = k:len()
    if klen > 1 and k:byte(klen) >= 0x80 then  -- last/only CP is not ascii7
        repeat klen = klen-1
        until klen == 1 or k:byte(klen) >= 0xc0  -- last CP begins at klen
    end
    return klen
end

local function get_kbinfo_lines()
    -- active keys: only highest priority of each key, and not our (stats) keys
    local bindings = mp.get_property_native("input-bindings", {})
    local active = {}  -- map: key-name -> bind-info
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

    -- make an array, find max key len, add sort keys (.subject/.mods[_count])
    local ordered = {}
    local kspaces = ""  -- as many spaces as the longest key name
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

    -- sort by: subject, mod(ifier)s count, mods, key-len, lowercase-key, key
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
            return a.key > b.key  -- only case differs, lowercase first
        end
    end)

    -- key/subject pre/post formatting for terminal/ass.
    -- key/subject alignment uses spaces (with mono font if ass)
    -- word-wrapping is disabled for ass, or cut at 79 for the terminal
    local LTR = string.char(0xE2, 0x80, 0x8E)  -- U+200E Left To Right mark
    local term = not o.use_ass
    local kpre = term and "" or format("{\\q2\\fn%s}%s", o.font_mono, LTR)
    local kpost = term and " " or format(" {\\fn%s}", o.font)
    local spre = term and kspaces .. "   "
                       or format("{\\q2\\fn%s}%s   {\\fn%s}{\\fs%d\\u1}",
                                 o.font_mono, kspaces, o.font, 1.3*font_size)
    local spost = term and "" or format("{\\u0\\fs%d}%s", font_size, text_style())

    -- create the display lines
    local info_lines = {}
    local subject = nil
    for _, bind in ipairs(ordered) do
        if bind.subject ~= subject then  -- new subject (title)
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

    local vspeed = append_property(s, "video-speed-correction", {prefix="DS:"})
    if vspeed then
        append_property(s, "audio-speed-correction",
                        {prefix="/", nl="", indent=" ", prefix_sep=" ", no_prefix_markup=true})
    else
        append_property(s, "audio-speed-correction",
                        {prefix="DS:" .. o.prefix_sep .. " - / ", prefix_sep=""})
    end

    append_property(s, "mistimed-frame-count", {prefix="Mistimed:", nl="",
                                                indent=o.prefix_sep .. o.prefix_sep})
    append_property(s, "vo-delayed-frame-count", {prefix="Delayed:", nl="",
                                                  indent=o.prefix_sep .. o.prefix_sep})

    -- As we need to plot some graphs we print jitter and ratio on their own lines
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
        append_property(s, "vsync-ratio", {prefix="VSync Ratio:",
                                           suffix=o.prefix_sep .. ratio_graph})
        append_property(s, "vsync-jitter", {prefix="VSync Jitter:",
                                            suffix=o.prefix_sep .. jitter_graph})
    else
        -- Since no graph is needed we can print ratio/jitter on the same line and save some space
        local vr = append_property(s, "vsync-ratio", {prefix="VSync Ratio:"})
        append_property(s, "vsync-jitter", {prefix="VSync Jitter:",
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
            n = n .. " (disabled)"
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
    append(s, "", {prefix="File:", nl="", indent=""})
    append_property(s, "filename", {prefix_sep="", nl="", indent=""})
    if mp.get_property_osd("filename") ~= mp.get_property_osd("media-title") then
        append_property(s, "media-title", {prefix="Title:"})
    end

    if print_tags then
        append_property(s, "duration", {prefix="Duration:"})
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
                       {prefix="Edition:"})
        append_property(s, "edition-list/count",
                        {prefix="(" .. tostring(edition + 1) .. "/", suffix=")", nl="",
                         indent=" ", prefix_sep=" ", no_prefix_markup=true})
    end

    local ch_index = mp.get_property_number("chapter")
    if ch_index and ch_index >= 0 then
        append_property(s, "chapter-list/" .. tostring(ch_index) .. "/title", {prefix="Chapter:",
                        nl=ed_cond and "" or o.nl})
        append_property(s, "chapter-list/count",
                        {prefix="(" .. tostring(ch_index + 1) .. " /", suffix=")", nl="",
                         indent=" ", prefix_sep=" ", no_prefix_markup=true})
    end

    local fs = append_property(s, "file-size", {prefix="Size:"})
    append_property(s, "file-format", {prefix="Format/Protocol:",
                                       nl=fs and "" or o.nl,
                                       indent=fs and o.prefix_sep .. o.prefix_sep})

    if not print_cache then
        return
    end

    local demuxer_cache = mp.get_property_native("demuxer-cache-state", {})
    if demuxer_cache["fw-bytes"] then
        demuxer_cache = demuxer_cache["fw-bytes"] -- returns bytes
    else
        demuxer_cache = 0
    end
    local demuxer_secs = mp.get_property_number("demuxer-cache-duration", 0)
    if demuxer_cache + demuxer_secs > 0 then
        append(s, utils.format_bytes_humanized(demuxer_cache), {prefix="Total Cache:"})
        append(s, format("%.1f", demuxer_secs), {prefix="(", suffix=" sec)", nl="",
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
        -- We can skip crop if it is the same as video decoded resolution
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

    -- If we are printing video out parameters it is just display, not mastering
    local display_prefix = video_out and "Display:" or "Mastering display:"

    local indent = ""
    local has_dml = has(hdr["min-luma"], 0.203) or has(hdr["max-luma"], 203)
    local has_cll = hdr["max-cll"] and hdr["max-cll"] > 0
    local has_fall = hdr["max-fall"] and hdr["max-fall"] > 0

    if has_dml or has_cll or has_fall then
        append(s, "", {prefix=video_out and "" or "HDR10:", prefix_sep=video_out and "" or nil})
        if has_dml then
            -- libplacebo uses close to zero values as "defined zero"
            hdr["min-luma"] = hdr["min-luma"] <= 1e-6 and 0 or hdr["min-luma"]
            append(s, format("%.2g / %.0f", hdr["min-luma"], hdr["max-luma"]),
                {prefix=display_prefix, suffix=" cd/m²", nl="", indent=indent})
            indent = o.prefix_sep .. o.prefix_sep
        end
        if has_cll then
            append(s, string.format("%.0f", hdr["max-cll"]), {prefix="MaxCLL:",
                                    suffix=" cd/m²", nl="", indent=indent})
            indent = o.prefix_sep .. o.prefix_sep
        end
        if has_fall then
            append(s, hdr["max-fall"], {prefix="MaxFALL:", suffix=" cd/m²", nl="",
                                        indent=indent})
        end
    end

    indent = o.prefix_sep .. o.prefix_sep

    if hdr["scene-max-r"] or hdr["scene-max-g"] or
       hdr["scene-max-b"] or hdr["scene-avg"] then
        append(s, "", {prefix="HDR10+:"})
        append(s, format("%.1f / %.1f / %.1f", hdr["scene-max-r"] or 0,
                         hdr["scene-max-g"] or 0, hdr["scene-max-b"] or 0),
               {prefix="MaxRGB:", suffix=" cd/m²", nl="", indent=""})
        append(s, format("%.1f", hdr["scene-avg"] or 0),
               {prefix="Avg:", suffix=" cd/m²", nl="", indent=indent})
    end

    if hdr["max-pq-y"] and hdr["avg-pq-y"] then
        append(s, "", {prefix="PQ(Y):"})
        append(s, format("%.2f cd/m² (%.2f%% PQ)", pq_eotf(hdr["max-pq-y"]),
                         hdr["max-pq-y"] * 100), {prefix="Max:", nl="",
                         indent=""})
        append(s, format("%.2f cd/m² (%.2f%% PQ)", pq_eotf(hdr["avg-pq-y"]),
                         hdr["avg-pq-y"] * 100), {prefix="Avg:", nl="",
                         indent=indent})
    end
end


local function append_img_params(s, r, ro)
    if not r then
        return
    end

    append_resolution(s, r, "Resolution:", "w", "h", true)
    if ro and (r["w"] ~= ro["dw"] or r["h"] ~= ro["dh"]) then
        if ro["crop-w"] and (crop_noop(r["w"], r["h"], ro) or crop_equal(r, ro)) then
            ro["crop-w"] = nil
        end
        append_resolution(s, ro, "Output Resolution:", "dw", "dh")
    end

    local indent = o.prefix_sep .. o.prefix_sep
    r = ro or r

    local pixel_format = r["hw-pixelformat"] or r["pixelformat"]
    append(s, pixel_format, {prefix="Format:"})
    append(s, r["colorlevels"], {prefix="Levels:", nl="", indent=indent})
    if r["chroma-location"] and r["chroma-location"] ~= "unknown" then
        append(s, r["chroma-location"], {prefix="Chroma Loc:", nl="", indent=indent})
    end

    -- Group these together to save vertical space
    append(s, r["colormatrix"], {prefix="Colormatrix:"})
    if r["prim-red-x"] or r["prim-red-y"] or
       r["prim-green-x"] or r["prim-green-y"] or
       r["prim-blue-x"] or r["prim-blue-y"] or
       r["prim-white-x"] or r["prim-white-y"] then
        append(s, string.format("[%.3f %.3f, %.3f %.3f, %.3f %.3f, %.3f %.3f]",
                                r["prim-red-x"] or 0, r["prim-red-y"] or 0,
                                r["prim-green-x"] or 0, r["prim-green-y"] or 0,
                                r["prim-blue-x"] or 0, r["prim-blue-y"] or 0,
                                r["prim-white-x"] or 0, r["prim-white-y"] or 0),
            {prefix="Primaries:", nl="", indent=indent})
        append(s, r["primaries"], {prefix="使用", nl="", indent=" ", prefix_sep=" ",
                                   no_prefix_markup=true})
    else
        append(s, r["primaries"], {prefix="Primaries:", nl="", indent=indent})
    end
    append(s, r["gamma"], {prefix="Transfer:", nl="", indent=indent})
end


local function append_fps(s, prop, eprop)
    local fps = mp.get_property_osd(prop)
    local efps = mp.get_property_osd(eprop)
    local single = eprop == "" or (fps ~= "" and efps ~= "" and fps == efps)
    local unit = prop == "display-fps" and " Hz" or " fps"
    local suffix = single and "" or " (specified)"
    local esuffix = single and "" or " (estimated)"
    local prefix = prop == "display-fps" and "Refresh Rate:" or "Frame Rate:"
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

    append(s, "", {prefix="Display:", nl=o.nl .. o.nl, indent=""})
    append(s, vo, {prefix_sep="", nl="", indent=""})

    append_property(s, "display-names", {prefix_sep="", prefix="(", suffix=")",
                    no_prefix_markup=true, nl="", indent=" "}, nil, true)
    append(s, mp.get_property_native("current-gpu-context"),
           {prefix="Context:", nl="", indent=o.prefix_sep .. o.prefix_sep})
    append_property(s, "avsync", {prefix="A-V:"})
    append_fps(s, "display-fps", "estimated-display-fps")
    if append_property(s, "decoder-frame-drop-count",
                       {prefix="Dropped Frames:", suffix=" (decoder)"}) then
        append_property(s, "frame-drop-count", {suffix=" (output)", nl="", indent=""})
    end
    append_display_sync(s)
    append_perfdata(nil, s, false)

    if mp.get_property_native("deinterlace-active") then
        append_property(s, "deinterlace", {prefix="Deinterlacing:"})
    end

    local scale = nil
    if not mp.get_property_native("fullscreen") then
        scale = get_property_cached("current-window-scale")
    end

    local od = mp.get_property_native("osd-dimensions")
    local rt = mp.get_property_native("video-target-params")
    local r = rt or {}

    -- Add window scale
    r["s"] = scale
    r["crop-x"] = od["ml"]
    r["crop-y"] = od["mt"]
    r["crop-w"] = od["w"] - od["ml"] - od["mr"]
    r["crop-h"] = od["h"] - od["mt"] - od["mb"]

    if not rt then
        r["w"] = r["crop-w"]
        r["h"] = r["crop-h"]
        append_resolution(s, r, "Resolution:", "w", "h", true)
        return
    end

    append_img_params(s, r)
    append_hdr(s, r, true)
end


local function add_video(s)
    local r = mp.get_property_native("video-params")
    local ro = mp.get_property_native("video-out-params")
    -- in case of e.g. lavfi-complex there can be no input video, only output
    if not r then
        r = ro
    end
    if not r then
        return
    end

    local track = mp.get_property_native("current-tracks/video")
    local track_type = (track and track.image) and "Image:" or "Video:"
    append(s, "", {prefix=track_type, nl=o.nl .. o.nl, indent=""})
    if track and append(s, track["codec-desc"], {prefix_sep="", nl="", indent=""}) then
        append(s, track["codec-profile"], {prefix="[", nl="", indent=" ", prefix_sep="",
               no_prefix_markup=true, suffix="]"})
        if track["codec"] ~= track["decoder"] then
            append(s, track["decoder"], {prefix="[", nl="", indent=" ", prefix_sep="",
                   no_prefix_markup=true, suffix="]"})
        end
        append_property(s, "hwdec-current", {prefix="HW:", nl="",
                        indent=o.prefix_sep .. o.prefix_sep,
                        no_prefix_markup=false, suffix=""}, {no=true, [""]=true}, true)
    end
    local has_prefix = false
    if o.show_frame_info then
        if append_property(s, "estimated-frame-number", {prefix="Frame:"}) then
            append_property(s, "estimated-frame-count", {indent=" / ", nl="",
                                                        prefix_sep=""})
            has_prefix = true
        end
        local frame_info = mp.get_property_native("video-frame-info")
        if frame_info and frame_info["picture-type"] then
            local attrs = has_prefix and {prefix="(", suffix=")", indent=" ", nl="",
                                          prefix_sep="", no_prefix_markup=true}
                                      or {prefix="Picture Type:"}
            append(s, frame_info["picture-type"], attrs)
            has_prefix = true
        end
        if frame_info and frame_info["interlaced"] then
            local attrs = has_prefix and {indent=" ", nl="", prefix_sep=""}
                                      or {prefix="Picture Type:"}
            append(s, "Interlaced", attrs)
        end

        local timecodes = {
            ["gop-timecode"] = "GOP",
            ["smpte-timecode"] = "SMPTE",
            ["estimated-smpte-timecode"] = "Estimated SMPTE",
        }
        for prop, name in pairs(timecodes) do
            if frame_info and frame_info[prop] then
                local attrs = has_prefix and {prefix=name .. " Timecode:",
                                              indent=o.prefix_sep .. o.prefix_sep, nl=""}
                                          or {prefix=name .. " Timecode:"}
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
    append_property(s, "video-bitrate", {prefix="Bitrate:"})
    append_filters(s, "vf", "Filters:")
end


local function add_audio(s)
    local r = mp.get_property_native("audio-params")
    -- in case of e.g. lavfi-complex there can be no input audio, only output
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

    append(s, "", {prefix="Audio:", nl=o.nl .. o.nl, indent=""})
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
    append_property(s, "current-ao", {prefix="AO:", nl="",
                                      indent=o.prefix_sep .. o.prefix_sep})
    local dev = append_property(s, "audio-device", {prefix="Device:"})
    local ao_mute = mp.get_property_native("ao-mute") and " (Muted)" or ""
    append_property(s, "ao-volume", {prefix="AO Volume:", suffix="%" .. ao_mute,
                                     nl=dev and "" or o.nl,
                                     indent=dev and o.prefix_sep .. o.prefix_sep})
    if math.abs(mp.get_property_native("audio-delay")) > 1e-6 then
        append_property(s, "audio-delay", {prefix="A-V delay:"})
    end
    local cc = append(s, merge(r, ro, "channel-count"), {prefix="Channels:"})
    append(s, merge(r, ro, "format"), {prefix="Format:", nl=cc and "" or o.nl,
                            indent=cc and o.prefix_sep .. o.prefix_sep})
    append(s, merge(r, ro, "samplerate"), {prefix="Sample Rate:", suffix=" Hz"})
    append_property(s, "audio-bitrate", {prefix="Bitrate:"})
    append_filters(s, "af", "Filters:")
end


-- Determine whether ASS formatting shall/can be used and set formatting sequences
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

-- split str into a table
-- example: local t = split(s, "\n")
-- plain: whether pat is a plain string (default false - pat is a pattern)
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

-- Composes the output with header and scrollable content
-- Returns string of the finished page and the actually chosen offset
--
-- header      : table of the header where each entry is one line
-- content     : table of the content where each entry is one line
-- apply_scroll: scroll the content
local function finalize_page(header, content, apply_scroll)
    local term_height = mp.get_property_native("term-size/h", 24)
    local from, to = 1, #content
    if apply_scroll then
        -- Up to 40 lines for libass because it can put a big performance toll on
        -- libass to process many lines which end up outside (below) the screen.
        -- In the terminal reduce height by 2 for the status line (can be more then one line)
        local max_content_lines = (o.use_ass and 40 or term_height - 2) - #header
        -- in the terminal the scrolling should stop once the last line is visible
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

-- Returns an ASS string with "normal" stats
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

-- Returns an ASS string with extended VO stats
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

    local type = t.image and "Image" or t["type"]:sub(1, 1):upper() .. t["type"]:sub(2)
    append(c, "", {prefix=type .. ":", nl=o.nl .. o.nl, indent=""})
    append(c, t["title"], {prefix_sep="", nl="", indent=""})
    append(c, t["id"], {prefix="ID:"})
    append(c, t["src-id"], {prefix="Demuxer ID:", nl="", indent=o.prefix_sep .. o.prefix_sep})
    append(c, t["program-id"], {prefix="Program ID:", nl="", indent=o.prefix_sep .. o.prefix_sep})
    append(c, t["ff-index"], {prefix="FFmpeg Index:", nl="", indent=o.prefix_sep .. o.prefix_sep})
    append(c, t["external-filename"], {prefix="File:"})
    append(c, "", {prefix="Flags:"})
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
    if append(c, t["codec-desc"], {prefix="Codec:"}) then
        append(c, t["codec-profile"], {prefix="[", nl="", indent=" ", prefix_sep="",
               no_prefix_markup=true, suffix="]"})
        if t["codec"] ~= t["decoder"] then
            append(c, t["decoder"], {prefix="[", nl="", indent=" ", prefix_sep="",
                   no_prefix_markup=true, suffix="]"})
        end
    end
    append(c, t["lang"], {prefix="Language:"})
    append(c, t["demux-channel-count"], {prefix="Channels:"})
    append(c, t["demux-channels"], {prefix="Channel Layout:"})
    append(c, t["demux-samplerate"], {prefix="Sample Rate:", suffix=" Hz"})
    local function B(b) return b and string.format("%.2f", b / 1024) end
    local bitrate = append(c, B(t["demux-bitrate"]), {prefix="Bitrate:", suffix=" kbps"})
    append(c, B(t["hls-bitrate"]), {prefix="HLS Bitrate:", suffix=" kbps",
                                    nl=bitrate and "" or o.nl,
                                    indent=bitrate and o.prefix_sep .. o.prefix_sep})
    append_resolution(c, {w=t["demux-w"], h=t["demux-h"], ["crop-x"]=t["demux-crop-x"],
                          ["crop-y"]=t["demux-crop-y"], ["crop-w"]=t["demux-crop-w"],
                          ["crop-h"]=t["demux-crop-h"]}, "Resolution:")
    if not t["image"] and t["demux-fps"] then
        append_fps(c, "track-list/" .. i .. "/demux-fps", "")
    end
    append(c, t["format-name"], {prefix="Format:"})
    append(c, t["demux-rotation"], {prefix="Rotation:"})
    if t["demux-par"] then
        local num, den = float2rational(t["demux-par"])
        append(c, string.format("%d:%d", num, den), {prefix="Pixel Aspect Ratio:"})
    end
    local track_rg = t["replaygain-track-peak"] ~= nil or t["replaygain-track-gain"] ~= nil
    local album_rg = t["replaygain-album-peak"] ~= nil or t["replaygain-album-gain"] ~= nil
    if track_rg or album_rg then
        append(c, "", {prefix="Replay Gain:"})
    end
    if track_rg then
        append(c, "", {prefix="Track:", indent=o.indent .. o.prefix_sep, prefix_sep=""})
        append(c, t["replaygain-track-gain"], {prefix="Gain:", suffix=" dB",
                                               nl="", indent=o.prefix_sep})
        append(c, t["replaygain-track-peak"], {prefix="Peak:", suffix=" dB",
                                               nl="", indent=o.prefix_sep})
    end
    if album_rg then
        append(c, "", {prefix="Album:", indent=o.indent .. o.prefix_sep, prefix_sep=""})
        append(c, t["replaygain-album-gain"], {prefix="Gain:", suffix=" dB",
                                               nl="", indent=o.prefix_sep})
        append(c, t["replaygain-album-peak"], {prefix="Peak:", suffix=" dB",
                                               nl="", indent=o.prefix_sep})
    end
    if t["dolby-vision-profile"] or t["dolby-vision-level"] then
        append(c, "", {prefix="Dolby Vision:"})
        append(c, t["dolby-vision-profile"], {prefix="Profile:", nl="", indent=""})
        append(c, t["dolby-vision-level"], {prefix="Level:", nl="",
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

-- Returns an ASS string with stats about the demuxer cache etc.
local function cache_stats()
    local stats = {}

    eval_ass_formatting()
    add_header(stats)
    append(stats, "", {prefix="Cache Info:", nl="", indent=""})

    local info = mp.get_property_native("demuxer-cache-state")
    if info == nil then
        append(stats, "Unavailable.", {})
        return finalize_page({}, stats, false)
    end

    local a = info["reader-pts"]
    local b = info["cache-end"]

    append(stats, opt_time(a) .. " - " .. opt_time(b), {prefix = "Packet Queue:"})

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
    append(stats, opt_time(r), {prefix = "Readahead:", suffix = r_graph})

    -- These states are not necessarily exclusive. They're about potentially
    -- separate mechanisms, whose states may be decoupled.
    local state = "reading"
    local seek_ts = info["debug-seeking"]
    if seek_ts ~= nil then
        state = "seeking (to " .. mp.format_time(seek_ts) .. ")"
    elseif info["eof"] == true then
        state = "eof"
    elseif info["underrun"] then
        state = "underrun"
    elseif info["idle"]  == true then
        state = "inactive"
    end
    append(stats, state, {prefix = "State:"})

    local speed = info["raw-input-rate"] or 0
    local speed_graph = nil
    if not display_timer.oneshot and o.use_ass and o.plot_cache then
        speed_graph = generate_graph(cache_speed_buf, cache_speed_buf.pos,
                                     cache_speed_buf.len, cache_speed_buf.max,
                                     nil, 0.8, 1)
        speed_graph = o.prefix_sep .. speed_graph
    end
    append(stats, utils.format_bytes_humanized(speed) .. "/s", {prefix="Speed:",
        suffix=speed_graph})

    append(stats, utils.format_bytes_humanized(info["total-bytes"]),
           {prefix = "Total RAM:"})
    append(stats, utils.format_bytes_humanized(info["fw-bytes"]),
           {prefix = "Forward RAM:"})

    local fc = info["file-cache-bytes"]
    if fc ~= nil then
        fc = utils.format_bytes_humanized(fc)
    else
        fc = "(disabled)"
    end
    append(stats, fc, {prefix = "Disk Cache:"})

    append(stats, info["debug-low-level-seeks"], {prefix = "Media Seeks:"})
    append(stats, info["debug-byte-level-seeks"], {prefix = "Stream Seeks:"})

    append(stats, "", {prefix="Ranges:", nl=o.nl .. o.nl, indent=""})

    append(stats, info["bof-cached"] and "yes" or "no",
           {prefix = "Start Cached:"})
    append(stats, info["eof-cached"] and "yes" or "no",
           {prefix = "End Cached:"})

    local ranges = info["seekable-ranges"] or {}
    for n, range in ipairs(ranges) do
        append(stats, mp.format_time(range["start"]) .. " - " ..
                      mp.format_time(range["end"]),
               {prefix = "Range " .. n .. ":"})
    end

    return finalize_page({}, stats, false)
end

-- Record 1 sample of cache statistics.
-- (Unlike record_data(), this does not return a function, but runs directly.)
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

-- Current page and <page key>:<page function> mapping
curr_page = o.key_page_1
pages = {
    [o.key_page_1] = { idx = 1, f = default_stats, desc = "Default" },
    [o.key_page_2] = { idx = 2, f = vo_stats, desc = "Extended Frame Timings", scroll = true },
    [o.key_page_3] = { idx = 3, f = cache_stats, desc = "Cache Statistics" },
    [o.key_page_4] = { idx = 4, f = keybinding_info, desc = "Active Key Bindings", scroll = true },
    [o.key_page_5] = { idx = 5, f = track_info, desc = "Tracks Info", scroll = true },
    [o.key_page_0] = { idx = 0, f = perf_stats, desc = "Internal Performance Info", scroll = true },
}


-- Returns a function to record vsratio/jitter with the specified `skip` value
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

-- Call the function for `page` and print it to OSD
local function print_page(page, after_scroll)
    -- the page functions assume we start in ass-enabled mode.
    -- that's true for mp.set_osd_ass, but not for mp.osd_message.
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

    -- Calculate scaled metrics.
    -- Make font_size=n the same size as --osd-font-size=n.
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
        prompt = "Filter bindings:",
        opened = function ()
            -- This is necessary to close the console if the oneshot
            -- display_timer expires without typing anything.
            searched_text = ""

            -- Must be re-bound to override the console.lua bindings.
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
    -- Don't bind in oneshot mode because if ESC is pressed right when the stats
    -- stop being displayed, it would unintentionally trigger any user-defined
    -- ESC binding.
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

-- Add keybindings for every page
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


-- Remove keybindings for every page
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
    -- Stats are already being displayed
    if display_timer:is_enabled() then
        -- Previous and current keys were oneshot -> restart timer
        if display_timer.oneshot and oneshot then
            display_timer:kill()
            print_page(curr_page)
            display_timer:resume()
        -- Previous and current keys were toggling -> end toggling
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
    -- No stats are being displayed yet
    else
        if not oneshot and (o.plot_vsync_jitter or o.plot_vsync_ratio) then
            recorder = record_data(o.skip_frames)
            -- Rely on the fact that "vsync-ratio" is updated at the same time.
            -- Using "none" to get a sample any time, even if it does not change.
            -- Will stop working if "vsync-jitter" property change notification
            -- changes, but it's fine for an internal script.
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


-- Create the timer used for redrawing (toggling) or clearing the screen (oneshot)
-- The duration here is not important and always set in process_key_binding()
display_timer = mp.add_periodic_timer(o.duration,
    function()
        if display_timer.oneshot then
            display_timer:kill() ; clear_screen() ; remove_page_bindings()
            -- Close the console only if it was opened for searching bindings.
            if searched_text then
                input.terminate()
            end
        else
            print_page(curr_page)
        end
    end)
display_timer:kill()

-- Single invocation key binding
mp.add_key_binding(nil, "display-stats", function() process_key_binding(true) end,
    {repeatable=true})

-- Toggling key binding
mp.add_key_binding(nil, "display-stats-toggle", function() process_key_binding(false) end,
    {repeatable=false})

for k, page in pairs(pages) do
    -- Single invocation key bindings for specific pages, e.g.:
    -- "e script-binding stats/display-page-2"
    mp.add_key_binding(nil, "display-page-" .. page.idx, function()
        curr_page = k
        process_key_binding(true)
    end, {repeatable=true})

    -- Key bindings to toggle a specific page, e.g.:
    -- "h script-binding stats/display-page-4-toggle".
    mp.add_key_binding(nil, "display-page-" .. page.idx .. "-toggle", function()
        curr_page = k
        process_key_binding(false)
    end, {repeatable=false})
end

-- Reprint stats immediately when VO was reconfigured, only when toggled
mp.register_event("video-reconfig",
    function()
        if display_timer:is_enabled() and not display_timer.oneshot then
            print_page(curr_page)
        end
    end)

if o.bindlist ~= "no" then
    -- This is a special mode to print key bindings to the terminal,
    -- Adjust the print format and level to make it print only the key bindings.
    mp.set_property("msg-level", "all=no,statusline=status")
    mp.set_property("term-osd", "force")
    mp.set_property_bool("msg-module", false)
    mp.set_property_bool("msg-time", false)
    -- wait for all other scripts to finish init
    mp.add_timeout(0, function()
        if o.bindlist:sub(1, 1) == "-" then
            o.no_ass_b0 = ""
            o.no_ass_b1 = ""
        end
        o.ass_formatting = false
        o.no_ass_indent = " "
        mp.osd_message(keybinding_info(false, true))
        -- wait for next tick to print status line and flush it without clearing
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





-- ============================================================
-- 自动翻译模块 - 全局替换版（yosh.wang_20260712）（QQ交流群：1097053691）
-- ============================================================

-- 通用词汇翻译表
local function auto_translate_text(text)
    if not text or type(text) ~= "string" then
        return text
    end
    
    local translations = {
        -- ==================== 页面标题 ====================
        ["Default"] = "默认信息",
        ["Extended Frame Timings"] = "扩展帧耗时",
        ["Cache Statistics"] = "缓存统计",
        ["Active Key Bindings"] = "活动按键绑定",
        ["Tracks Info"] = "轨道信息",
        ["Internal Performance Info"] = "内部性能信息",
        
        -- ==================== 文件/媒体信息 ====================
        ["File:"] = "文件：",
        ["Title:"] = "标题：",
        ["Duration:"] = "时长：",
        ["Edition:"] = "版本：",
        ["Chapter:"] = "章节：",
        ["Size:"] = "大小：",
        ["Format/Protocol:"] = "格式/协议：",
        ["Total Cache:"] = "总缓存：",
        [" sec)"] = " 秒）",
        [" sec"] = " 秒",
        [" fps (specified)"] = " fps（指定）",
        [" fps (estimated)"] = " fps（估计）",
        [" fps"] = " fps",
        [" Hz (specified)"] = " Hz（指定）",
        [" Hz (estimated)"] = " Hz（估计）",
        [" Hz"] = " Hz",
        [" kbps"] = " kbps",
        [" (specified)"] = "（指定）",
        [" (estimated)"] = "（估计）",
        
        -- ==================== 视频/显示器信息 ====================
        ["Display:"] = "显示器：",
        ["Context:"] = "渲染后端：",
        ["A-V:"] = "音视频同步：",
        ["Refresh Rate:"] = "刷新率：",
        ["Frame Rate:"] = "帧率：",
        ["Dropped Frames:"] = "丢帧：",
        [" (decoder)"] = "（解码器）",
        [" (output)"] = "（输出）",
        ["Deinterlacing:"] = "去隔行：",
        ["Resolution:"] = "分辨率：",
        ["Output Resolution:"] = "输出分辨率：",
        ["Format:"] = "格式：",
        ["Levels:"] = "色彩范围：",
        ["Chroma Loc:"] = "色度位置：",
        ["Colormatrix:"] = "色彩矩阵：",
        ["Primaries:"] = "色域基色：",
        ["Transfer:"] = "传输函数：",
        ["Bitrate:"] = "码率：",
        ["Filters:"] = "滤镜：",
        ["HW:"] = "硬解：",
        ["AO:"] = "音频输出：",
        ["Device:"] = "设备：",
        ["AO Volume:"] = "音量：",
        [" (Muted)"] = "（静音）",
        ["A-V delay:"] = "音视频延迟：",
        ["Channels:"] = "声道数：",
        ["Sample Rate:"] = "采样率：",
        
        -- ==================== 显示同步 ====================
        ["DS:"] = "显示同步：",
        ["Mistimed:"] = "错时帧：",
        ["Delayed:"] = "延迟帧：",
        ["VSync Ratio:"] = "垂直同步比率：",
        ["VSync Jitter:"] = "垂直同步抖动：",
        
        -- ==================== HDR相关 ====================
        ["Mastering display:"] = "母版显示：",
        ["MaxCLL:"] = "最大内容亮度：",
        ["MaxFALL:"] = "最大帧平均亮度：",
        ["MaxRGB:"] = "最大RGB：",
        ["Avg:"] = "平均：",
        [" cd/m²"] = " cd/m²",
        ["HDR10:"] = "HDR10：",
        ["HDR10+:"] = "HDR10+：",
        ["PQ(Y):"] = "PQ(Y)：",
        ["Max:"] = "最大：",
        -- ["in"] = "使用",   -- 不启用：模糊匹配会破坏包含 "in" 的英文单词（Container, Vision 等）
        
        -- ==================== 视频轨道信息 ====================
        ["Video:"] = "视频：",
        ["Audio:"] = "音频：",
        ["Image:"] = "图像：",
        ["Frame:"] = "帧：",
        ["Picture Type:"] = "画面类型：",
        ["Interlaced"] = "隔行扫描",
        ["Timecode:"] = "时间码：",
        ["GOP"] = "GOP",
        ["SMPTE"] = "SMPTE",
        ["Estimated SMPTE"] = "估计SMPTE",
        ["GOP Timecode:"] = "GOP时间码：",
        ["SMPTE Timecode:"] = "SMPTE时间码：",
        ["Estimated SMPTE Timecode:"] = "估计SMPTE时间码：",
        
        -- ==================== 帧耗时页面 ====================
        ["Frame Timings:"] = "帧耗时：",
        ["Total"] = "总计",
        ["(last/average/peak μs)"] = "（最新/平均/峰值 微秒）",
        
        -- ==================== 缓存信息 ====================
        ["Cache Info:"] = "缓存信息：",
        ["Packet Queue:"] = "数据包队列：",
        ["Readahead:"] = "预读：",
        ["State:"] = "状态：",
        ["reading"] = "读取中",
        ["eof"] = "文件尾",
        ["underrun"] = "缓存不足",
        ["inactive"] = "空闲",
        ["seeking"] = "定位中",
        ["Speed:"] = "速度：",
        ["Total RAM:"] = "总内存：",
        ["Forward RAM:"] = "前向内存：",
        ["Disk Cache:"] = "磁盘缓存：",
        ["(disabled)"] = "（已禁用）",
        ["Media Seeks:"] = "媒体定位：",
        ["Stream Seeks:"] = "流定位：",
        ["Ranges:"] = "范围：",
        ["Start Cached:"] = "起始已缓存：",
        ["End Cached:"] = "结尾已缓存：",
        ["Range "] = "范围 ",
        ["Unavailable."] = "不可用。",
        ["yes"] = "是",
        ["no"] = "否",
        
        -- ==================== 按键绑定页面 ====================
        ["script: "] = "脚本：",
        ["[unknown]"] = "[未知]",
        ["Filter bindings:"] = "过滤绑定：",
        ["(hint: scroll with "] = "（提示：使用 ",
        [" and search with "] = " 滚动，使用 ",
        
        -- ==================== 轨道信息页面 ====================
        ["ID:"] = "ID：",
        ["Demuxer ID:"] = "解复用器ID：",
        ["Program ID:"] = "节目ID：",
        ["FFmpeg Index:"] = "FFmpeg索引：",
        ["Flags:"] = "标志：",
        ["Codec:"] = "编解码器：",
        ["Language:"] = "语言：",
        ["Channel Layout:"] = "声道布局：",
        ["HLS Bitrate:"] = "HLS码率：",
        ["Rotation:"] = "旋转：",
        ["Pixel Aspect Ratio:"] = "像素宽高比：",
        ["Replay Gain:"] = "重放增益：",
        ["Track:"] = "音轨：",
        ["Album:"] = "专辑：",
        ["Gain:"] = "增益：",
        ["Peak:"] = "峰值：",
        ["Dolby Vision:"] = "杜比视界：",
        ["Profile:"] = "配置文件：",
        ["Level:"] = "级别：",
        ["default"] = "默认",
        ["forced"] = "强制",
        ["dependent"] = "依赖",
        ["visual-impaired"] = "视觉障碍",
        ["hearing-impaired"] = "听觉障碍",
        ["original"] = "原始",
        ["commentary"] = "解说",
        ["albumart"] = "专辑封面",
        ["external"] = "外部",
        
        -- ==================== 滤镜相关 ====================
        [" (disabled)"] = "（已禁用）",
    }
    
    -- 精确匹配
    local result = translations[text]
    if result then
        return result
    end
    
    -- 模糊匹配（跳过过短的键，防止破坏包含短英文单词的文本）
    for en, zh in pairs(translations) do
        if #en >= 4 and text:find(en, 1, true) then
            text = text:gsub(en, zh, 1)
        end
    end
    
    return text
end

-- ==================== 性能标签翻译 ====================
local perf_translations = {
    ["poll-time"] = "轮询耗时",
    ["demuxer/thread"] = "解封装/线程",
    ["main/iterations"] = "主循环/单次",
    ["main/thread"] = "主循环/线程",
    ["osd/osd-render/cpu"] = "OSD渲染/CPU",
    ["osd/osd-render/time"] = "OSD渲染/总时",
    ["osd/sub-render/cpu"] = "字幕渲染/CPU",
    ["osd/sub-render/time"] = "字幕渲染/总时",
    ["vo/iterations"] = "视频输出/单次",
    ["vo/video-draw/cpu"] = "视频输出/绘制/CPU",
    ["vo/video-draw/time"] = "视频输出/绘制/总时",
    ["vo/video-flip/cpu"] = "视频输出/提交/CPU",
    ["vo/video-flip/time"] = "视频输出/提交/总时",
}

-- 保存原始函数
local original_append_general_perfdata = append_general_perfdata

-- 重写性能数据函数
append_general_perfdata = function(s)
    for i, data in ipairs(mp.get_property_native("perf-info") or {}) do
        local display_name = perf_translations[data.name]
        if not display_name and data.name:match("^script/") then
            display_name = data.name:gsub("^script/", "脚本/")
        elseif not display_name then
            display_name = data.name
        end
        
        append(s, data.text or data.value, {prefix="["..tostring(i).."] "..display_name.."："})

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

-- ==================== 重写核心翻译函数 ====================
-- 保存原始函数
local original_append = append
local original_append_property = append_property
local original_scroll_hint = scroll_hint
local original_cmd_subject = cmd_subject

-- 重写 append
append = function(s, str, attr)
    if str and type(str) == "string" then
        str = auto_translate_text(str)
    end
    if attr then
        if attr.prefix then
            attr.prefix = auto_translate_text(attr.prefix)
        end
        if attr.suffix then
            attr.suffix = auto_translate_text(attr.suffix)
        end
    end
    return original_append(s, str, attr)
end

-- 重写 append_property
append_property = function(s, prop, attr, excluded, cached)
    if attr then
        if attr.prefix then
            attr.prefix = auto_translate_text(attr.prefix)
        end
        if attr.suffix then
            attr.suffix = auto_translate_text(attr.suffix)
        end
    end
    return original_append_property(s, prop, attr, excluded, cached)
end

-- 重写 scroll_hint
scroll_hint = function(search)
    local hint = original_scroll_hint(search)
    return auto_translate_text(hint)
end

-- 重写 cmd_subject
cmd_subject = function(cmd)
    local result = original_cmd_subject(cmd)
    return auto_translate_text(result)
end

-- ==================== 翻译页面描述 ====================
for k, page in pairs(pages) do
    if page.desc then
        page.desc = auto_translate_text(page.desc)
    end
end

-- ============================================================
-- 自动翻译模块结束
-- ============================================================



-- ============================================================
-- 系统 CPU / GPU 占用率获取模块（yosh.wang_20260712）（QQ交流群：1097053691）
-- ============================================================

local cpu_usage = "N/A"
local gpu_usages = {}
local cpu_name = nil
local gpu_names = {}
local hw_detected = false
local stats_refresh_timer = nil
local update_counter = 0
local sys_lang = nil
local nvidia_smi_usage = nil  -- nvidia-smi 最新返回的数值，用于 LUID 归属识别

-- 异步执行系统命令
local function run_async(cmd_args, callback)
    mp.command_native_async({
        name = "subprocess",
        args = cmd_args,
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
    }, function(success, res)
        if callback then
            callback(success, res and (res.stdout or "") or "", res and (res.stderr or "") or "")
        end
    end)
end

-- 强制刷新页面
local function refresh_display()
    if display_timer and display_timer:is_enabled() and curr_page then
        local ass_content = pages[curr_page].f(false)
        if o.persistent_overlay then
            mp.set_osd_ass(0, 0, ass_content)
        else
            mp.osd_message((o.use_ass and ass_start or "") .. ass_content,
                           display_timer.oneshot and o.duration or o.redraw_delay + 1)
        end
    end
end

-- 检测系统语言（缓存结果）
local function detect_sys_lang(callback)
    if sys_lang then
        callback(sys_lang)
        return
    end
    run_async({"typeperf", "-q", "Processor"}, function(success, stdout)
        if success and stdout:match("Processor") then
            sys_lang = "en"
            callback("en")
            return
        end
        run_async({"typeperf", "-q", "处理器"}, function(success2, stdout2)
            if success2 and stdout2:match("处理器") then
                sys_lang = "zh"
                callback("zh")
                return
            end
            sys_lang = "en"
            callback("en")
        end)
    end)
end

-- 判断是否为虚拟 GPU
local function is_virtual_gpu(name)
    if not name then return true end
    local lower = name:lower()
    local virtual_keywords = {
        "virtual", "remote", "hyper-v", "hyperv", "microsoft basic",
        "basic render", "standard vga", "vms3d", "vmware", "virtualbox",
        "parallels", "citrix", "rdp", "wddm", "render only",
        "oray", "orayldd", "sunflower", "向日葵"
    }
    for _, kw in ipairs(virtual_keywords) do
        if lower:find(kw, 1, true) then
            return true
        end
    end
    return false
end

-- 判断是否为集显（iGPU）
local function is_integrated_gpu(name)
    if not name then return false end
    local lower = name:lower()
    -- NVIDIA 始终是独显
    if lower:find("nvidia", 1, true) or lower:find("geforce", 1, true)
       or lower:find("rtx", 1, true) or lower:find("gtx", 1, true) then
        return false
    end
    -- Intel Arc 是独显
    if lower:find("arc", 1, true) then return false end
    -- AMD Radeon RX 系列是独显；Radeon 带 M 后缀或 "Graphics" 是集显
    if lower:find("radeon", 1, true) then
        if lower:find("rx ", 1, true) then return false end
        return true
    end
    -- Intel UHD / Iris / HD Graphics 是集显
    if lower:find("uhd", 1, true) or lower:find("iris", 1, true)
       or lower:find("hd graphics", 1, true) then
        return true
    end
    return false
end

-- 检测 CPU / GPU 硬件型号（只检测一次，缓存结果）
-- 注意：wmic 在 Windows 11 中已被移除，优先使用 PowerShell Get-CimInstance
local function detect_hardware()
    if hw_detected then return end
    hw_detected = true

    local os_name = mp.get_property("platform", "unknown")
    if os_name ~= "windows" then return end

    -- CPU 型号：优先 CIM，备用注册表
    run_async({"powershell", "-NoProfile", "-Command",
               "(Get-CimInstance Win32_Processor).Name"}, function(success, stdout)
        if success then
            local name = stdout:match("^(.-)[\r\n]*$")
            if name and #name > 0 then
                name = name:gsub("^%s+", ""):gsub("%s+$", "")
                cpu_name = name
                refresh_display()
                return
            end
        end
        -- 备用：注册表
        run_async({"reg", "query", "HKLM\\HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0", "/v", "ProcessorNameString"}, function(success2, stdout2)
            if success2 then
                local name2 = stdout2:match("ProcessorNameString%s+REG_SZ%s+(.-)[\r\n]")
                if name2 and #name2 > 0 then
                    name2 = name2:gsub("^%s+", ""):gsub("%s+$", "")
                    cpu_name = name2
                    refresh_display()
                end
            end
        end)
    end)

    -- GPU 型号：优先 CIM（收集所有真实 GPU），备用注册表
    run_async({"powershell", "-NoProfile", "-Command",
               "Get-CimInstance Win32_VideoController | Select-Object -ExpandProperty Name"}, function(success, stdout)
        local found = {}
        if success then
            for name in stdout:gmatch("[^\r\n]+") do
                name = name:gsub("^%s+", ""):gsub("%s+$", "")
                if #name > 0 and not is_virtual_gpu(name) then
                    local dup = false
                    for _, n in ipairs(found) do
                        if n == name then dup = true; break end
                    end
                    if not dup then
                        table.insert(found, name)
                    end
                end
            end
        end
        if #found > 0 then
            gpu_names = found
            -- 排序：集显在前，独显在后
            table.sort(gpu_names, function(a, b)
                local a_int = is_integrated_gpu(a)
                local b_int = is_integrated_gpu(b)
                if a_int ~= b_int then return a_int end
                return false
            end)
            for _, n in ipairs(gpu_names) do
                gpu_usages[n] = "N/A"
            end
            refresh_display()
            return
        end
        -- 备用：注册表（遍历 0000、0001、0002... 检测所有 GPU）
        local reg_base = "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Class\\{4d36e968-e325-11ce-bfc1-08002be10318}"
        local found_reg = {}
        local function probe_reg_gpu(idx)
            local subkey = string.format("%04d", idx)
            run_async({"reg", "query", reg_base .. "\\" .. subkey, "/v", "DriverDesc"}, function(success3, stdout3)
                if success3 then
                    local name3 = stdout3:match("DriverDesc%s+REG_SZ%s+(.-)[\r\n]")
                    if name3 and #name3 > 0 then
                        name3 = name3:gsub("^%s+", ""):gsub("%s+$", "")
                        if #name3 > 0 and not is_virtual_gpu(name3) then
                            local dup = false
                            for _, n in ipairs(found_reg) do
                                if n == name3 then dup = true; break end
                            end
                            if not dup then
                                table.insert(found_reg, name3)
                            end
                        end
                        probe_reg_gpu(idx + 1)
                        return
                    end
                end
                if #found_reg > 0 then
                    gpu_names = found_reg
                    -- 排序：集显在前，独显在后
                    table.sort(gpu_names, function(a, b)
                        local a_int = is_integrated_gpu(a)
                        local b_int = is_integrated_gpu(b)
                        if a_int ~= b_int then return a_int end
                        return false
                    end)
                    for _, n in ipairs(gpu_names) do
                        gpu_usages[n] = "N/A"
                    end
                    refresh_display()
                end
            end)
        end
        probe_reg_gpu(0)
    end)
end

-- ============================================================
-- CPU 占用率获取（Windows）
-- ============================================================

-- 方案1：CIM（兼容 Windows 10+，wmic 在 Win11 中已移除）
local function update_cpu_cim(callback)
    run_async({"powershell", "-NoProfile", "-Command",
               "(Get-CimInstance Win32_Processor).LoadPercentage"}, function(success, stdout)
        if success then
            local load = stdout:match("(%d+)")
            if load and tonumber(load) and tonumber(load) <= 100 then
                callback(load)
                return
            end
        end
        callback(nil)
    end)
end

-- 方案2：typeperf（稳定，支持中英文）
local function update_cpu_typeperf(callback)
    detect_sys_lang(function(lang)
        local counter = lang == "zh"
            and "\\处理器(_Total)\\%% 处理器时间"
            or "\\Processor(_Total)\\%% Processor Time"
        run_async({"typeperf", counter, "-sc", "1"}, function(success, stdout)
            if success then
                local load = stdout:match(",\"(%d+%.?%d*)\"")
                if load and tonumber(load) and tonumber(load) <= 100 then
                    callback(load)
                    return
                end
            end
            -- 再试另一种语言
            local counter2 = lang == "zh"
                and "\\Processor(_Total)\\%% Processor Time"
                or "\\处理器(_Total)\\%% 处理器时间"
            run_async({"typeperf", counter2, "-sc", "1"}, function(success2, stdout2)
                if success2 then
                    local load2 = stdout2:match(",\"(%d+%.?%d*)\"")
                    if load2 and tonumber(load2) and tonumber(load2) <= 100 then
                        callback(load2)
                        return
                    end
                end
                callback(nil)
            end)
        end)
    end)
end

-- 方案3：PowerShell Get-Counter（最后备选）
local function update_cpu_powershell(callback)
    detect_sys_lang(function(lang)
        local counter = lang == "zh"
            and "\\处理器(_Total)\\% 处理器时间"
            or "\\Processor(_Total)\\% Processor Time"
        run_async({"powershell", "-NoProfile", "-Command",
            "Get-Counter '" .. counter .. "' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty CounterSamples | Select-Object -ExpandProperty CookedValue"
        }, function(success, stdout)
            if success then
                local load = stdout:match("(%d+%.?%d*)")
                if load and tonumber(load) and tonumber(load) <= 100 then
                    callback(load)
                    return
                end
            end
            callback(nil)
        end)
    end)
end

-- ============================================================
-- GPU 占用率获取（Windows）
-- ============================================================

-- 方案1：nvidia-smi（只支持 NVIDIA 显卡，最准确）
local function update_gpu_nvidia(callback)
    run_async({"nvidia-smi", "--query-gpu=utilization.gpu", "--format=csv,noheader,nounits"}, function(success, stdout)
        if success then
            local load = stdout:match("(%d+)")
            if load and tonumber(load) and tonumber(load) <= 100 then
                callback(load)
                return
            end
        end
        callback(nil)
    end)
end

-- 方案2：CIM GPU 性能计数器（兼容性最好，与系统语言无关，支持多 GPU 分组）
-- wmic 在 Win11 中已移除，改用 PowerShell Get-CimInstance
local function update_gpu_cim(callback)
    run_async({"powershell", "-NoProfile", "-Command",
               "Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine | ForEach-Object { Write-Output ($_.Name + '|' + $_.UtilizationPercentage) }"},
              function(success, stdout)
        if success then
            -- 返回所有引擎的原始数据（key=完整引擎名，value=利用率）
            local engines = {}
            for line in stdout:gmatch("[^\r\n]+") do
                local name, util = line:match("^(.-)|(%d+)$")
                if name and util then
                    local val = tonumber(util)
                    if val and val >= 0 and val <= 100 then
                        name = name:gsub("^%s+", ""):gsub("%s+$", "")
                        engines[name] = val
                    end
                end
            end
            if next(engines) then
                callback(engines)
                return
            end
        end
        callback(nil)
    end)
end

-- 方案3：typeperf GPU 引擎（支持中英文，支持多 GPU 分组）
-- typeperf CSV 输出：
--   行1（表头）: "\\COMPUTER\GPU Engine(pid_..._engtype_3D)\Utilization Percentage",...
--   行2（数据）: "07/12/2026 15:30:45.123","0.000","15.000",...
--   行3（收尾）: "Exiting..." / "退出代码..."
-- 需要按列位置匹配表头与数据（跳过第1列=时间戳）
local function parse_typeperf_engines(stdout)
    if not stdout then return nil end
    local lines = {}
    for line in stdout:gmatch("[^\r\n]+") do
        lines[#lines + 1] = line
        if #lines >= 2 then break end
    end
    if #lines < 2 then return nil end
    -- 解析表头列（完整计数器路径）
    local headers = {}
    for h in lines[1]:gmatch('"([^"]*)"') do
        headers[#headers + 1] = h
    end
    -- 解析数据列（第1列为时间戳）
    local values = {}
    for v in lines[2]:gmatch('"([^"]*)"') do
        values[#values + 1] = v
    end
    -- 按列位置匹配，跳过第1列（表头标签/数据时间戳）
    local engines = {}
    for i = 2, #headers do
        local path = headers[i]
        local val_str = values[i]
        if path and val_str then
            local val = tonumber(val_str)
            if val and val >= 0 and val <= 100 then
                local engine_name = path:match("GPU[Ee]ngine%(([^)]+)%)")
                if engine_name then
                    engines[engine_name] = val
                end
            end
        end
    end
    return next(engines) and engines or nil
end

local function update_gpu_typeperf(callback)
    detect_sys_lang(function(lang)
        local counter = lang == "zh"
            and "\\GPU 引擎(*)\\利用率百分比"
            or "\\GPU Engine(*)\\Utilization Percentage"
        run_async({"typeperf", counter, "-sc", "1"}, function(success, stdout)
            if success then
                local engines = parse_typeperf_engines(stdout)
                if engines then
                    callback(engines)
                    return
                end
            end
            -- 再试另一种语言
            local counter2 = lang == "zh"
                and "\\GPU Engine(*)\\Utilization Percentage"
                or "\\GPU 引擎(*)\\利用率百分比"
            run_async({"typeperf", counter2, "-sc", "1"}, function(success2, stdout2)
                if success2 then
                    local engines = parse_typeperf_engines(stdout2)
                    if engines then
                        callback(engines)
                        return
                    end
                end
                callback(nil)
            end)
        end)
    end)
end

-- 方案4：PowerShell Get-Counter（最后备选，单值）
local function update_gpu_powershell(callback)
    detect_sys_lang(function(lang)
        local counter = lang == "zh"
            and "\\GPU 引擎(*)\\利用率百分比"
            or "\\GPU Engine(*)\\Utilization Percentage"
        local ps_cmd = "Get-Counter '" .. counter .. "' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty CounterSamples | ForEach-Object { $_.CookedValue } | Sort-Object -Descending | Select-Object -First 1"
        run_async({"powershell", "-NoProfile", "-Command", ps_cmd}, function(success, stdout)
            if success then
                local load = stdout:match("(%d+%.?%d*)")
                if load and tonumber(load) and tonumber(load) <= 100 then
                    callback(load)
                    return
                end
            end
            callback(nil)
        end)
    end)
end

-- ============================================================
-- 统一入口
-- ============================================================

-- 判断是否为 NVIDIA 显卡
local function is_nvidia_gpu(name)
    if not name then return false end
    local lower = name:lower()
    return lower:find("nvidia", 1, true)
        or lower:find("geforce", 1, true)
        or lower:find("rtx", 1, true)
        or lower:find("gtx", 1, true)
end

-- 把分组数据应用到 gpu_usages（跳过 NVIDIA 显卡，N 卡数据以 nvidia-smi 为准）
-- 引擎名格式：pid_X_luid_0xLOW_0xHIGH_phys_Y_eng_Z_engtype_TYPE
-- 引擎名不含显卡名称，而是用 LUID 标识 GPU，因此按 LUID 分组
-- 通过 nvidia-smi 的值匹配找出 NVIDIA 的 LUID 并跳过，其余 LUID 分配给非 N 卡
local function apply_gpu_usage_map(gpu_map, fmt)
    if not gpu_map then return false end
    local updated = false
    -- 按 LUID 分组，收集每个 LUID 的引擎数据
    local luid_data = {}      -- luid -> { max_val=0, val_3d=0, has_3d=false, eng_types={} }
    local luid_order = {}     -- 保持 LUID 出现顺序
    for engine_name, util in pairs(gpu_map) do
        local luid = engine_name:match("luid_(0x%x+_0x%x+)") or "unknown"
        if not luid_data[luid] then
            luid_data[luid] = { max_val = 0, val_3d = 0, has_3d = false, eng_types = {} }
            luid_order[#luid_order + 1] = luid
        end
        local val = tonumber(util)
        if val and val >= 0 and val <= 100 then
            if val > luid_data[luid].max_val then
                luid_data[luid].max_val = val
            end
            -- 记录引擎类型（用于过滤虚拟显卡：虚拟显卡只有 3D 引擎）
            local etype = engine_name:match("engtype_(.+)$")
            if etype then luid_data[luid].eng_types[etype:lower()] = true end
            -- 检查是否是 3D 引擎（engtype_3D）
            if engine_name:lower():find("engtype_3d", 1, true) then
                if not luid_data[luid].has_3d or val > luid_data[luid].val_3d then
                    luid_data[luid].has_3d = true
                    luid_data[luid].val_3d = val
                end
            end
        end
    end
    -- 过滤虚拟显卡 LUID（只有 3D 引擎、没有其他引擎类型的 LUID）
    -- 如 OrayIddDriver 等间接显示驱动只有 engtype_3D 实例
    local filtered_order = {}
    for _, luid in ipairs(luid_order) do
        local types = luid_data[luid].eng_types
        local non_3d = false
        for t, _ in pairs(types) do
            if t ~= "3d" then non_3d = true; break end
        end
        if non_3d or not next(types) then
            filtered_order[#filtered_order + 1] = luid
        end
    end
    luid_order = filtered_order
    if #luid_order == 0 then return false end

    -- 计算每个 LUID 的代表利用率（优先 3D 引擎，否则取最大值）
    local luid_utils = {}
    for i, luid in ipairs(luid_order) do
        local d = luid_data[luid]
        luid_utils[i] = {
            luid = luid,
            util = d.has_3d and d.val_3d or d.max_val,
        }
    end

    -- 通过 nvidia-smi 值识别 NVIDIA 的 LUID（取差值最小的，容差 ±15）
    local nvidia_luid_idx = nil
    -- 参考值：优先使用本轮 nvidia-smi 值，其次使用上一轮残留的 N 卡利用率
    local nv_ref = nvidia_smi_usage
    if not nv_ref then
        for _, gname in ipairs(gpu_names) do
            if is_nvidia_gpu(gname) and gpu_usages[gname] then
                local prev = tonumber(gpu_usages[gname]:match("(%d+)"))
                if prev then
                    nv_ref = prev
                    break
                end
            end
        end
    end
    if nv_ref and #luid_utils > 1 then
        local nv_val = tonumber(nv_ref)
        if nv_val then
            local best_diff = math.huge
            for i, lu in ipairs(luid_utils) do
                local diff = math.abs(lu.util - nv_val)
                if diff < best_diff then
                    best_diff = diff
                    nvidia_luid_idx = i
                end
            end
            if best_diff > 15 then
                nvidia_luid_idx = nil
            end
        end
    end
    -- 单 N 卡系统兜底：只有 1 个 LUID 且有 NVIDIA 显卡时，直接将该 LUID 分配给 N 卡
    if not nvidia_luid_idx and #luid_utils == 1 then
        for _, gname in ipairs(gpu_names) do
            if is_nvidia_gpu(gname) then
                nvidia_luid_idx = 1
                break
            end
        end
    end
    -- 兜底：有 N 卡但没能通过值匹配识别 LUID 时，跳过利用率最高的 LUID
    -- （mpv 硬解通常在 N 卡上，负载高于集显）
    if not nvidia_luid_idx and #luid_utils > 1 then
        local has_nv = false
        for _, gname in ipairs(gpu_names) do
            if is_nvidia_gpu(gname) then has_nv = true; break end
        end
        if has_nv then
            local max_util = -1
            for i, lu in ipairs(luid_utils) do
                if lu.util > max_util then
                    max_util = lu.util
                    nvidia_luid_idx = i
                end
            end
        end
    end

    -- 收集非 NVIDIA 显卡名称（按检测顺序）
    local non_nv_names = {}
    for _, gname in ipairs(gpu_names) do
        if not is_nvidia_gpu(gname) then
            non_nv_names[#non_nv_names + 1] = gname
        end
    end

    -- 将非 NVIDIA 的 LUID 分配给非 N 卡（按顺序）
    local non_nv_idx = 1
    for i, lu in ipairs(luid_utils) do
        if i == nvidia_luid_idx then
            -- 跳过 NVIDIA LUID（已由 nvidia-smi 更新）
        else
            if non_nv_idx <= #non_nv_names then
                local gname = non_nv_names[non_nv_idx]
                gpu_usages[gname] = fmt and string.format(fmt, lu.util)
                                   or (tostring(lu.util) .. "%")
                updated = true
                non_nv_idx = non_nv_idx + 1
            elseif #gpu_names == 0 then
                -- 没检测到型号，记个总的
                gpu_usages["__total__"] = fmt and string.format(fmt, lu.util)
                                        or (tostring(lu.util) .. "%")
                updated = true
            end
        end
    end
    return updated
end

-- 获取 CPU 占用率
local function update_cpu()
    local os_name = mp.get_property("platform", "unknown")

    if os_name == "windows" then
        -- 优先级：CIM → typeperf → powershell
        update_cpu_cim(function(load)
            if load then
                cpu_usage = load .. "%"
                refresh_display()
            else
                update_cpu_typeperf(function(load2)
                    if load2 then
                        cpu_usage = string.format("%.0f%%", tonumber(load2))
                        refresh_display()
                    else
                        update_cpu_powershell(function(load3)
                            if load3 then
                                cpu_usage = string.format("%.0f%%", tonumber(load3))
                            else
                                cpu_usage = "N/A"
                            end
                            refresh_display()
                        end)
                    end
                end)
            end
        end)
    elseif os_name == "linux" then
        run_async({"sh", "-c", "top -bn1 | grep 'Cpu(s)' | awk '{print $2}'"}, function(success, stdout)
            if success then
                local load = stdout:match("(%d+%.?%d*)")
                if load then
                    cpu_usage = load .. "%"
                else
                    cpu_usage = "N/A"
                end
            else
                cpu_usage = "N/A"
            end
            refresh_display()
        end)
    elseif os_name == "darwin" then
        run_async({"ps", "-A", "-o", "%cpu"}, function(success, stdout)
            if success then
                local total = 0
                for line in stdout:gmatch("[^\r\n]+") do
                    local num = line:match("^(%d+%.?%d*)")
                    if num then total = total + tonumber(num) end
                end
                if total > 0 then
                    cpu_usage = string.format("%.1f%%", total)
                else
                    cpu_usage = "N/A"
                end
            else
                cpu_usage = "N/A"
            end
            refresh_display()
        end)
    end
end

-- 获取 GPU 占用率（CIM → typeperf → powershell 完整回退链）
local function update_gpu_full_fallback()
    update_gpu_cim(function(result)
        if result and type(result) == "table" then
            apply_gpu_usage_map(result, "%.0f%%")
            refresh_display()
        else
            update_gpu_typeperf(function(result2)
                if result2 and type(result2) == "table" then
                    apply_gpu_usage_map(result2, "%.0f%%")
                    refresh_display()
                else
                    update_gpu_powershell(function(load4)
                        if load4 then
                            -- 单值兜底：只给还没有有效数据的 GPU 设置值，不覆盖已有数据
                            for _, gname in ipairs(gpu_names) do
                                if not gpu_usages[gname] or gpu_usages[gname] == "N/A" then
                                    gpu_usages[gname] = string.format("%.0f%%", tonumber(load4))
                                end
                            end
                            if #gpu_names == 0 then
                                gpu_usages["__total__"] = string.format("%.0f%%", tonumber(load4))
                            end
                        else
                            -- 失败时也只清空那些本来就是 N/A 的，不覆盖已有数据
                            for _, gname in ipairs(gpu_names) do
                                if not gpu_usages[gname] or gpu_usages[gname] == "N/A" then
                                    gpu_usages[gname] = "N/A"
                                end
                            end
                            if #gpu_names == 0 then
                                gpu_usages["__total__"] = "N/A"
                            end
                        end
                        refresh_display()
                    end)
                end
            end)
        end
    end)
end

-- 获取 GPU 占用率
local function update_gpu()
    local os_name = mp.get_property("platform", "unknown")

    if os_name == "windows" then
        -- 先尝试 nvidia-smi（快，只更新 N 卡），然后继续完整回退链更新所有 GPU
        update_gpu_nvidia(function(load)
            if load then
                -- 记录 nvidia-smi 数值，供 apply_gpu_usage_map 做 LUID 归属识别
                nvidia_smi_usage = tonumber(load) or nil
                -- nvidia-smi 返回单值，找 NVIDIA 显卡分配
                local found_nv = false
                for _, gname in ipairs(gpu_names) do
                    if is_nvidia_gpu(gname) then
                        gpu_usages[gname] = load .. "%"
                        found_nv = true
                    end
                end
                if not found_nv and #gpu_names == 0 then
                    -- 没检测到型号，记个总的
                    gpu_usages["__total__"] = load .. "%"
                end
                refresh_display()
            else
                nvidia_smi_usage = nil
            end
            -- 无论 nvidia-smi 是否成功，都继续完整回退链，确保所有 GPU（含 Intel/AMD 集显）都有数据
            update_gpu_full_fallback()
        end)
    elseif os_name == "linux" then
        run_async({"nvidia-smi", "--query-gpu=utilization.gpu", "--format=csv,noheader,nounits"}, function(success, stdout)
            if success then
                local load = stdout:match("(%d+)")
                if load then
                    gpu_usages["__total__"] = load .. "%"
                    refresh_display()
                    return
                end
            end
            run_async({"sh", "-c", "radeontop --dump - | grep 'gpu' | awk '{print $2}' | head -1"}, function(success2, stdout2)
                if success2 then
                    local load2 = stdout2:match("(%d+%.?%d*)")
                    if load2 then
                        gpu_usages["__total__"] = string.format("%.0f%%", tonumber(load2))
                        refresh_display()
                        return
                    end
                end
                run_async({"sh", "-c", "intel_gpu_top -J | grep 'render' | head -1 | awk '{print $2}'"}, function(success3, stdout3)
                    if success3 then
                        local load3 = stdout3:match("(%d+%.?%d*)")
                        if load3 then
                            gpu_usages["__total__"] = string.format("%.0f%%", tonumber(load3))
                        else
                            gpu_usages["__total__"] = "N/A"
                        end
                    else
                        gpu_usages["__total__"] = "N/A"
                    end
                    refresh_display()
                end)
            end)
        end)
    elseif os_name == "darwin" then
        run_async({"sh", "-c", "ioreg -l | grep PerformanceStatistics | grep GPU | head -1"}, function(success, stdout)
            if success then
                local load = stdout:match("GPU Activity Factor = (%d+)")
                if load then
                    gpu_usages["__total__"] = load .. "%"
                else
                    gpu_usages["__total__"] = "N/A"
                end
            else
                gpu_usages["__total__"] = "N/A"
            end
            refresh_display()
        end)
    end
end

-- 刷新统计数据
local function refresh_stats()
    update_counter = update_counter + 1
    if update_counter % 3 == 0 then
        update_gpu()
    end
    update_cpu()
end

-- 修改 add_file
local original_add_file = add_file
add_file = function(s, print_cache, print_tags)
    original_add_file(s, print_cache, print_tags)

    if not hw_detected then
        detect_hardware()
    end

    if cpu_usage == "N/A" then
        refresh_stats()
    end

    -- 显示 CPU（占用率 + 型号，百分比右对齐到 4 字符以对齐后续标签，兼容 100%）
    local cpu_display = cpu_usage ~= "N/A" and cpu_usage or "--%"
    local cpu_line = "CPU: " .. string.format("%4s", cpu_display)
    if cpu_name then
        cpu_line = cpu_line .. "  CPU:" .. cpu_name
    end
    append(s, cpu_line, {nl=o.nl, prefix="", prefix_sep=""})

    -- 显示 GPU（每个 GPU 一行）
    if #gpu_names > 0 then
        for _, gname in ipairs(gpu_names) do
            local gutil = gpu_usages[gname] or "N/A"
            local gpu_display = gutil ~= "N/A" and gutil or "--%"
            local gpu_line = "GPU: " .. string.format("%4s", gpu_display) .. "  GPU:" .. gname
            append(s, gpu_line, {nl=o.nl, prefix="", prefix_sep=""})
        end
    elseif gpu_usages["__total__"] then
        local gpu_display = gpu_usages["__total__"] ~= "N/A" and gpu_usages["__total__"] or "--%"
        local gpu_line = "GPU: " .. string.format("%4s", gpu_display)
        append(s, gpu_line, {nl=o.nl, prefix="", prefix_sep=""})
    else
        append(s, "GPU: " .. string.format("%4s", "--%"), {nl=o.nl, prefix="", prefix_sep=""})
    end
end

-- 页面激活时启动定时器
local original_process_key_binding = process_key_binding
process_key_binding = function(oneshot)
    original_process_key_binding(oneshot)

    if display_timer and display_timer:is_enabled() then
        if not stats_refresh_timer then
            stats_refresh_timer = mp.add_periodic_timer(1.0, refresh_stats)
            mp.add_timeout(0.1, refresh_stats)
        end
    else
        if stats_refresh_timer then
            stats_refresh_timer:stop()
            stats_refresh_timer = nil
            update_counter = 0
        end
    end
end

-- 退出时清理
local original_remove_page_bindings = remove_page_bindings
remove_page_bindings = function()
    original_remove_page_bindings()
    if stats_refresh_timer then
        stats_refresh_timer:stop()
        stats_refresh_timer = nil
        update_counter = 0
    end
end

-- 文件切换时重置
mp.register_event("file-loaded", function()
    cpu_usage = "N/A"
    for k, _ in pairs(gpu_usages) do
        gpu_usages[k] = "N/A"
    end
    update_counter = 0
end)

-- ============================================================
-- 系统统计模块结束
-- ============================================================






