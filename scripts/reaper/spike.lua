-- @license
-- Copyright (c) Audanika. All Rights Reserved.
--
-- Use of this source code is governed by terms that can be
-- found in the LICENSE file in the root of this package.

-- The scenarios of the spike S0-plugin-ui (ticket 24) as a ReaScript:
-- scripts/reaper.js starts REAPER with this script and a configuration in
-- the file AUD_REAPER_CONFIG names. The script adds the plugins to tracks,
-- starts the transport, opens and closes the editors, plays automation and
-- writes what it did as JSON lines to the configuration's log; at the end
-- it saves the scratch project and quits REAPER.

local config = dofile(os.getenv("AUD_REAPER_CONFIG"))
local logFile = io.open(config.log, "a")

local function record(kind, fields)
  logFile:write(string.format('{"kind":"%s","t":%.6f%s}\n', kind,
    reaper.time_precise(), fields or ""))
  logFile:flush()
end

-- Tracks with one plugin each: every plugin of the configuration, as many
-- instances of each as it asks for. The tracks leave out anticipative FX
-- processing, so the plugins render on the audio thread like a played
-- instrument; the master is muted.
reaper.SetMediaTrackInfo_Value(reaper.GetMasterTrack(0), "B_MUTE", 1)
local slots = {}
for _, plugin in ipairs(config.plugins) do
  for _ = 1, config.instances do
    local index = reaper.CountTracks(0)
    reaper.InsertTrackAtIndex(index, true)
    local track = reaper.GetTrack(0, index)
    reaper.SetMediaTrackInfo_Value(track, "I_PERFFLAGS", 2)
    local fx = reaper.TrackFX_AddByName(track, plugin, false, -1)
    if fx < 0 then
      record("error", string.format(',"message":"plugin %s not found"', plugin))
    else
      local _, name = reaper.TrackFX_GetFXName(track, fx, "")
      record("added", string.format(',"name":"%s"', name))
    end
    local slot = { track = track, fx = fx, plugin = plugin }
    for p = 0, reaper.TrackFX_GetNumParams(track, fx) - 1 do
      local _, name = reaper.TrackFX_GetParamName(track, fx, p, "")
      if name == "Spike test" then slot.test = p end
      if name == "filter Cutoff" then slot.cutoff = p end
      if name:lower() == "out master" then slot.master = p end
    end
    slots[#slots + 1] = slot
  end
end
record("setup", string.format(',"slots":%d', #slots))

local function show(slot, open)
  -- 3 opens the floating window, 2 closes it.
  reaper.TrackFX_Show(slot.track, slot.fx, open and 3 or 2)
  record(open and "show" or "hide", string.format(',"track":%d',
    reaper.GetMediaTrackInfo_Value(slot.track, "IP_TRACKNUMBER")))
end

local function showAll(open)
  for _, slot in ipairs(slots) do show(slot, open) end
end

-- Automation of the cutoff: a ramp from 0.25 to 0.5 and back in 1000
-- steps at 60 per second, from `start` seconds on (the automate scenario),
-- or a slow sine over `length` seconds (the soak).
local function automate(slot, start, length, sine)
  if slot.cutoff == nil then return end
  local envelope = reaper.GetFXEnvelope(slot.track, slot.fx, slot.cutoff, true)
  if sine then
    for step = 0, math.floor(length * 10) do
      local t = step / 10
      reaper.InsertEnvelopePoint(envelope, start + t,
        0.3 + 0.2 * math.sin(t / 20 * 2 * math.pi), 0, 0, false, true)
    end
  else
    for step = 0, 1000 do
      local value = 0.25 + (step <= 500 and step or 1000 - step) * 0.0005
      reaper.InsertEnvelopePoint(envelope, start + step / 60, value, 1, 0, false, true)
    end
  end
  reaper.Envelope_SortPoints(envelope)
end

local actions = {}
local function at(seconds, action) actions[#actions + 1] = { at = seconds, run = action } end

local scenario = config.scenario
local duration = config.duration or 10
local finish = duration

if scenario == "closed" then
  at(5, function() record("closed") end)
elseif scenario == "open" then
  at(1, function() showAll(true) end)
  at(4, function() record("open") end)
  at(duration - 1, function() showAll(false) end)
elseif scenario == "idle" then
  -- Open editors over a silent output: the meter stands still, nothing
  -- animates.
  at(1, function() showAll(true) end)
  at(1.5, function()
    for _, slot in ipairs(slots) do
      if slot.master ~= nil then
        reaper.TrackFX_SetParamNormalized(slot.track, slot.fx, slot.master, 0)
      end
    end
    record("silent")
  end)
  at(duration - 1, function() showAll(false) end)
elseif scenario == "test" then
  at(1, function() show(slots[1], true) end)
  at(4, function()
    reaper.TrackFX_SetParamNormalized(slots[1].track, slots[1].fx, slots[1].test, 1)
  end)
  at(26, function()
    reaper.TrackFX_SetParamNormalized(slots[1].track, slots[1].fx, slots[1].test, 0)
    show(slots[1], false)
  end)
  finish = 28
elseif scenario == "automate" then
  automate(slots[1], 3, 0, false)
  at(1, function() show(slots[1], true) end)
  at(24, function() show(slots[1], false) end)
  finish = 25
elseif scenario == "cycles" then
  local cycles = config.cycles or 100
  for cycle = 0, cycles - 1 do
    at(1 + cycle * 0.7, function() showAll(true) end)
    at(1 + cycle * 0.7 + 0.5, function() showAll(false) end)
  end
  finish = 1 + cycles * 0.7 + 3
elseif scenario == "crash" then
  -- As the test host does: scripts/reaper.js kills the editor process at
  -- 4 s, the editors reopen at 7 s, and scripts/reaper.js suspends the new
  -- editor process from 10 s to 20 s.
  at(1, function() showAll(true) end)
  at(7, function() showAll(false) end)
  at(7.2, function() showAll(true) end)
  at(23, function() showAll(false) end)
  finish = 24
elseif scenario == "soak" then
  for _, slot in ipairs(slots) do automate(slot, 0, duration, true) end
  at(1, function() showAll(true) end)
  at(duration - 1, function() showAll(false) end)
elseif scenario == "pair" then
  at(1, function() showAll(true) end)
  at(5, function()
    record("closeFirst")
    show(slots[1], false)
  end)
  at(9, function() showAll(false) end)
  finish = 10
end

table.sort(actions, function(a, b) return a.at < b.at end)
-- An empty project ends at once and the transport stops; it loops the
-- first hour instead.
reaper.GetSet_LoopTimeRange(true, true, 0, 3600, false)
reaper.GetSetRepeat(1)
reaper.SetEditCurPos(0, false, false)
reaper.OnPlayButton()
local start = reaper.time_precise()
local next = 1
record("start", string.format(',"scenario":"%s"', scenario))

local function quit()
  reaper.OnStopButton()
  record("done")
  logFile:close()
  reaper.Main_SaveProject(0, false)
  reaper.Main_OnCommand(40004, 0) -- File: Quit REAPER
end

-- Once a second: whether REAPER's audio runs and the transport plays.
local lastTick = -1
local function tick(now)
  if math.floor(now) == lastTick then return end
  lastTick = math.floor(now)
  -- REAPER may drop the play command of the script's start.
  if reaper.GetPlayState() & 1 == 0 and now < 10 then
    reaper.OnPlayButton()
    record("play")
  end
  record("tick", string.format(',"audio":%d,"play":%d,"pos":%.3f',
    reaper.Audio_IsRunning(), reaper.GetPlayState(), reaper.GetPlayPosition()))
end

local function loop()
  local now = reaper.time_precise() - start
  tick(now)
  while next <= #actions and actions[next].at <= now do
    actions[next].run()
    next = next + 1
  end
  if now >= finish then
    quit()
    return
  end
  reaper.defer(loop)
end

reaper.defer(loop)
