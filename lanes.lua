-- lanes v0.0.7 @sonocircuit
-- llllllll.co/t/url
--
--
--        multi track midi
--           player &
--           recorder
--
--
-- E1: select lane
-- E2/E3: change parameter
-- K2/K3: navigate pages
-- hold K1: display options/shift
-- K1 + K2/K3: select options
--

local fs = require 'fileselect'
local ms = require 'core/mods'
local rf = include 'lib/lanes_reflection'
local md = include 'lib/lanes_midi'
local nb = include 'lib/nb/lib/nb'

local m = midi.connect()
local g = grid.connect()


------------------------------
-- TODO: oneset rec mode when track not playing
-- TODO: revise grid logic and ui
-- TOOD: add screen msg (undo, clear)?
-- TODO: code review
-- TODO: docs and testing
------------------------------

--------- variables ----------
local load_pset = false

local NUM_LANES = 7
local NUM_PAGES = 6
local NUM_SNAP = 8
local STEP_RES = 96 -- reflection defaults at 96ppqn

local default_path = _path.code .."lanes/midi_files/"

-- UI
local ui = {}
ui.page = 1
ui.k1 = false
ui.quant_key = false
ui.reset_key = false
ui.stop_key = false
ui.rec_key = false
ui.loop_key = false
ui.all_key = false
ui.dirtyscreen = false
ui.dirtygrid = false

-- focus
local focus = {}
focus.rec = 0
focus.lane = 1

-- quantization
local qnt = {}
qnt.bar = 4
qnt.launch = 1
qnt.loop = 1
qnt.cut = 1
qnt.key = 1
qnt.snap = 1
qnt.event = {}

-- snapshots
local snap = {}
for slot = 1, NUM_SNAP do
  snap[slot] = {}
  snap[slot].has_data = false
  for lane = 1, NUM_LANES do
    snap[slot][lane] = {}
    snap[slot][lane].playing = false
    snap[slot][lane].looping = false
    snap[slot][lane].min = 1
    snap[slot][lane].max = 16
  end
end
 
-- key viz
local viz = {}
viz.bar = false
viz.beat = false
viz.key_fast = 8
viz.key_mid = 4
viz.key_slow = 4

local p = {} -- temp storage for pattern data
p.count = 0
p.step = 0
p.event = {}
p.endpoint = 0

-- midi io
local m = {} 
m.tick_res = 0
m.glb_in = true
m.glb_ch = 1
m.devices = {}
m.out = {}
for i = 1, NUM_LANES do
  m.out[i] = midi.connect()
end

-- held grid keys and midi keys
local held = {}
for i = 1, NUM_LANES do
  held[i] = {}
  held[i].num = 0
  held[i].max = 0
  held[i].first = 0
  held[i].second = 0
  held[i].notes = {}
end

-- note off flag. if true then note off msg has been recorded
local off_flag = {}
for i = 1, NUM_LANES do
  off_flag[i] = {}
  for note = 0, 127 do
    off_flag[i][note] = false
  end
end

-- options
local options = {}
options.q_names = {"none", "1/64", "1/48", "3/128", "1/32", "1/24", "3/64", "1/16", "1/12", "3/32", "1/8", "1/6", "3/16", "1/4"}
options.q_values = {1/96, 1/64, 1/48, 3/128, 1/32, 1/24, 3/64, 1/16, 1/12, 3/32, 1/8, 1/6, 3/16, 1/4}
options.meter_names = {"2/4", "3/4", "4/4", "5/4", "6/4", "7/4", "9/4"}
options.meter_values = {2/4, 3/4, 4/4, 5/4, 6/4, 7/4, 9/4}

--------- pattern playback ----------
function lane_runner(e, i)
  if e.msg == "note_on" then
    play_notes(e, i)
    table.insert(lane[i].active_notes, e.note)
  elseif e.msg == "note_off" then
    -- if the corresponding note is not held then stop the note.
    if not tab.contains(held[e.i].notes, e.note) then
      stop_notes(e, i)
      table.remove(lane[i].active_notes, tab.key(lane[i].active_notes, e.note))
    end
  end
end

function play_notes(e, i)
  if lane[i].output == 1 then
    m.out[i]:note_on(e.note, e.vel, lane[i].mo_ch)
  else
    local player = params:lookup_param("nb_player_"..i):get_player()
    local velocity = util.linlin(0, 127, 0, 1, e.vel)
    player:note_on(e.note, velocity)
  end
end

function stop_notes(e, i)
  if lane[i].output == 1 then
    m.out[i]:note_off(e.note, 64, lane[i].mo_ch)
  else
    local player = params:lookup_param("nb_player_"..i):get_player()
    player:note_off(e.note)
  end
end

function event_q_clock()
  while true do
    clock.sync(qnt.key)
    if #qnt.event > 0 then
      for _, e in ipairs(qnt.event) do
        if e.msg == "note_on" then
          lane[e.i]:watch(e)
          if lane[e.i].midi_thru then
            play_notes(e, e.i)
          end
          if lane[e.i].rec == 1 then
            ui.dirtyscreen = true
          end
        elseif e.msg == "note_off" then
          if not off_flag[e.i][e.note] then
            lane[e.i]:watch(e)
            off_flag[e.i][e.note] = true
          end
          if lane[e.i].midi_thru then
            stop_notes(e, e.i)
          end
        end
      end
      qnt.event = {}
    end
  end
