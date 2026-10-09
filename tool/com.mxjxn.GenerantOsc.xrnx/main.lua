local tool = renoise.tool()
local OscMessage = renoise.Osc.Message
local UDP = renoise.Socket.PROTOCOL_UDP

local prefs = renoise.Document.create("GenerantOscPreferences") {
  host = "127.0.0.1",
  generant_port = 57142,
  blender_port = 57141,
  sync_transport = true,
  sync_sequence = true,
  live_pattern_events = true,
  automation_hz = 60
}
tool.preferences = prefs

local modes = {"trigger", "gate", "unipolar", "bipolar", "integer", "range", "enum", "marker"}
local targets = {"blender", "generant"}
local mappings = {}
local selected_mapping = 1
local clients = {}
local dialog = nil
local attached_song = nil
local attached_patterns = {}
local compiled = nil
local compile_dirty = true
local next_event = 1
local last_seconds = nil

local function trim(value)
  return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

local function round(value)
  return math.floor(value + 0.5)
end

local function escape_field(value)
  return tostring(value or ""):gsub("[%%%c]", function(char) return ("%%%02X"):format(string.byte(char)) end)
end

local function unescape_field(value)
  return (value or ""):gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
end

local function split(value, separator)
  local result = {}
  if value == nil or value == "" then return result end
  for part in (value .. separator):gmatch("(.-)" .. separator) do table.insert(result, trim(part)) end
  return result
end

local function mapping_by_code(code)
  code = tostring(code or ""):upper()
  for _, mapping in ipairs(mappings) do if mapping.code == code then return mapping end end
  return nil
end

local function default_mapping(code)
  return {code = code, target = "blender", address = "/visual/cue", mode = "trigger", min = 0, max = 1, release = 80, fixed = "", enum = ""}
end

local function serialize_mappings()
  local lines = {"GENERANT_OSC_2"}
  for _, mapping in ipairs(mappings) do
    local fields = {mapping.code, mapping.target, mapping.address, mapping.mode, mapping.min, mapping.max, mapping.release, mapping.fixed, mapping.enum}
    for index, value in ipairs(fields) do fields[index] = escape_field(value) end
    table.insert(lines, table.concat(fields, "\t"))
  end
  return table.concat(lines, "\n")
end

local function save_mappings()
  if renoise.song() then renoise.song().tool_data = serialize_mappings() end
  compile_dirty = true
end

