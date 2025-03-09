-- mpv-Undo-input: 在mpv中撤销或重置快捷键操作（撤销操作）
-- https://github.com/wan0ge/mpv-Undo-input
-- 功能：记录用户的快捷键操作，并提供撤销功能（恢复到上一次操作之前的值）和重置功能（重置到默认值）
-- 忽略视频播放相关的快捷键操作，如快进、倍速、进度跳转等
-- 快捷键：Ctrl+Alt+z 撤销上一次操作
--        Ctrl+Alt+Backspace 重置上一次操作
--  如果快捷键不生效请在input.conf中添加 Ctrl+Alt+z script-message undo_last_action和ctrl+alt+BS script-message reset_last_action

-- 配置选项
local options = {
    max_history_size = 100,  -- 最大历史记录数
    debug_mode = false,      -- 是否启用调试输出
    undo_key = "Ctrl+Alt+z", -- 撤销快捷键
    reset_key = "ctrl+alt+BS", -- 重置快捷键
    use_native_osd = true    -- 是否使用MPV原生OSD显示撤销信息
}

-- 状态变量（使用局部表存储以提高访问速度）
local state = {
    shortcut_history = {},   -- 操作历史记录
    history_index = 0,       -- 当前历史记录索引，用于在撤销和重置间共享
    previous_values = {},    -- 属性变更前的值记录
    default_values = {},     -- 属性的默认值记录
    user_key_bindings = {},  -- 用户自定义快捷键映射
    initialized = false,     -- 是否已初始化
    is_undoing = false       -- 标记是否正在执行撤销操作
}

-- 使用哈希集合存储需要忽略的命令和属性(提高查找效率)
-- 优化：预编译忽略命令前缀的模式匹配
local ignored_commands_lookup = {
    ["seek"] = true, 
    ["revert-seek"] = true, 
    ["frame-step"] = true, 
    ["frame-back-step"] = true, 
    ["ab-loop"] = true, 
    ["speed"] = true, 
    ["playlist-next"] = true, 
    ["playlist-prev"] = true,
    ["chapter"] = true, 
    ["add speed"] = true, 
    ["multiply speed"] = true, 
    ["set speed"] = true,
    ["set fullscreen"] = true, 
    ["cycle fullscreen"] = true, 
    ["toggle fullscreen"] = true
}