end

lane = {}
for i = 1, NUM_LANES do
  lane[i] = rf.new(i)
  lane[i].process = lane_runner
  lane[i].start_callback = function() clear_active_notes(i) end
  lane[i].end_of_loop_callback = function() catch_note_off(i) end
  lane[i].end_callback = function() clear_active_notes(i) ui.dirtygrid = true end
  lane[i].step_callback = function() track_playhead(i) end
  lane[i].length = 16
  lane[i].meter_id = 3
  lane[i].barnum = 4
  lane[i].position = 1
  lane[i].file_id = "rec   lane   "..i

  lane[i].played_notes = {}
  lane[i].active_notes = {}

  lane[i].step_min_viz = 0
  lane[i].step_max_viz = 0
  lane[i].looping = false
  lane[i].loop_reset = false
  lane[i].snap_reset = false

  lane[i].output = 1
  lane[i].mo_ch = 1
  lane[i].mi_ch = 1
  lane[i].midi_thru = true
end

function track_playhead(i)
  local size = math.floor(lane[i].endpoint / 16)
  if lane[i].step % size == 1 then
    local prev_pos = lane[i].position
    lane[i].position = math.floor((lane[i].step) / size) + 1
    ui.dirtygrid = true
  end
end

function clear_active_notes(i)
  if #lane[i].active_notes > 0 and lane[i].endpoint > 0 then
    for _, note_num in ipairs(lane[i].active_notes) do
      if lane[i].output == 1 then
        m.out[i]:note_off(note_num, 64, lane[i].mo_ch)
      else
        local player = params:lookup_param("nb_player_"..i):get_player()
        player:note_off(note_num)
      end
    end
    lane[i].active_notes = {}
  end
end

function catch_note_off(i)
  if lane[i].rec == 1 then
    for _, note in ipairs(held[i].notes) do
      local e = {i = i, msg = "note_off", note = note, vel = 64}
      lane[i]:insert(e, lane[i].step_max)
      table.remove(held[i].notes, tab.key(held[i].notes, note))
    end
  end
end

function cut_pattern_pos(i, sync, pos)
  clock.sync(sync)
  lane[i].step = math.floor(lane[i].endpoint / 16) * (pos - 1)
  clear_active_notes(i)
end

function set_pattern_loop(i, sync, first, second)
  clock.sync(sync)
  local segment = math.floor(lane[i].endpoint / 16)
  lane[i].step_min = segment * (math.min(first, second) - 1)
  lane[i].step_max = segment * math.max(first, second)
  lane[i].step = lane[i].step_min
  lane[i].looping = true
  clear_active_notes(i)
end

function clear_pattern_loop(i, sync)
  clock.sync(sync)
  --lane[i].step = lane[i].loop_reset and 0 or (math.floor(lane[i].endpoint / 16) * lane[i].position) -- TODO: test
  if lane[i].loop_reset then
    lane[i].step = 0
  end
  lane[i].step_min = 0
  lane[i].step_max = lane[i].endpoint
  lane[i].looping = false
  clear_active_notes(i)
end

function reset_lane(i, sync)
  clock.sync(sync)
  lane[i].step = 0
  lane[i].step_min = 0
  lane[i].step_max = lane[i].endpoint
  lane[i].looping = false
  clear_active_notes(i)
end

function num_rec_enabled()
  local num_enabled = 0
  for i = 1, NUM_LANES do
    if lane[i].rec_enabled > 0 then
      num_enabled = num_enabled + 1
    end
  end
  return num_enabled
end


--------- snapshots  ----------

function save_snapshot(slot)
  snap[slot].has_data = true
  for i = 1, NUM_LANES do
    snap[slot][i].playing = lane[i].play == 1 and true or false
    snap[slot][i].looping = lane[i].looping
    snap[slot][i].min = lane[i].step_min_viz
    snap[slot][i].max = lane[i].step_max_viz
  end
end

function load_snapshot(slot)
  if snap[slot].has_data then
    for i = 1, NUM_LANES do
      if snap[slot][i].playing then
        if lane[i].play == 0 then
          lane[i]:start(qnt.snap)
        end
        if snap[slot][i].looping then
          clock.run(set_pattern_loop, i, qnt.snap, snap[slot][i].min, snap[slot][i].max)
          lane[i].step_min_viz = snap[slot][i].min
          lane[i].step_max_viz = snap[slot][i].max
        else
          if lane[i].looping then
            clock.run(clear_pattern_loop, i, qnt.snap)
            lane[i].looping = false
          end
          if lane[i].snap_reset then
            clock.run(reset_lane, i, qnt.snap)
          end
        end
      else
        if lane[i].play == 1 then
          lane[i]:stop(qnt.snap)
          clock.run(clear_pattern_loop, i, qnt.snap)
          lane[i].looping = false
        end
      end
    end
  end
end