local function load_mappings()
  mappings = {}
  local data = renoise.song() and renoise.song().tool_data or ""
  if type(data) ~= "string" or data:sub(1, 14) ~= "GENERANT_OSC_2" then selected_mapping = 1; return end
  for line in data:gmatch("[^\n]+") do
    if line ~= "GENERANT_OSC_2" then
      local fields = {}
      for field in (line .. "\t"):gmatch("(.-)\t") do table.insert(fields, unescape_field(field)) end
      local code = (fields[1] or ""):upper()
      if code:match("^[0-9A-Z][0-9A-Z]$") and code ~= "00" then
        local mapping = default_mapping(code)
        mapping.target = fields[2] == "generant" and "generant" or "blender"
        mapping.address = fields[3] or mapping.address
        mapping.mode = fields[4] or mapping.mode
        mapping.min = tonumber(fields[5]) or 0
        mapping.max = tonumber(fields[6]) or 1
        mapping.release = tonumber(fields[7]) or 80
        mapping.fixed = fields[8] or ""
        mapping.enum = fields[9] or ""
        table.insert(mappings, mapping)
      end
    end
  end
  table.sort(mappings, function(a, b) return a.code < b.code end)
  selected_mapping = clamp(selected_mapping, 1, math.max(1, #mappings))
  compile_dirty = true
end

local function close_clients()
  for _, client in pairs(clients) do pcall(function() client:close() end) end
  clients = {}
end

local function client_for(port)
  if clients[port] then return clients[port] end
  local client, socket_error = renoise.Socket.create_client(prefs.host.value, port, UDP)
  if socket_error then error(socket_error) end
  clients[port] = client
  return client
end

local function osc_arg(value)
  if type(value) == "string" then return {tag = "s", value = value} end
  if type(value) == "number" then
    if value == math.floor(value) and value >= -2147483648 and value <= 2147483647 then return {tag = "i", value = value} end
    return {tag = "f", value = value}
  end
  error("OSC arguments must be numbers or strings")
end

local function send(port, address, values)
  if type(address) ~= "string" or not address:match("^/[%w_/%-%.:]+$") then error("OSC address is invalid") end
  local args = {}
  for _, value in ipairs(values or {}) do table.insert(args, osc_arg(value)) end
  local success, socket_error = client_for(port):send(OscMessage(address, args).binary_data)
  if not success then error(socket_error or "OSC send failed") end
end

local function send_target(target, address, values)
  local port = target == "generant" and prefs.generant_port.value or prefs.blender_port.value
  local ok, err = pcall(send, port, address, values)
  if not ok then renoise.app():show_warning("Generant OSC: " .. tostring(err)) end
end

local function fixed_args(mapping)
  local args = {}
  for _, token in ipairs(split(mapping.fixed, ",")) do
    local number = tonumber(token)
    table.insert(args, number or token)
  end
  return args
end

local function copy_args(values)
  local result = {}
  for _, value in ipairs(values or {}) do table.insert(result, value) end
  return result
end

local function value_for(mapping, byte)
  local normalized = clamp(byte or 0, 0, 255) / 255
  if mapping.mode == "gate" then return byte > 0 and 1 or 0 end
  if mapping.mode == "unipolar" then return normalized end
  if mapping.mode == "bipolar" then return normalized * 2 - 1 end
  if mapping.mode == "integer" then return round(byte) end
  if mapping.mode == "range" then return mapping.min + (mapping.max - mapping.min) * normalized end
  if mapping.mode == "enum" then
    local values = split(mapping.enum, ";")
    return values[byte + 1] or byte
  end
  return mapping.max
end

local function value_for_normalized(mapping, normalized)
  normalized = clamp(normalized, 0, 1)
  if mapping.mode == "gate" then return normalized >= 0.5 and 1 or 0 end
  if mapping.mode == "unipolar" then return normalized end
  if mapping.mode == "bipolar" then return normalized * 2 - 1 end
  if mapping.mode == "integer" then return round(normalized * 255) end
  if mapping.mode == "range" then return mapping.min + (mapping.max - mapping.min) * normalized end
  if mapping.mode == "enum" then return value_for(mapping, round(normalized * 255)) end
  return normalized
end

local function event_args(mapping, value, marker)
  local args = fixed_args(mapping)
  if not marker then table.insert(args, value) end
  return args
end

local function add_event(events, seconds, mapping, args, kind, order)
  table.insert(events, {seconds = seconds, target = mapping.target, address = mapping.address, args = args, kind = kind, order = order or 0})
end

local function add_effect_event(events, seconds, duration, mapping, byte, order)
  if mapping.mode == "marker" then
    add_event(events, seconds, mapping, event_args(mapping, nil, true), "event", order)
  elseif mapping.mode == "trigger" then
    add_event(events, seconds, mapping, event_args(mapping, mapping.max, false), "state", order)
    local release = seconds + math.max(1, mapping.release) / 1000
    if duration > 0 and release >= duration then release = release % duration end
    add_event(events, release, mapping, event_args(mapping, mapping.min, false), "state", order + 0.5)
  else
    local kind = (mapping.mode == "unipolar" or mapping.mode == "bipolar" or mapping.mode == "integer" or mapping.mode == "range") and "curve" or "state"
    add_event(events, seconds, mapping, event_args(mapping, value_for(mapping, byte), false), kind, order)
  end
end

local function automation_code(automation)
  local device = automation.dest_device
  if not device then return nil end
  return tostring(device.display_name or ""):upper():match("^%[OSC%s+([0-9A-Z][0-9A-Z])%]")
end

local function automation_value(automation, time)
  local points = automation.points
  if #points == 0 or time < points[1].time or time > points[#points].time then return nil end
  local previous = points[1]
  for index = 2, #points do
    local following = points[index]
    if time <= following.time then
      if automation.playmode == renoise.PatternTrackAutomation.PLAYMODE_POINTS or following.time == previous.time then return previous.value end
      local ratio = (time - previous.time) / (following.time - previous.time)
      return previous.value + (following.value - previous.value) * ratio
    end
    previous = following
  end
  return previous.value
end

local function compile_song()
  local song = renoise.song()
  local bpm, lpb = song.transport.bpm, song.transport.lpb
  local seconds_per_line = 60 / bpm / lpb
  local duration_lines = 0
  for _, pattern_index in ipairs(song.sequencer.pattern_sequence) do duration_lines = duration_lines + song.patterns[pattern_index].number_of_lines end
  local duration = duration_lines * seconds_per_line
  local events, base_line, order = {}, 0, 0
  for _, pattern_index in ipairs(song.sequencer.pattern_sequence) do
    local pattern = song.patterns[pattern_index]
    for track_index, track in ipairs(song.tracks) do
      if tostring(track.name):match("^%[OSC%]") then
        local pattern_track = pattern.tracks[track_index]
        for line_index = 1, pattern.number_of_lines do
          local line = pattern_track:line(line_index)
          for column_index = 1, track.visible_effect_columns do
            local column = line.effect_columns[column_index]
            if column and not column.is_empty then
              local mapping = mapping_by_code(column.number_string)
              if mapping then
                order = order + 1
                add_effect_event(events, (base_line + line_index - 1) * seconds_per_line, duration, mapping, column.amount_value, order)
              end
            end
          end
        end
        for _, automation in ipairs(pattern_track.automation) do
          local mapping = mapping_by_code(automation_code(automation))
          if mapping and mapping.mode ~= "trigger" and mapping.mode ~= "marker" and #automation.points > 0 then
            local first, last = automation.points[1].time, automation.points[#automation.points].time
            local step = math.max(1 / 256, bpm * lpb / (60 * prefs.automation_hz.value))
            local time = first
            while time < last + step * 0.25 do
              local normalized = automation_value(automation, math.min(time, last))
              if normalized ~= nil then
                order = order + 1
                local kind = (mapping.mode == "unipolar" or mapping.mode == "bipolar" or mapping.mode == "integer" or mapping.mode == "range") and "curve" or "state"
                add_event(events, (base_line + math.min(time, last) - 1) * seconds_per_line, mapping, event_args(mapping, value_for_normalized(mapping, normalized), false), kind, order)
              end
              time = time + step
            end
          end
        end
      end
    end
    base_line = base_line + pattern.number_of_lines
  end
  table.sort(events, function(a, b) return a.seconds == b.seconds and a.order < b.order or a.seconds < b.seconds end)
  compiled = {events = events, duration = duration, bpm = bpm, lpb = lpb}
  compile_dirty = false
  return compiled
end

local function mark_dirty()
  compile_dirty = true
end

local function event_index_at(seconds)
  local events = (compiled or compile_song()).events
  local low, high = 1, #events + 1
  while low < high do
    local middle = math.floor((low + high) / 2)
    if middle <= #events and events[middle].seconds < seconds then low = middle + 1 else high = middle end
  end
  return low
end

local function live_tick()
  local song = renoise.song()
  if not song or not prefs.live_pattern_events.value or not song.transport.playing then last_seconds = nil; return end
  if compile_dirty or not compiled then compile_song() end
  local seconds = song.transport.playback_pos_beats * 60 / song.transport.bpm
  if last_seconds == nil or seconds < last_seconds - 0.02 then next_event = event_index_at(math.max(0, seconds - 0.015)) end
  local horizon = seconds + 0.015
  while next_event <= #compiled.events and compiled.events[next_event].seconds <= horizon do
    local event = compiled.events[next_event]
    if last_seconds == nil or event.seconds >= last_seconds - 0.015 then send_target(event.target, event.address, event.args) end
    next_event = next_event + 1
  end
  last_seconds = seconds
end

local function json_escape(value)
  return '"' .. tostring(value):gsub('[%z\1-\31\\"]', function(char)
    local replacements = {['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t'}
    return replacements[char] or ("\\u%04x"):format(string.byte(char))
  end) .. '"'
end

local function json(value)
  local kind = type(value)
  if kind == "nil" then return "null" end
  if kind == "boolean" then return value and "true" or "false" end
  if kind == "number" then return tostring(value) end
  if kind == "string" then return json_escape(value) end
  if kind ~= "table" then error("Cannot encode JSON value") end
  local count, maximum, array = 0, 0, true
  for key in pairs(value) do
    count = count + 1
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then array = false else maximum = math.max(maximum, key) end
  end
  if array and maximum == count then
    local parts = {}
    for index = 1, maximum do parts[index] = json(value[index]) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local keys = {}
  for key in pairs(value) do table.insert(keys, tostring(key)) end
  table.sort(keys)
  local parts = {}
  for _, key in ipairs(keys) do table.insert(parts, json_escape(key) .. ":" .. json(value[key])) end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function score_data()
  local result = compiled and not compile_dirty and compiled or compile_song()
  local events = {}
  for _, event in ipairs(result.events) do
    if event.target == "blender" and event.seconds >= 0 and event.seconds < result.duration then
      table.insert(events, {seconds = event.seconds, address = event.address, args = event.args, kind = event.kind, trackId = "renoise"})
    end
  end
  return {format = "rack-osc-score", version = 1, name = renoise.song().name, bpm = result.bpm, loopSeconds = result.duration, durationSeconds = result.duration, hz = prefs.automation_hz.value, events = events}
end

local function export_score()
  local path = renoise.app():prompt_for_filename_to_write("json", "Export OSC score")
  if not path or path == "" then return end
  local ok, err = pcall(function()
    local handle = assert(io.open(path, "wb"))
    handle:write(json(score_data()))
    handle:close()
  end)
  if ok then renoise.app():show_status("OSC score exported: " .. path) else renoise.app():show_warning("OSC score export failed: " .. tostring(err)) end
end

local function send_tempo()
  if renoise.song() then send_target("generant", "/generant/v1/transport/tempo", {renoise.song().transport.bpm}) end
end

local function on_playing()
  if not renoise.song() then return end
  if renoise.song().transport.playing then
    compile_song(); next_event = event_index_at(math.max(0, renoise.song().transport.playback_pos_beats * 60 / renoise.song().transport.bpm - 0.015)); last_seconds = nil
    if prefs.sync_transport.value then send_tempo(); send_target("generant", "/generant/v1/transport/play", {}) end
  elseif prefs.sync_transport.value then send_target("generant", "/generant/v1/transport/stop", {}) end
end

local function on_bpm()
  mark_dirty()
  if prefs.sync_transport.value and renoise.song() and not renoise.song().transport.playing then send_tempo() end
end

local function on_lpb() mark_dirty() end

local function on_sequence()
  if prefs.sync_sequence.value and renoise.song() then send_target("generant", "/generant/v1/song/position/queue", {renoise.song().selected_sequence_index - 1}) end
end

local function detach_song()
  if not attached_song then return end
  local transport = attached_song.transport
  if transport.playing_observable:has_notifier(on_playing) then transport.playing_observable:remove_notifier(on_playing) end
  if transport.bpm_observable:has_notifier(on_bpm) then transport.bpm_observable:remove_notifier(on_bpm) end
  if transport.lpb_observable:has_notifier(on_lpb) then transport.lpb_observable:remove_notifier(on_lpb) end
  if attached_song.selected_sequence_index_observable:has_notifier(on_sequence) then attached_song.selected_sequence_index_observable:remove_notifier(on_sequence) end
  if attached_song.sequencer.pattern_sequence_observable:has_notifier(mark_dirty) then attached_song.sequencer.pattern_sequence_observable:remove_notifier(mark_dirty) end
  if attached_song.patterns_observable:has_notifier(mark_dirty) then attached_song.patterns_observable:remove_notifier(mark_dirty) end
  for _, pattern in ipairs(attached_patterns) do if pattern:has_line_notifier(mark_dirty) then pattern:remove_line_notifier(mark_dirty) end end
  attached_patterns = {}
  attached_song = nil
end

local function attach_song()
  detach_song()
  attached_song = renoise.song()
  if not attached_song then return end
  load_mappings()
  attached_song.transport.playing_observable:add_notifier(on_playing)
  attached_song.transport.bpm_observable:add_notifier(on_bpm)
  attached_song.transport.lpb_observable:add_notifier(on_lpb)
  attached_song.selected_sequence_index_observable:add_notifier(on_sequence)
  attached_song.sequencer.pattern_sequence_observable:add_notifier(mark_dirty)
  attached_song.patterns_observable:add_notifier(mark_dirty)
  for _, pattern in ipairs(attached_song.patterns) do pattern:add_line_notifier(mark_dirty); table.insert(attached_patterns, pattern) end
  compiled = nil
end

local function next_code()
  local digits = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  for value = 1, 1295 do
    local code = digits:sub(math.floor(value / 36) + 1, math.floor(value / 36) + 1) .. digits:sub(value % 36 + 1, value % 36 + 1)
    if not mapping_by_code(code) then return code end
  end
  error("All mapping IDs are in use")
end

local function create_osc_track()
  local song = renoise.song()
  song:insert_track_at(song.sequencer_track_count + 1)
  local track = song.tracks[song.sequencer_track_count]
  track.name = "[OSC] Cues"
  track.visible_effect_columns = 4
  song.selected_track_index = song.sequencer_track_count
  mark_dirty()
end

local function mapping_labels()
  local labels = {}
  for _, mapping in ipairs(mappings) do table.insert(labels, mapping.code .. "  " .. mapping.address) end
  if #labels == 0 then labels[1] = "(no mappings)" end
  return labels
end

local function index_of(values, value)
  for index, item in ipairs(values) do if item == value then return index end end
  return 1
end

local show_panel
local function refresh_panel()
  if dialog and dialog.visible then dialog:close() end
  local reopen
  reopen = function() tool:remove_timer(reopen); show_panel() end
  tool:add_timer(reopen, 1)
end

show_panel = function()
  if dialog and dialog.visible then dialog:show(); return end
  local vb = renoise.ViewBuilder()
  local current = mappings[selected_mapping]
  local content = vb:column {
    margin = 10, spacing = 7,
    vb:text {text = "Connections", font = "bold"},
    vb:row {spacing = 6, vb:text {text = "Host", width = 110}, vb:textfield {width = 160, value = prefs.host.value, notifier = function(v) prefs.host.value = trim(v); close_clients() end}},
    vb:row {spacing = 6, vb:text {text = "Generant", width = 110}, vb:valuefield {width = 80, min = 1024, max = 65535, value = prefs.generant_port.value, notifier = function(v) prefs.generant_port.value = v; close_clients() end}, vb:text {text = "Blender"}, vb:valuefield {width = 80, min = 1024, max = 65535, value = prefs.blender_port.value, notifier = function(v) prefs.blender_port.value = v; close_clients() end}},
    vb:row {vb:checkbox {value = prefs.sync_transport.value, notifier = function(v) prefs.sync_transport.value = v end}, vb:text {text = "Renoise transport → Generant"}},
    vb:row {vb:checkbox {value = prefs.sync_sequence.value, notifier = function(v) prefs.sync_sequence.value = v end}, vb:text {text = "Selected sequence → Generant song position"}},
    vb:row {vb:checkbox {value = prefs.live_pattern_events.value, notifier = function(v) prefs.live_pattern_events.value = v end}, vb:text {text = "Send [OSC] tracks during playback"}},
    vb:row {spacing = 6, vb:text {text = "Automation rate", width = 110}, vb:valuefield {width = 80, min = 1, max = 120, value = prefs.automation_hz.value, notifier = function(v) prefs.automation_hz.value = v; mark_dirty() end}, vb:text {text = "Hz"}},
    vb:space {height = 5},
    vb:text {text = "Song mappings", font = "bold"},
    vb:row {spacing = 6, vb:popup {width = 280, items = mapping_labels(), value = clamp(selected_mapping, 1, math.max(1, #mappings)), notifier = function(v) if #mappings > 0 then selected_mapping = v; refresh_panel() end end}, vb:button {text = "+", notifier = function() table.insert(mappings, default_mapping(next_code())); selected_mapping = #mappings; save_mappings(); refresh_panel() end}, vb:button {text = "−", active = current ~= nil, notifier = function() if current then table.remove(mappings, selected_mapping); selected_mapping = clamp(selected_mapping, 1, math.max(1, #mappings)); save_mappings(); refresh_panel() end end}},
  }
  if current then
    local function set(field, value) current[field] = value; save_mappings() end
    content:add_child(vb:row {spacing = 6, vb:text {text = "ID", width = 110}, vb:textfield {width = 60, value = current.code, notifier = function(v)
      local code = trim(v):upper()
      if code:match("^[0-9A-Z][0-9A-Z]$") and code ~= "00" and (not mapping_by_code(code) or code == current.code) then current.code = code; save_mappings() else renoise.app():show_warning("Use an unused ID from 01 to ZZ") end
    end}, vb:text {text = "Write this in the FX command column."}})
    content:add_child(vb:row {spacing = 6, vb:text {text = "Destination", width = 110}, vb:popup {width = 100, items = targets, value = index_of(targets, current.target), notifier = function(v) set("target", targets[v]) end}, vb:textfield {width = 250, value = current.address, notifier = function(v) set("address", trim(v)) end}})
    content:add_child(vb:row {spacing = 6, vb:text {text = "Mode", width = 110}, vb:popup {width = 120, items = modes, value = index_of(modes, current.mode), notifier = function(v) set("mode", modes[v]) end}, vb:text {text = "Min"}, vb:valuefield {width = 70, min = -100000, max = 100000, value = current.min, notifier = function(v) set("min", v) end}, vb:text {text = "Max"}, vb:valuefield {width = 70, min = -100000, max = 100000, value = current.max, notifier = function(v) set("max", v) end}})
    content:add_child(vb:row {spacing = 6, vb:text {text = "Trigger release", width = 110}, vb:valuefield {width = 80, min = 1, max = 5000, value = current.release, notifier = function(v) set("release", v) end}, vb:text {text = "ms"}, vb:button {text = "Test FF", notifier = function()
      send_target(current.target, current.address, current.mode == "marker" and fixed_args(current) or event_args(current, value_for(current, 255), false))
      if current.mode == "trigger" then local release; release = function() tool:remove_timer(release); send_target(current.target, current.address, event_args(current, current.min, false)) end; tool:add_timer(release, current.release) end
    end}})
    content:add_child(vb:row {spacing = 6, vb:text {text = "Fixed arguments", width = 110}, vb:textfield {width = 330, value = current.fixed, notifier = function(v) set("fixed", v) end}})
    content:add_child(vb:row {spacing = 6, vb:text {text = "Enum values", width = 110}, vb:textfield {width = 330, value = current.enum, notifier = function(v) set("enum", v) end}})
  else
    content:add_child(vb:text {text = "Add a mapping, then write its ID and value in an [OSC] track effect column."})
  end
  content:add_child(vb:space {height = 5})
  content:add_child(vb:row {spacing = 6, vb:button {text = "Create [OSC] track", notifier = create_osc_track}, vb:button {text = "Recompile", notifier = function() compile_song(); renoise.app():show_status(("Compiled %d OSC events"):format(#compiled.events)) end}, vb:button {text = "Export Blender score", notifier = export_score}})
  content:add_child(vb:text {text = "Automation: automate a device whose display name is [OSC ID] on an [OSC] track."})
  dialog = renoise.app():show_custom_dialog("Generant OSC", content, function(window, key) if key.name == "esc" then window:close(); return nil end return key end)
end

tool:add_menu_entry {name = "Main Menu:Tools:Generant OSC:Mappings and settings", invoke = show_panel}
tool:add_menu_entry {name = "Main Menu:Tools:Generant OSC:Create OSC track", invoke = create_osc_track}
tool:add_menu_entry {name = "Main Menu:Tools:Generant OSC:Export Blender score", invoke = export_score}
tool:add_keybinding {name = "Global:Tools:Generant OSC Mappings", invoke = show_panel}
tool:add_keybinding {name = "Global:Tools:Export Generant OSC Score", invoke = export_score}
tool.app_new_document_observable:add_notifier(attach_song)
tool.app_release_document_observable:add_notifier(detach_song)
tool.app_will_save_document_observable:add_notifier(save_mappings)
tool.tool_will_unload_observable:add_notifier(function() detach_song(); close_clients(); if tool:has_timer(live_tick) then tool:remove_timer(live_tick) end end)
tool:add_timer(live_tick, 10)