-- 优化：一次性编译所有忽略模式
local ignored_patterns = {}
for cmd, _ in pairs(ignored_commands_lookup) do
    ignored_patterns[#ignored_patterns + 1] = "^" .. cmd
end

local ignored_properties_lookup = {
    ["speed"] = true, 
    ["time-pos"] = true, 
    ["percent-pos"] = true, 
    ["playlist-pos"] = true,
    ["chapter"] = true, 
    ["chapter-list"] = true, 
    ["edition"] = true, 
    ["pause"] = true, 
    ["fullscreen"] = true
}

-- 预缓存正则表达式模式，避免重复编译
local command_patterns = {
    {pattern = "^set%s+([%w_-]+)%s+(.*)", type = "set", props = {"property", "value"}},
    {pattern = "^add%s+([%w_-]+)%s+(.*)", type = "add", props = {"property", "value"}},
    {pattern = "^cycle%s+([%w_-]+)", type = "cycle", props = {"property"}},
    {pattern = "^cycle%-values%s+([%w_-]+)%s+(.*)", type = "cycle-values", props = {"property", "values"}},
    {pattern = "^toggle%s+([%w_-]+)", type = "toggle", props = {"property"}},
    {pattern = "^multiply%s+([%w_-]+)%s+(.*)", type = "multiply", props = {"property", "factor"}}
}

-- 视频调整属性集合 - 使用哈希表提高查找速度
local video_adjustments = {
    brightness = true, 
    contrast = true, 
    gamma = true, 
    saturation = true, 
    hue = true
}

-- 属性显示映射表 - 预缓存显示格式 定义替换为动态获取
local property_display = {
    volume = "${volume}",
    mute = "${mute}",
    ontop = "${ontop}",
    ["sub-visibility"] = "字幕可见: ${sub-visibility}",
    ["audio-delay"] = function() 
        local val = mp.get_property_number("audio-delay", 0)
        return string.format("音频延迟: %.0f ms", val * 1000)
    end,
    ["sub-delay"] = function()
        local val = mp.get_property_number("sub-delay", 0)
        return string.format("字幕延迟: %.0f ms", val * 1000)  -- 秒转毫秒
    end
}

-- 常用属性列表 - 预先定义避免重复创建
local common_properties = {
    "volume", "mute", "brightness", "contrast",
    "gamma", "saturation", "hue", "ontop",
    "sub-visibility", "audio-delay", "sub-delay"
}

-- 常见的MPV命令列表（排除播放控制相关命令）
local common_commands = {
    "quit", "pause", "screenshot", "set", "toggle", 
    "cycle", "add", "multiply", "script-message"
}

-- 优化：使用局部函数缓存，减少表查找开销
local mp_msg_info = mp.msg.info
local mp_get_property_native = mp.get_property_native
local mp_set_property_native = mp.set_property_native
local mp_commandv = mp.commandv
local mp_osd_message = mp.osd_message
local mp_add_timeout = mp.add_timeout
local mp_add_forced_key_binding = mp.add_forced_key_binding
local mp_find_config_file = mp.find_config_file
local mp_command = mp.command
local mp_observe_property = mp.observe_property
local mp_register_script_message = mp.register_script_message
local mp_add_key_binding = mp.add_key_binding
local mp_register_event = mp.register_event
local string_format = string.format
local string_match = string.match
local string_find = string.find
local string_sub = string.sub
local string_lower = string.lower
local table_insert = table.insert
local table_remove = table.remove
local os_time = os.time
local math_floor = math.floor
local tostring_native = tostring
local io_open = io.open
local pcall_native = pcall

-- 用于调试输出的函数
local function debug_print(message)
    if options.debug_mode then
        mp_msg_info(message)
    end
end

-- 检查命令是否应被忽略（播放控制相关）- 使用预编译的模式匹配
local function should_ignore_command(command)
    if not command then return false end
    
    local cmd_lower = string_lower(command)
    
    -- 优化：直接查找匹配而不是循环模式
    if ignored_commands_lookup[cmd_lower] then
        return true
    end
    
    -- 使用预编译的模式进行匹配
    for i = 1, #ignored_patterns do
        if cmd_lower:find(ignored_patterns[i], 1, true) then
            return true
        end
    end
    
    return false
end

-- 检查属性是否应被忽略（播放控制相关）- 直接使用O(1)哈希表查找
local function should_ignore_property(property)
    if not property then return false end
    return ignored_properties_lookup[string_lower(property)] ~= nil
end

-- 检查快捷键是否为特殊键（撤销键或重置键）
local function is_special_key(key)
    if not key then return false end
    local key_lower = string_lower(key)
    return key_lower == string_lower(options.undo_key) or key_lower == string_lower(options.reset_key)
end

-- 检查两个历史记录项是否操作相同属性
local function are_actions_on_same_property(action1, action2)
    if not action1 or not action2 then
        return false
    end
    
    -- 直接获取属性名
    local prop1 = action1.cmd_info and action1.cmd_info.property or action1.property
    local prop2 = action2.cmd_info and action2.cmd_info.property or action2.property
    
    -- 检查是否操作相同属性
    return prop1 and prop2 and prop1 == prop2
end

-- 检查两个历史记录项是否由相同的快捷键触发
local function are_actions_from_same_key(action1, action2)
    return action1 and action2 and action1.key and action2.key and action1.key == action2.key
end

-- 解析命令并提取属性和值(使用预编译模式)
local function parse_command(command)
    if not command then 
        return {type = "unknown"}
    end
    
    for _, pattern_info in ipairs(command_patterns) do
        local matches = {string_match(command, pattern_info.pattern)}
        if matches[1] then
            local result = {type = pattern_info.type}
            for i, prop_name in ipairs(pattern_info.props) do
                result[prop_name] = matches[i]
            end
            return result
        end
    end
    
    -- 对于其他复杂命令，返回原始命令
    return {type = "other", original = command}
end

-- 安全地转换值为字符串
local function safe_tostring(value)
    if value == nil then
        return "nil"
    end
    
    local success, result = pcall_native(tostring_native, value)
    if success then
        return result
    else
        return "无法转换为字符串"
    end
end

-- 保存属性的当前值(操作前的值)
local function save_previous_value(property)
    -- 快速路径：跳过播放控制相关属性
    if not property or should_ignore_property(property) then
        return nil
    end
    
    local success, value = pcall_native(mp_get_property_native, property)
    if success and value ~= nil then
        debug_print("保存属性操作前的值: " .. property .. " = " .. safe_tostring(value))
        
        -- 如果是第一次操作此属性，同时保存默认值
        if state.default_values[property] == nil then
            state.default_values[property] = value
            debug_print("保存属性默认值: " .. property .. " = " .. safe_tostring(value))
        end
        
        return value
    end
    
    return nil
end

-- 读取用户的input.conf文件，解析快捷键（优化版）
local function load_user_key_bindings()
    local bindings = {}
    
    local input_conf_path = mp_find_config_file("input.conf")
    if not input_conf_path then
        debug_print("未找到用户快捷键配置文件")
        return bindings
    end
    
    debug_print("加载用户快捷键配置: " .. input_conf_path)
    local file, open_err = io_open(input_conf_path, "r")
    if not file then
        debug_print("无法打开配置文件: " .. (open_err or "未知错误"))
        return bindings
    end
    
    -- 优化：一次性读取整个文件内容并按行分割
    local content = file:read("*all")
    file:close()
    
    -- 使用模式匹配一次性提取所有快捷键绑定
    for line in content:gmatch("[^\r\n]+") do
        -- 快速检查行是否为空或注释
        local first_char = line:match("^%s*(.)")
        if first_char and first_char ~= "#" then
            -- 解析键位和命令
            local key, command = line:match("^%s*([^%s]+)%s+(.+)")
            if key and command then
                -- 去除尾部注释
                local comment_pos = command:find("#")
                if comment_pos then
                    command = command:sub(1, comment_pos-1):match("^%s*(.-)%s*$")
                end
                
                -- 跳过播放控制相关命令
                if not should_ignore_command(command) and #command > 0 then
                    bindings[key] = command
                end
            end
        end
    end
    
    return bindings
end

-- 显示属性信息到OSD（优化后的版本）
local function show_property_osd(property, action_type, current_value, previous_value)
    if not options.use_native_osd or not property then
        return false
    end
    
    if should_ignore_property(property) then
        return true
    end
    
    -- 如果当前值和前一个值相同，不显示提示
    if current_value == previous_value then
        debug_print("值未发生变化，跳过显示: " .. property)
        return true
    end
    
    -- 获取当前值(如果未传入)
    local display_current = current_value or (function()
        local success, val = pcall_native(mp_get_property_native, property)
        if success then return val else return nil end
    end)()
    
    if display_current == nil then
        debug_print("获取属性值失败: " .. property)
        return false
    end
    
    -- 构造提示前缀
    local prefix = action_type == "undo" and "已撤销 " or "已重置 "
    
    -- 针对不同类型的属性使用不同的显示格式
    local property_zh_names = {
        brightness = "亮度",
        contrast = "对比度",
        gamma = "伽马",
        saturation = "饱和度",
        hue = "色调",
        volume = "音量",
        mute = function(val) return (val and "开启" or "关闭") end,
        ["sub-visibility"] = function(val) return (val and "是" or "否") end,
        ontop = function(val) return (val and "开启" or "关闭") end,
        ["audio-delay"] = function(val) 
            -- 确保使用正确的数值计算
            return string_format("%d ms", math_floor(val * 1000 + 0.5)) -- 添加0.5进行四舍五入
        end,
        ["sub-delay"] = function(val) 
            -- 确保使用正确的数值计算
            return string_format("%d ms", math_floor(val * 1000 + 0.5)) -- 添加0.5进行四舍五入
        end
    }
    
    local handler = property_zh_names[property]
    local display_text = prefix
    
    -- 构造显示文本,包含变化过程
    if type(handler) == "function" then
        local prop_name = ""
        -- 为特定属性添加前缀说明
        if property == "mute" then
            prop_name = "静音: "
        elseif property == "sub-visibility" then
            prop_name = "字幕可见: "
        elseif property == "ontop" then
            prop_name = "窗口置顶: "
        elseif property == "audio-delay" then
            prop_name = "音频延迟: "
        elseif property == "sub-delay" then
            prop_name = "字幕延迟: "
        end
        
        if previous_value ~= nil then
            display_text = display_text .. prop_name .. handler(previous_value) .. " → " .. handler(display_current)
        else
            display_text = display_text .. prop_name .. handler(display_current)
        end
    else
        local prop_name = type(handler) == "string" and handler or property
        if previous_value ~= nil then
            display_text = display_text .. prop_name .. ": " .. 
                         safe_tostring(previous_value) .. " → " .. 
                         safe_tostring(display_current)
        else
            display_text = display_text .. prop_name .. ": " .. safe_tostring(display_current)
        end
    end
    
    -- 显示到OSD
    mp_commandv("show-text", display_text)
    return true
end

-- 定义状态更新函数
local function update_history_index()
    state.history_index = #state.shortcut_history
    debug_print("历史索引已更新为: " .. state.history_index)
end

-- 添加一个历史记录项
local function add_history_item(item)
    -- 如果正在撤销，不记录此次操作
    if state.is_undoing then
        debug_print("正在撤销操作，跳过记录历史")
        return
    end
    
    -- 如果是要忽略的属性，则不添加到历史记录
    if item.property and should_ignore_property(item.property) then
        return
    end
    
    -- 使用滑动窗口管理历史记录大小
    if #state.shortcut_history >= options.max_history_size then
        table_remove(state.shortcut_history, 1)
    end
    
    -- 添加新记录
    table_insert(state.shortcut_history, item)
    
    -- 更新历史索引指向最新的记录
    update_history_index()
end

-- 获取当前历史记录中的操作项
local function get_current_history_item()
    if #state.shortcut_history == 0 or state.history_index <= 0 or state.history_index > #state.shortcut_history then
        debug_print("没有可用的历史记录项")
        return nil
    end
    
    return state.shortcut_history[state.history_index]
end

-- 查找下一个不同属性或不同快捷键的历史记录项索引
local function find_next_different_action_index(current_index)
    if current_index <= 0 or current_index > #state.shortcut_history then
        return 0
    end
    
    local current_action = state.shortcut_history[current_index]
    if not current_action then
        return 0
    end
    
    -- 从当前索引向前搜索，找到第一个不同属性或不同快捷键的操作
    for i = current_index - 1, 1, -1 do
        local action = state.shortcut_history[i]
        if not are_actions_on_same_property(current_action, action) or 
           not are_actions_from_same_key(current_action, action) then
            return i
        end
    end
    
    return 0
end

-- 定义设置撤销标志的函数
local function set_undoing_flag(value)
    state.is_undoing = value
    if value then
        -- 延迟重置撤销标志，确保属性变更完成后才能再次记录操作
        mp_add_timeout(0.01, function()
            state.is_undoing = false
        end)
    end
end

-- 撤销上一次操作（修改版 - 撤销后删除历史记录）
local function undo_last_action()
    if #state.shortcut_history == 0 then
        mp_osd_message("没有可撤销的操作")
        return
    end
    
    -- 检查历史索引是否有效
    if state.history_index <= 0 then
        -- 重置索引到最新操作
        update_history_index()
        debug_print("重置历史索引到最新: " .. state.history_index)
    end
    
    -- 递归函数用于处理连续撤销
    local function try_undo()
        -- 获取当前操作项
        local current_action = get_current_history_item()
        if not current_action then
            mp_osd_message("无法撤销操作")
            return false
        end
        
        -- 设置撤销标志，防止撤销操作被记录
        set_undoing_flag(true)
        
        -- 简化属性名获取逻辑
        local property_name = current_action.cmd_info and current_action.cmd_info.property or current_action.property
        
        -- 如果找到属性名并有先前值，则尝试恢复
        if property_name and current_action.previous_value ~= nil then
            local current_value = mp_get_property_native(property_name)
            
            -- 检查值是否相同
            if current_value == current_action.previous_value then
                debug_print("跳过相同值的撤销操作: " .. property_name)
                -- 从历史记录中删除这条记录
                table_remove(state.shortcut_history, state.history_index)
                if state.history_index > #state.shortcut_history then
                    state.history_index = #state.shortcut_history
                end
                
                -- 递归尝试撤销下一个操作
                if #state.shortcut_history > 0 then
                    return try_undo()
                end
                return false
            end
            
            local success, err = pcall_native(mp_set_property_native, property_name, current_action.previous_value)
            if success then
                -- 尝试使用原生OSD显示
                if not show_property_osd(property_name, "undo", current_action.previous_value, current_value) then
                    mp_osd_message(string_format("已撤销: %s: %s → %s", 
                        property_name,
                        safe_tostring(current_value),
                        safe_tostring(current_action.previous_value)))
                end
                
                -- 从历史记录中删除当前操作
                table_remove(state.shortcut_history, state.history_index)
                debug_print("已从历史记录中删除撤销的操作，剩余历史记录数: " .. #state.shortcut_history)
                
                -- 更新历史索引，指向下一个可撤销的操作
                if state.history_index > #state.shortcut_history then
                    state.history_index = #state.shortcut_history
                end
                
                debug_print("撤销成功，历史索引更新为: " .. state.history_index)
                return true
            else
                debug_print("设置属性失败: " .. (err or "未知错误"))
                mp_osd_message("撤销失败: " .. property_name)
                return false
            end
        else
            debug_print("无法撤销操作，没有保存操作前的值")
            mp_osd_message("无法撤销此操作")
            
            -- 无法撤销的操作也从历史记录中移除
            table_remove(state.shortcut_history, state.history_index)
            debug_print("已从历史记录中删除无法撤销的操作，剩余历史记录数: " .. #state.shortcut_history)
            
            -- 更新历史索引
            if state.history_index > #state.shortcut_history then
                state.history_index = #state.shortcut_history
            end
            
            -- 递归尝试撤销下一个操作
            if #state.shortcut_history > 0 then
                return try_undo()
            end
            return false
        end
    end
    
    -- 开始尝试撤销
    try_undo()
end

-- 重置当前操作为默认值（修改版 - 重置后删除相关历史记录）
local function reset_last_action()
    if #state.shortcut_history == 0 then
        mp_osd_message("没有可重置的操作")
        return
    end
    
    -- 检查历史索引是否有效
    if state.history_index <= 0 then
        -- 重置索引到最新操作
        update_history_index()
        debug_print("重置历史索引到最新: " .. state.history_index)
    end
    
    -- 获取当前操作项
    local current_action = get_current_history_item()
    if not current_action then
        mp_osd_message("无法重置操作")
        return
    end
    
    -- 设置撤销标志，防止重置操作被记录
    set_undoing_flag(true)
    
    -- 简化属性名获取逻辑
    local property_name = current_action.cmd_info and current_action.cmd_info.property or current_action.property
    
    -- 如果找到了属性名，尝试重置该属性
    if property_name and state.default_values[property_name] ~= nil then
        local current_value = mp_get_property_native(property_name)
        local success, err = pcall_native(mp_set_property_native, property_name, state.default_values[property_name])
        if success then
            -- 使用改进后的 show_property_osd,传入当前值和默认值
            if not show_property_osd(property_name, "reset", state.default_values[property_name], current_value) then
                mp_osd_message(string_format("已重置: %s: %s → %s", 
                    property_name,
                    safe_tostring(current_value),
                    safe_tostring(state.default_values[property_name])))
            end
            
            -- 保存当前操作的属性名和快捷键
            local current_prop = property_name
            local current_key = current_action.key
            
            -- 收集要删除的历史记录索引（相同属性或相同快捷键的操作）
            local indices_to_remove = {}
            for i = #state.shortcut_history, 1, -1 do
                local action = state.shortcut_history[i]
                local action_prop = action.cmd_info and action.cmd_info.property or action.property
                
                -- 检查是否操作相同属性或使用相同快捷键
                if action_prop == current_prop or (current_key and action.key == current_key) then
                    table_insert(indices_to_remove, i)
                    debug_print("标记删除历史索引 " .. i .. ": " .. (action_prop or "未知属性"))
                end
            end
            
            -- 从后向前删除标记的历史记录，避免索引变化问题
            for i = 1, #indices_to_remove do
                table_remove(state.shortcut_history, indices_to_remove[i])
                debug_print("删除历史索引 " .. indices_to_remove[i])
            end
            
            debug_print("已从历史记录中删除重置的操作及相关操作，剩余历史记录数: " .. #state.shortcut_history)
            
            -- 更新历史索引
            update_history_index()
            debug_print("重置成功，历史索引更新为: " .. state.history_index)
        else
            debug_print("设置属性失败: " .. (err or "未知错误"))
            mp_osd_message("重置失败: " .. property_name)
        end
    else
        debug_print("无法重置操作，没有保存默认值")
        mp_osd_message("无法重置此操作")
        
        -- 无法重置的操作也从历史记录中移除
        table_remove(state.shortcut_history, state.history_index)
        debug_print("已从历史记录中删除无法重置的操作，剩余历史记录数: " .. #state.shortcut_history)
        
        -- 更新历史索引
        if state.history_index > #state.shortcut_history then
            state.history_index = #state.shortcut_history
        end
    end
end

-- 监听常用属性变化（优化版）
local function monitor_properties()
    for i = 1, #common_properties do
        local prop = common_properties[i]
        
        if should_ignore_property(prop) then
            goto continue
        end
        
        -- 获取并保存默认值
        local success, init_value = pcall_native(mp_get_property_native, prop)
        if success and init_value ~= nil then
            state.default_values[prop] = init_value
            debug_print("保存属性默认值: " .. prop .. " = " .. safe_tostring(init_value))
        end
        
        -- 创建闭包保存当前属性名和上一次的值
        local last_value = init_value
        local property_name = prop
        
        mp_observe_property(prop, "native", function(_, value)
            -- 如果正在撤销操作，跳过记录
            if state.is_undoing then
                debug_print("正在撤销操作，跳过记录属性变更: " .. property_name)
                return
            end
            
            -- 记录每一次有效的值变化
            if value ~= nil and value ~= last_value then
                debug_print("记录属性变更: " .. property_name .. 
                          " 从 " .. safe_tostring(last_value) .. 
                          " 到 " .. safe_tostring(value))
                
                -- 记录这次变化
                add_history_item({
                    property = property_name,
                    value = value,
                    timestamp = os_time(),
                    previous_value = last_value
                })
                
                -- 更新last_value为当前值
                last_value = value
            end
        end)
        
        ::continue::
    end
end	

-- 监听所有用户定义的快捷键（使用函数闭包优化）
local function setup_user_key_bindings()
    -- 清除旧的绑定
    for key, _ in pairs(state.user_key_bindings) do
        if key then
            local binding_name = "user_key_" .. key:gsub("%W", "_")
            mp.remove_key_binding(binding_name)
        end
    end
    
    -- 为每个快捷键创建处理函数
    for key, command in pairs(state.user_key_bindings) do
        -- 跳过特殊键和播放控制相关命令
        if key and command and not is_special_key(key) and not should_ignore_command(command) then
            local binding_name = "user_key_" .. key:gsub("%W", "_")
            
            -- 预先解析命令以避免重复解析
            local cmd_info = parse_command(command)
            
            -- 跳过播放控制相关属性
            if cmd_info.property and should_ignore_property(cmd_info.property) then
                debug_print("忽略播放控制属性操作: " .. command)
                goto continue
            end
            
            -- 创建闭包保存当前的key和command
            local current_key = key
            local current_command = command
            local current_cmd_info = cmd_info
            
            -- 添加新的监听（使用闭包捕获变量避免重复解析）
            mp_add_forced_key_binding(key, binding_name, function()
                debug_print("执行用户快捷键: " .. current_key .. " => " .. current_key .. " => " .. current_command)
                
                -- 保存操作前的值
                local prev_value = nil
                
                -- 如果是属性操作，尝试保存操作前的值
                if current_cmd_info.type ~= "other" and current_cmd_info.property then
                    prev_value = save_previous_value(current_cmd_info.property)
                end
                
                -- 记录到历史
                add_history_item({
                    key = current_key,
                    command = current_command,
                    cmd_info = current_cmd_info,
                    timestamp = os.time(),
                    previous_value = prev_value
                })
                
                -- 执行原始命令
                pcall(mp.command, current_command)
            end, {repeatable = true})
            
            ::continue::
        end
    end
end

-- 获取MPV的内置键绑定（使用表缓存）
local function get_default_key_bindings()
    local bindings = {}
    
    -- 使用pcall避免获取属性失败时崩溃
    local success, built_in = pcall(mp.get_property_native, "input-bindings", {})
    if not success or not built_in then
        debug_print("获取内置快捷键失败")
        return bindings
    end
    
    for i = 1, #built_in do
        local binding = built_in[i]
        if binding and binding.key and binding.cmd and not should_ignore_command(binding.cmd) then
            bindings[binding.key] = binding.cmd
        end
    end
    
    return bindings
end

-- 处理未在input.conf中定义但在MPV中存在的常用快捷键（使用闭包优化）
local function setup_common_commands()
    -- 为每个命令创建一个处理器
    for i = 1, #common_commands do
        local cmd = common_commands[i]
        
        -- 跳过播放控制相关命令
        if should_ignore_command(cmd) then
            goto continue
        end
        
        -- 捕获循环变量
        local command_name = cmd
        
        -- 保存原始命令处理函数
        local original_command = mp.get_script_name() .. "_original_" .. command_name
        
        -- 创建原始命令调用函数
        mp.register_script_message(original_command, function(...)
            pcall(mp.commandv, command_name, ...)
        end)
        
        -- 重新定义该命令的处理行为
        local cmd_handler = function(...)
            local args = {...}
            local cmd_str = command_name
            
            -- 构建完整命令字符串
            for j = 1, #args do
                cmd_str = cmd_str .. " " .. safe_tostring(args[j])
            end
            
            -- 检查是否为播放控制相关命令
            if should_ignore_command(cmd_str) then
                -- 直接调用原始命令，不记录
                pcall(mp.commandv, "script-message", original_command, ...)
                return
            end
            
            -- 尝试解析命令和保存操作前的值
            local cmd_info = parse_command(cmd_str)
            local prev_value = nil
            
            if cmd_info.property and not should_ignore_property(cmd_info.property) then
                prev_value = save_previous_value(cmd_info.property)
            end
            
            -- 记录到历史
            debug_print("捕获命令: " .. cmd_str)
            add_history_item({
                command = cmd_str,
                cmd_info = cmd_info,
                timestamp = os.time(),
                previous_value = prev_value
            })
            
            -- 调用原始命令
            pcall(mp.commandv, "script-message", original_command, ...)
        end
        
        -- 尝试劫持命令
        if mp[command_name] then
            mp[command_name] = cmd_handler
        end
        
        ::continue::
    end
end

-- 重置新文件加载时的所有默认值
local function reset_default_values()
    state.default_values = {}
    
    -- 重新获取常用属性的默认值（排除播放控制相关属性）
    for i = 1, #common_properties do
        local prop = common_properties[i]
        if not should_ignore_property(prop) then
            local success, value = pcall(mp.get_property_native, prop)
            if success and value ~= nil then
                state.default_values[prop] = value
                debug_print("更新属性默认值: " .. prop .. " = " .. safe_tostring(value))
            end
        end
    end
end

-- 修改初始化函数
local function init()
    -- 防止重复初始化
    if state.initialized then
        return
    end
    state.initialized = true
    
    -- 每次启动时强制清空历史记录
    state.shortcut_history = {}
    state.history_index = 0
    
    -- 先加载用户定义的快捷键
    state.user_key_bindings = load_user_key_bindings()
    
    -- 检查用户 input.conf 是否定义了撤销和重置快捷键
    local undo_key, reset_key
    for key, cmd in pairs(state.user_key_bindings) do
        if cmd:match("^script%-message%s+undo_last_action$") then
            undo_key = key
            options.undo_key = key  -- 覆盖默认快捷键
        elseif cmd:match("^script%-message%s+reset_last_action$") then
            reset_key = key
            options.reset_key = key  -- 覆盖默认快捷键
        end
    end
    
    -- 如果用户没有定义很多快捷键，也加载默认快捷键
    if not next(state.user_key_bindings) or #state.user_key_bindings < 10 then
        local default_bindings = get_default_key_bindings()
        -- 合并默认绑定和用户绑定（用户绑定优先）
        for key, cmd in pairs(default_bindings) do
            if key and not state.user_key_bindings[key] and not should_ignore_command(cmd) then
                state.user_key_bindings[key] = cmd
            end
        end
    end
    
    -- 设置监听所有快捷键
    setup_user_key_bindings()
    
    -- 监听通用命令
    setup_common_commands()
    
    -- 监听属性变化
    monitor_properties()
    
    -- 注册撤销和重置功能的快捷键（优先使用 input.conf 中定义的）
    if undo_key then
        mp.add_key_binding(undo_key, "undo_last_action", undo_last_action)
    else
        mp.add_key_binding(options.undo_key, "undo_last_action", undo_last_action)
    end
    
    if reset_key then
        mp.add_key_binding(reset_key, "reset_last_action", reset_last_action)
    else
        mp.add_key_binding(options.reset_key, "reset_last_action", reset_last_action)
    end
    
    -- 使用脚本消息方式提供撤销和重置功能(用于其他脚本调用)
    mp.register_script_message("undo_last_action", undo_last_action)
    mp.register_script_message("reset_last_action", reset_last_action)
    
    -- 只在首次加载时显示简短的OSD消息
    local undo_display_key = undo_key or options.undo_key
    local reset_display_key = reset_key or options.reset_key
    mp.osd_message("快捷键撤销插件已加载\n" .. undo_display_key .. " 撤销 | " .. reset_display_key .. " 重置", 3)
end


-- 处理mpv文件加载事件，确保在文件加载后重新设置绑定
mp.register_event("file-loaded", function()
    debug_print("文件已加载，重新设置快捷键监听")
    setup_user_key_bindings()
    -- 清空历史记录
    state.shortcut_history = {}
    -- 重置历史索引
    state.history_index = 0
    -- 重置默认值
    reset_default_values()
end)

-- 启动插件
init()