function clear_snapshot(slot)
  snap[slot].has_data = false
end

-------- midi --------
function build_midi_device_list()
  m.devices = {}
  for i = 1, #midi.vports do
    local long_name = midi.vports[i].name
    local short_name = string.len(long_name) > 12 and util.acronym(long_name) or long_name
    table.insert(m.devices, i..": "..short_name)
  end
end

function set_all_channels()
  if m.glb_in then
    for i = 1, NUM_LANES do
      params:set("midi_in_channel_"..i, m.glb_ch)
    end
  end
end

function set_midi_channel(i, val)
  if m.glb_in then
    params:set("midi_in_channel_"..i, m.glb_ch)
  else
    lane[i].mi_ch = val
  end
end

function midi.add()
  build_midi_device_list()
end

function midi.remove()
  clock.run(function()
    clock.sleep(0.2)
    build_midi_device_list()
  end)
end

function set_midi_callback()
  for i = 1, 16 do
    midi.vports[i].event = nil
  end
  m.event = midi_events
end

function midi_events(data)
  local msg = midi.to_msg(data)
  local i = focus.rec > 0 and focus.rec or focus.lane
  if msg.type == "note_on" or msg.type == "note_off" then
    if msg.ch == m.glb_in and m.glb_ch or lane[i].mi_ch then
      local e = {i = i, msg = msg.type, note = msg.note, vel = msg.vel}
      table.insert(qnt.event, e)
      if msg.type == "note_on" then
        -- flag that note off msg needs to occur
        off_flag[i][msg.note] = flase
        table.insert(held[i].notes, msg.note)
      elseif msg.type == "note_off" then
        table.remove(held[i].notes, tab.key(held[i].notes, msg.note))
      end
    end
  end
end

function clock.transport.start()
  -- nothing yet
end

function clock.transport.stop()
  for i = 1, NUM_LANES do
    lane[i]:stop()
  end
end

-------- clock coroutines --------
function vizclock()
  local counter = 0
  while true do
    clock.sync(1/8)
    counter = util.wrap(counter + 1, 1, 8)
    -- beat
    if counter == 1 then
      viz.beat = true
      ui.dirtygrid = true
      clock.run(function()
        clock.sleep(1/30)
        viz.beat = false
        ui.dirtygrid = true
      end)
    end
    -- fast
    viz.key_fast = viz.key_fast == 8 and 12 or 8
    -- mid
    if counter % 2 == 0 then
      viz.key_mid = util.wrap(viz.key_mid + 1, 4, 12)
    end
    -- slow
    if counter % 4 == 0 then
      viz.key_slow = util.wrap(viz.key_slow + 1, 4, 12)
    end
  end
end

function vizbar()
  while true do
    clock.sync(qnt.bar)
    viz.bar = true
    ui.dirtygrid = true
    clock.run(function()
      clock.sleep(1/30)
      viz.bar = false
      ui.dirtygrid = true
    end)
  end
end


--------- midi to reflection conversion ----------

-- format event
function format_event(msg, note, vel)
  local msg = msg == "noteOn" and "note_on" or "note_off" -- transform string
  local e = {i = focus.lane, msg = msg, note = note, vel = vel}
  return e
end

-- callback function to grab tick resolution from header
function get_ticks(string, format, tracks, division)
  m.tick_res = division
end

-- handler for note on/off messages
function parse_notes(msg, channel, note, velocity)
  local vel = math.floor(util.linlin(0, 1, 0, 127, velocity))
  local e = format_event(msg, note, vel)
  if not p.event[p.step] then
    p.event[p.step] = {}
  end
  table.insert(p.event[p.step], e)
  p.count = p.count + 1
end

-- handler for deltatime increments
function get_position(ticks)
  p.step = p.step + math.floor((ticks / m.tick_res) * STEP_RES)
end

-- callback to for conversion
function to_pattern(msg, ...)
  if msg == "deltatime" then
    get_position(...)
  elseif msg == "noteOn" or msg == "noteOff" then
    parse_notes(msg, ...)
  elseif msg == "endOfTrack" then
    copy_to_pattern(p.focus)
  end
end

function convert_to_reflection(i, filename)
  if filename ~= "cancel" and filename ~= "" and filename ~= default_path then
    -- clear temp pattern
    p.step = 1
    p.count = 0
    p.event = {}
    p.endpoint = 0
    p.focus = i
    -- set id
    lane[i].file_id = filename:match("[^/]*$")
    -- read midi and convert
    local file = assert(io.open(filename, "rb"))
    md.processHeader(file, get_ticks)
    assert(file:seek("set"))
    md.processTrack(file, to_pattern, 1)
    file:close()
  end
end

function get_length(i)
  local num_beats = tonumber(lane[i].file_id:match("[^_]*$"):sub(1, -6))
  if type(num_beats) ~= "number" then
    local b = p.step / STEP_RES
    local bl = math.floor(b)
    if b >= bl + 0.5 then
      num_beats = bl + 1
    else
      num_beats = bl
    end
  end
  return num_beats
end

function set_length(i, beats)
  local beats = beats or options.meter_values[lane[i].meter_id] * lane[i].barnum * 4
  lane[i].length = beats
  lane[i]:set_length(beats)
end

function copy_to_pattern(i)
  local num_beats = get_length(i)
  set_length(i, num_beats)
  lane[i].count = p.count
  lane[i].event = deep_copy(p.event)
   -- get bar and meter values
  if ((lane[i].endpoint % STEP_RES == 0) and (lane[i].endpoint >= (STEP_RES * 2))) then
    -- calc values
    local current_meter = options.meter_values[lane[i].meter_id]
    local bar_count = num_beats / (current_meter * 4)
    -- check bar-size
    if bar_count % 1 == 0 then
      params:set("lane_bar_num_"..i, bar_count)
    else
      -- get closest fit
      local n = lane[i].endpoint > (STEP_RES * 2) and 2 or 1
      for c = n, #options.meter_values do
        local new_meter = options.meter_values[c]
        local new_count = num_beats / (new_meter * 4)
        if new_count % 1 == 0 then
          local b = math.floor(new_count)
          params:set("lane_meter_id_"..i, c)
          params:set("lane_bar_num_"..i, b)
          break
        end
      end
    end
  end
  print("copied to pattern: "..i, "num beats: "..lane[i].length)
end

function set_midi_file(i, filename)
  convert_to_reflection(i, filename)
  screenredrawtimer:start()
  ui.dirtyscreen = true
end

--------- utility functions ----------

function set_quant_val()
  local l = params:get("launch_quant")
  qnt.launch = l == 3 and qnt.bar or (l == 2 and 1 or 1/4)
  local o = params:get("loop_quant")
  qnt.loop = o == 3 and qnt.bar or (o == 2 and 1 or 1/4)
  local c = params:get("cut_quant")
  qnt.cut = c == 3 and qnt.bar or (c == 2 and 1 or 1/4)
  local s = params:get("snap_quant")
  qnt.snap = s == 3 and qnt.bar or (s == 2 and 1 or 1/4)
end

function deep_copy(tbl)
  local ret = {}
  if type(tbl) ~= 'table' then return tbl end
  for key, value in pairs(tbl) do
    ret[key] = deep_copy(value)
  end
  return ret
end

function print_event_tab()
  for k, v in pairs(p.event) do
    print("events @ step "..k)
    for e, v in pairs(p.event[k]) do
      print("event "..e)
      tab.print(p.event[k][e])
    end
  end
end


--------- init function ----------
function init()

  -- build midi device list
  build_midi_device_list()

  -- make directory
  if util.file_exists(default_path) == false then
    util.make_dir(default_path)
  end

  -- add params
  params:add_separator("global_settings", "global settings", 4)
  -- time signiture
  params:add_number("time_signature", "time signature", 2, 9, 4, function(param) return param:get().."/4" end)
  params:set_action("time_signature", function(val) qnt.bar = val set_quant_val() end)
  
  params:add_group("quantization_options", "quantization", 5)
  -- input quantization
  params:add_option("key_quant", "key Q", options.q_names, 1)
  params:set_action("key_quant", function(idx) qnt.key = options.q_values[idx] * 4 end)
  -- cut quantization
  params:add_option("cut_quant", "cut Q", {"free", "beat", "bar"}, 2)
  params:set_action("cut_quant", function() set_quant_val() end)
  -- loop quantization
  params:add_option("loop_quant", "loop Q", {"free", "beat", "bar"}, 2)
  params:set_action("loop_quant", function() set_quant_val() end)
  -- launch quantization
  params:add_option("launch_quant", "launch Q", {"free", "beat", "bar"}, 3)
  params:set_action("launch_quant", function() set_quant_val() end)
  -- snapshot quantization
  params:add_option("snap_quant", "snaphot Q", {"free", "beat", "bar"}, 2)
  params:set_action("snap_quant", function() set_quant_val() end)

  params:add_group("input_options", "midi input", 3)
  -- glb midi in device
  params:add_option("glb_midi_in_device", "device", m.devices, 1)
  params:set_action("glb_midi_in_device", function(val) mi = midi.connect(val) set_midi_callback() end)
  -- glb midi in
  params:add_option("glb_midi_in_option", "midi in channel", {"lane", "global"}, 1)
  params:set_action("glb_midi_in_option", function(mode) m.glb_in = mode == 2 and true or false set_all_channels() end)
  -- glb midi channel
  params:add_number("glb_midi_in_channel", "channel", 1, 16, 1)
  params:set_action("glb_midi_in_channel", function(val) m.glb_ch = val set_all_channels() end)

  params:add_separator("lanes_params", "lanes")

  for i = 1, NUM_LANES do
    params:add_group("lane_settings_"..i, "lane "..i, 15)

    params:add_separator("input_options_"..i, "midi input")
    -- midi thru
    params:add_option("midi_in_thru_"..i, "midi monitor", {"off", "thru"}, 2)
    params:set_action("midi_in_thru_"..i, function(mode) lane[i].midi_thru = mode == 2 and true or false end)
    -- midi in channel
    params:add_number("midi_in_channel_"..i, "channel", 1, 16, 1)
    params:set_action("midi_in_channel_"..i, function(val) set_midi_channel(i, val) end)
    
    params:add_separator("output_options_"..i, "lane output")
    -- output options
    params:add_option("lane_output_"..i, "output", {"midi", "nb player"}, 1)
    params:set_action("lane_output_"..i, function(mode) lane[i].output = mode build_menu() end)
    -- nb voice
    nb:add_param("nb_player_"..i, "player")
    -- midi out device
    params:add_option("midi_out_device_"..i, "device", m.devices, 1)
    params:set_action("midi_out_device_"..i, function(val) m.out[i] = midi.connect(val) end)
    -- midi out channel
    params:add_number("midi_out_channel_"..i, "channel", 1, 16, 1)
    params:set_action("midi_out_channel_"..i, function(val) lane[i].mo_ch = val end)

    params:add_separator("playback_options_"..i, "playback options")
    -- playback mode
    params:add_option("playback_mode_"..i, "playback mode", {"oneshot", "loop"}, 2)
    params:set_action("playback_mode_"..i, function(mode) lane[i]:set_loop(mode - 1) end)
    -- playback quantization
    params:add_option("playback_quant_"..i, "note quantization", options.q_names, 1)
    params:set_action("playback_quant_"..i, function(idx) lane[i].quantize = options.q_values[idx] * 4 end)
    -- loop clear
    params:add_option("loop_clear_mode_"..i, "loop clear", {"reset", "continue"}, 1)
    params:set_action("loop_clear_mode_"..i, function(mode) lane[i].loop_reset = mode == 1 and true or false end)
    -- snap reset
    params:add_option("snap_reset_mode_"..i, "snap load", {"reset", "continue"}, 1)
    params:set_action("snap_reset_mode_"..i, function(mode) lane[i].snap_reset = mode == 1 and true or false end)

    params:add_number("lane_meter_id_"..i, "meter id", 1, #options.meter_names, 3)
    params:set_action("lane_meter_id_"..i, function(idx) lane[i].meter_id = idx end)
    params:hide("lane_meter_id_"..i)

    params:add_number("lane_bar_num_"..i, "length", 1, 128, 4)
    params:set_action("lane_bar_num_"..i, function(val) lane[focus.lane].barnum = val end)
    params:hide("lane_bar_num_"..i)
  end

  -- nb parameters
  params:add_separator("nb_params", "nb voices")
  nb:add_player_params()

  -- fx parameters
  if ms.is_loaded("fx") then
    params:add_separator("fx_params", "fx")
  end

  -- set default length
  for i = 1, NUM_LANES do
    set_length(i)
  end

  -- pset callbacks
  params.action_write = function(filename, name, number)
    -- make directory
    os.execute("mkdir -p "..norns.state.data.."sessions/"..number.."/")
    -- populate table
    local data = {}
    data.lane = {}
    data.snap = {}
    -- lane data
    for i = 1, NUM_LANES do
      data.lane[i] = {}
      data.lane[i].length = lane[i].length
      data.lane[i].meter_id = lane[i].meter_id
      data.lane[i].barnum = lane[i].barnum
      data.lane[i].file_id = lane[i].file_id
      data.lane[i].event = deep_copy(lane[i].event)
      data.lane[i].count = lane[i].count
      data.lane[i].endpoint = lane[i].endpoint
    end
    -- snapshot data
    for i = 1, NUM_SNAP do
      data.snap[i] = deep_copy(snap[i])
    end
    -- save table
    tab.save(data, norns.state.data.."sessions/"..number.."/"..name..".data")
    print("finished writing pset: "..name)
  end

  params.action_read = function(filename, silent, number)
    local loaded_file = io.open(filename, "r")
    if loaded_file then
      io.input(loaded_file)
      local pset_id = string.sub(io.read(), 4, -1)
      io.close(loaded_file)
      -- load sesh data file
      local data = tab.load(norns.state.data.."sessions/"..number.."/"..pset_id..".data")
      if next(data) then
        for i = 1, NUM_LANES do
          lane[i].length = data.lane[i].length
          lane[i].meter_id = data.lane[i].meter_id
          lane[i].barnum = data.lane[i].barnum
          lane[i].file_id = data.lane[i].file_id
          lane[i].event = deep_copy(data.lane[i].event)
          lane[i].count = data.lane[i].count
          lane[i].endpoint = data.lane[i].endpoint
        end
        -- snapshot data
        for i = 1, NUM_SNAP do
          snap[i] = deep_copy(data.snap[i])
        end
        ui.dirtyscreen = true
        ui.dirtygrid = true
        print("finished reading pset: "..pset_id)
      else
        print("no data file for: "..pset_id)
      end
    end
  end

  params.action_delete = function(filename, name, number)
    norns.system_cmd("rm -r "..norns.state.data.."sessions/"..number.."/")
    build_pset_list()
    print("finished deleting pset: "..name)
  end

  -- metros
  screenredrawtimer = metro.init(function() screen_redraw() end, 1/15, -1)
  screenredrawtimer:start()
  ui.dirtyscreen = true

  hardwareredrawtimer = metro.init(function() hardware_redraw() end, 1/30, -1)
  hardwareredrawtimer:start()
  ui.dirtygrid = true

  -- clocks
  clock.run(vizbar)
  clock.run(vizclock)
  clock.run(event_q_clock)

  -- bang params
  if load_pset then
    params:default()
  else
    params:bang()
  end

end


--------- norns UI ----------
function key(n, z)
  if n == 1 then
    ui.k1 = z == 1 and true or false
  else
    if ui.k1 then
      if ui.page == 1 then
        if n == 2 and z == 1 then
          screenredrawtimer:stop()
          fs.enter(default_path, function(filename) set_midi_file(focus.lane, filename) end)
          ui.k1 = false
        elseif n == 3 and z == 1 then
          lane[focus.lane]:clear()
        end
      elseif ui.page == 2 and z == 1 then
        set_length(focus.lane)
      elseif ui.page == 4 and z == 1 then
        params:set("lane_output_"..focus.lane, n - 1)
      end
    else
      if z == 1 then
        local inc = n == 3 and 1 or -1
        ui.page = util.wrap(ui.page + inc, 1, NUM_PAGES)
      end
    end
  end
  ui.dirtyscreen = true
end

function enc(n, d)
  if n == 1 then
    focus.lane = util.clamp(focus.lane + d, 1, NUM_LANES)
  else
    if ui.quant_key then
      local param = {"time_signature", "key_quant"}
      params:delta(param[n - 1], d)
    elseif ui.page == 2 then
      local param = {"lane_meter_id_", "lane_bar_num_"}
      params:delta(param[n - 1]..focus.lane, d)
    elseif ui.page == 3 then
      if ui.k1 then
        local param = {"glb_midi_in_option", "glb_midi_in_channel"}
        params:delta(param[n - 1], d)
      else
        local param = {"midi_in_thru_", "midi_in_channel_"}
        params:delta(param[n - 1]..focus.lane, d)
      end
    elseif ui.page == 4 then
      if lane[focus.lane].output == 1 then
        local param = {"midi_out_device_", "midi_out_channel_"}
        params:delta(param[n - 1]..focus.lane, d)
      else
        local param = {"nb_player_", "nb_player_"}
        params:delta(param[n - 1]..focus.lane, d)
      end
    elseif ui.page == 5 then
      local param = {"playback_mode_", "playback_quant_"}
      params:delta(param[n - 1]..focus.lane, d)
    elseif ui.page == 6 then
      local param = {"loop_clear_mode_", "snap_reset_mode_"}
      params:delta(param[n - 1]..focus.lane, d)
    end
  end
  ui.dirtyscreen = true
end

function redraw()
  screen.clear()
  screen.font_face(2)

  if ui.quant_key then
    screen.font_size(8)
    screen.level(2)
    screen.move(64, 12)
    screen.text_center("TIMING")
    screen.font_size(16)
    screen.level(12)
    screen.move(30, 39)
    screen.text_center(params:string("time_signature"))
    screen.move(98, 39)
    screen.text_center(params:string("key_quant"))
    screen.font_size(8)
    screen.level(2)
    screen.move(34, 58)
    screen.text_center("time  signature")
    screen.move(94, 58)
    screen.text_center("key  quantization") 
  else
    screen.font_size(8)
    screen.level(15)
    screen.move(4, 12)
    screen.text(focus.lane)

    if ui.page == 1 then -- NOTES
      screen.font_size(8)
      screen.level(2)
      screen.move(64, 12)
      screen.text_center("NOTES")
  
      screen.font_size(16)
      screen.level(ui.k1 and 1 or 12)
      screen.move(64, 39)
      screen.text_center(lane[focus.lane].count > 0 and lane[focus.lane].file_id or "LOAD  or  REC")
  
      screen.font_size(8)
      screen.level(ui.k1 and 8 or 0)
      screen.move(34, 58)
      screen.text_center("load   file")
      screen.move(94, 58)
      screen.text_center("clear   lane")

    elseif ui.page == 2 then -- LENGTH
      screen.font_size(8)
      screen.level(2)
      screen.move(64, 12)
      screen.text_center("LENGTH")
  
      local num_beats = options.meter_values[lane[focus.lane].meter_id] * lane[focus.lane].barnum * 4
      local barnum = math.floor(lane[focus.lane].barnum)
      screen.font_size(16)
      screen.level(lane[focus.lane].length == num_beats and 12 or 2)
      screen.move(34, 39)
      screen.text_center(options.meter_names[lane[focus.lane].meter_id])
      screen.move(94, 39)
      screen.text_center(barnum..(barnum == 1 and " bar" or " bars"))
  
      screen.font_size(8)
      screen.level(ui.k1 and 8 or 2)
      if ui.k1 then
        screen.move(64, 58)
        screen.text_center(">  set  <")
      else
        screen.move(34, 58)
        screen.text_center("meter")
        screen.move(94, 58)
        screen.text_center("length")
      end
  
    elseif ui.page == 3 then -- INPUT
      screen.font_size(8)
      screen.level(2)
      screen.move(64, 12)
      screen.text_center("INPUT")
  
      screen.font_size(16)
      screen.level(12)
      if ui.k1 then
        screen.move(34, 39)
        screen.text_center(params:string("glb_midi_in_option"))
        screen.move(94, 39)
        screen.text_center(m.glb_in and params:string("glb_midi_in_channel") or "-")
      else
        screen.move(34, 39)
        screen.text_center(params:string("midi_in_thru_"..focus.lane))
        screen.move(94, 39)
        screen.text_center(m.glb_in and "glb" or params:string("midi_in_channel_"..focus.lane))
      end
      
      screen.font_size(8)
      screen.level(ui.k1 and 8 or 2)
      if ui.k1 then
        screen.move(34, 58)
        screen.text_center("midi   in")
        screen.move(94, 58)
        screen.text_center("global   ch")
      else
        screen.move(34, 58)
        screen.text_center("monitor")
        screen.move(94, 58)
        screen.text_center("channel")
      end
      
    elseif ui.page == 4 then -- OUTPUT
      screen.font_size(8)
      screen.level(2)
      screen.move(64, 12)
      screen.text_center("OUTPUT")
  
      screen.font_size(16)
      screen.level(12)
      if lane[focus.lane].output == 1 then
        screen.move(34, 39)
        screen.text_center(params:string("midi_out_device_"..focus.lane))
        screen.move(94, 39)
        screen.text_center(params:string("midi_out_channel_"..focus.lane))
      else
        screen.move(64, 39)
        screen.text_center(params:string("nb_player_"..focus.lane))
      end
      
      screen.font_size(8)
      screen.level(ui.k1 and 8 or 2)
      if ui.k1 then
        screen.move(34, 58)
        screen.text_center(">  midi")
        screen.move(94, 58)
        screen.text_center("nb  <")
      else
        if lane[focus.lane].output == 1 then
          screen.move(34, 58)
          screen.text_center("device")
          screen.move(94, 58)
          screen.text_center("channel")
        else
          screen.move(64, 58)
          screen.text_center("nb player")
        end
      end
    
    elseif ui.page == 5 then -- PLAYBACK
      screen.font_size(8)
      screen.level(2)
      screen.move(64, 12)
      screen.text_center("PLAYBACK")
  
      screen.font_size(16)
      screen.level(12)
      screen.move(34, 39)
      screen.text_center(params:string("playback_mode_"..focus.lane))
      screen.move(94, 39)
      screen.text_center(params:string("playback_quant_"..focus.lane))
  
      screen.font_size(8)
      screen.level(2)
      screen.move(34, 58)
      screen.text_center("mode")
      screen.move(94, 58)
      screen.text_center("quantization")
  
    elseif ui.page == 6 then -- PLAYHEAD
      screen.font_size(8)
      screen.level(2)
      screen.move(64, 12)
      screen.text_center("PLAYHEAD")
  
      screen.font_size(16)
      screen.level(12)
      screen.move(34, 39)
      screen.text_center(params:string("loop_clear_mode_"..focus.lane))
      screen.move(94, 39)
      screen.text_center(params:string("snap_reset_mode_"..focus.lane))
      
      screen.font_size(8)
      screen.level(2)
      screen.move(34, 58)
      screen.text_center("@ loop clear")
      screen.move(94, 58)
      screen.text_center("@ snapshot load")
    end
  end
  screen.update()
end

--------- grid UI ----------
function g.key(x, y, z)
  if y == 8 then
    if x == 1 then
      ui.rec_key = z == 1 and true or false
    elseif x == 2 then
      ui.stop_key = z == 1 and true or false
    elseif x == 3 then
      ui.loop_key = z == 1 and true or false
    elseif x > 4 and x < 13 and z == 1 then
      local i = x - 4
      if snap[i].has_data then
        if ui.reset_key then
          clear_snapshot(i)
        else
          load_snapshot(i)
        end
      else
        save_snapshot(i)
      end
    elseif x == 14 then
      ui.loop_key = z == 1 and true or false
    elseif x == 15 then
      ui.reset_key = z == 1 and true or false
      -- if rec then clear or undo
      if ui.rec_key and focus.rec > 0 then
        if next(lane[focus.rec].event_prev) then
          lane[focus.rec]:undo()
        else
          lane[focus.rec].event = {}
          lane[focus.rec].count = 0
        end
        clear_active_notes(focus.rec)
      end
    elseif x == 16 then
      ui.all_key = z == 1 and true or false
      if ui.rec_key then
        -- do nothing
      elseif ui.stop_key then -- stop all
        for i = 1, NUM_LANES do
          if lane[i].play == 1 then
            lane[i]:stop()
          end
        end
      elseif ui.loop_key then -- clear all loops
        for i = 1, NUM_LANES do
          if lane[i].looping then
            clock.run(clear_pattern_loop, i, qnt.loop)
            lane[i].looping = false
          end
        end
      elseif ui.reset_key then
        for i = 1, NUM_LANES do
          if lane[i].play == 1 then
            clock.run(reset_lane, i, qnt.launch)
          end
        end
      else
        ui.quant_key = z == 1 and true or false
        ui.dirtyscreen = true
      end
    end
  else
    local i = y
    if focus.lane ~= i then
      focus.lane = i
      ui.dirtyscreen = true
    end
    if z == 1 and held[i].num then held[i].max = 0 end
    held[i].num = held[i].num + (z * 2 - 1)
    if held[i].num > held[i].max then held[i].max = held[i].num end
    if z == 1 then
      -- set held keys
      if held[i].num == 1 then
        held[i].first = x
      elseif held[i].num == 2 then
        held[i].second = x
      end
      -- actions
      if ui.rec_key then
        for n = 1, NUM_LANES do
          if n ~= i then
            lane[n]:set_rec(0)
          end
        end
        if lane[i].rec == 0 then
          if lane[i].play == 0 then
            lane[i]:set_rec(2)
          else
            lane[i]:set_rec(1)
          end
          focus.rec = i
        end     
      elseif ui.stop_key then
        if lane[i].play == 1 then
          lane[i]:stop()
        else
          local x_min = (lane[i].looping and x < lane[i].step_min_viz) and lane[i].step_min_viz or x
          local pos = math.floor(lane[i].endpoint / 16) * (x_min - 1)
          lane[i]:start(qnt.launch, pos)
        end
      elseif ui.reset_key then
        if lane[i].rec_enabled == 0 and lane[i].play == 1 then
          clock.run(reset_lane, i, qnt.launch)
        end
      else
        if lane[i].rec_enabled == 0 and lane[i].play == 0 then
          clock.run(clear_pattern_loop, i, 1/96)
          local pos = math.floor(lane[i].endpoint / 16) * (x - 1)
          lane[i]:start(qnt.launch, pos)
        end
      end
    elseif z == 0 and not (ui.rec_key or ui.stop_key or ui.reset_key) then
      if lane[i].rec_enabled == 1 then
        lane[i]:set_rec(0)
        focus.rec = 0
      elseif held[i].num == 1 and held[i].max == 2 then
        if ui.all_key then
          for n = 1, NUM_LANES do
            if lane[n].play == 1 then
              clock.run(set_pattern_loop, n, qnt.loop, held[i].first, held[i].second)
              lane[n].step_min_viz = math.min(held[i].first, held[i].second)
              lane[n].step_max_viz = math.max(held[i].first, held[i].second)
              lane[n].looping = true
            end
          end
        else
          clock.run(set_pattern_loop, i, qnt.loop, held[i].first, held[i].second)
          lane[i].step_min_viz = math.min(held[i].first, held[i].second)
          lane[i].step_max_viz = math.max(held[i].first, held[i].second)
          lane[i].looping = true
        end
      elseif lane[i].looping and held[i].max < 2 then
        clock.run(clear_pattern_loop, i, qnt.loop)
        lane[i].looping = false
      elseif not lane[i].looping and held[i].max < 2 and lane[i].play == 1 then
        clock.run(cut_pattern_pos, i, qnt.cut, x)
      end
    end
  end
  ui.dirtygrid = true
end

function gridredraw()
  g:all(0)
  for i = 1, NUM_LANES do
    if lane[i].rec_enabled == 1 then
      for x = 1, 16 do
        g:led(x, i, 2)
      end
    end
    if lane[i].looping then
      local min = lane[i].step_min_viz
      local max = lane[i].step_max_viz
      for x = min, max do
        g:led(x, i, 4)
      end
    end
    if lane[i].play == 1 and lane[i].endpoint > 0 then
      g:led(lane[i].position, i, lane[i].play == 1 and (lane[i].rec == 1 and 15 or 8) or 0)
    end
  end
  -- rec
  g:led(1, 8, ui.rec_key and 15 or 10)
  -- playback
  g:led(2, 8, ui.stop_key and 15 or 6)
  -- snapshots
  for i = 1, NUM_SNAP do
    g:led(i + 4, 8, snap[i].has_data and 10 or 4)
  end
  --loop
  g:led(14, 8, ui.loop_key and 15 or 2)
  -- reset
  g:led(15, 8, ui.reset_key and 15 or 4)
  -- metronome / ui.all_key
  g:led(16, 8, viz.bar and 15 or (viz.beat and 8 or (ui.all_key and 6 or 3))) -- Q flash

  g:refresh()
end

--------- redraw functions ----------
function screen_redraw()
  if ui.dirtyscreen then
    redraw()
    ui.dirtyscreen = false
  end
end

function hardware_redraw()
  if ui.dirtygrid then
    gridredraw()
    ui.dirtygrid = false
  end
end

function build_menu()
  local num_nb = 0
  for i = 1, NUM_LANES do
    if lane[i].output == 1 then
      params:hide("nb_player_"..i)
      params:show("midi_out_device_"..i)
      params:show("midi_out_channel_"..i)
      params:set("nb_player_"..i, 1)
    else
      params:show("nb_player_"..i)
      params:hide("midi_out_device_"..i)
      params:hide("midi_out_channel_"..i)
      num_nb = num_nb + 1
    end
  end
  if num_nb > 0 then
    params:show("nb_params")
  else
    params:hide("nb_params")
  end
  _menu.rebuild_params()
  ui.dirtyscreen = true
end


--------- cleanup ----------
function cleanup()
  print("all nice and tidy here")
end

