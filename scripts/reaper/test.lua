-- @license
-- Copyright (c) Audanika. All Rights Reserved.
--
-- Use of this source code is governed by terms that can be
-- found in the LICENSE file in the root of this package.

-- The REAPER test of a plugin (ticket 37), run by scripts/reaper-test.js:
-- REAPER finds the plugin, a MIDI item with a note on each of the MIDI
-- channels 1 to 4 renders offline with several presets into WAV files, the
-- item plays live for a few seconds, and the preset a saved project holds
-- comes back when the project opens again. Every step writes a JSON line
-- to the file AUD_REAPER_CONFIG names as `log`; scripts/reaper-test.js
-- checks the lines and the files.

local config = dofile(os.getenv("AUD_REAPER_CONFIG"))
local logFile = io.open(config.log, "a")

local function jsonString(text)
  return '"' .. tostring(text):gsub('[%c"\\]', function(c)
    return string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function record(kind, fields)
  logFile:write(string.format('{"kind":%s,"t":%.3f%s}\n', jsonString(kind),
    reaper.time_precise(), fields or ""))
  logFile:flush()
end

local function quit()
  reaper.OnStopButton()
  record("done")
  logFile:close()
  reaper.Main_SaveProject(0, false)
  reaper.Main_OnCommand(40004, 0) -- File: Quit REAPER
end

-- The track with the plugin.
reaper.InsertTrackAtIndex(0, true)
local track = reaper.GetTrack(0, 0)
local fx = reaper.TrackFX_AddByName(track, config.plugin, false, -1)
if fx < 0 then
  record("error", ',"message":' .. jsonString("plugin " .. config.plugin .. " not found"))
  quit()
  return
end
local _, fxName = reaper.TrackFX_GetFXName(track, fx, "")
record("added", ',"name":' .. jsonString(fxName) .. ',"params":' ..
  reaper.TrackFX_GetNumParams(track, fx))
-- The plugin's editor in a floating window while the test runs.
if (config.showEditor or 0) > 0 then
  reaper.TrackFX_Show(track, fx, 3)
  record("editorShown")
end

-- The parameter of the presets: its name starts with "Preset".
local presetParam = -1
for p = 0, reaper.TrackFX_GetNumParams(track, fx) - 1 do
  local _, name = reaper.TrackFX_GetParamName(track, fx, p, "")
  if name:sub(1, 6) == "Preset" then presetParam = p end
end
local _, _, presetSteps = reaper.TrackFX_GetParameterStepSizes(track, fx, presetParam)
local presets = config.presets
record("presetParam", string.format(',"index":%d', presetParam))

-- A MIDI item of three seconds from 0.5 s: a note on each of the MIDI
-- channels 1 to 4 for two seconds.
local item = reaper.CreateNewMIDIItemInProj(track, 0.5, 3.5, false)
local take = reaper.GetActiveTake(item)
local pitches = { 48, 60, 72, 76 }
for channel = 0, 3 do
  local from = reaper.MIDI_GetPPQPosFromProjTime(take, 0.5)
  local to = reaper.MIDI_GetPPQPosFromProjTime(take, 2.5)
  reaper.MIDI_InsertNote(take, false, false, from, to, channel, pitches[channel + 1], 100, true)
end
reaper.MIDI_Sort(take)

-- Offline: one WAV per preset.
reaper.GetSetProjectInfo_String(0, "RENDER_FILE", config.renderDir, true)
reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 0, true)    -- master mix
reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 1, true)  -- entire project
reaper.GetSetProjectInfo(0, "RENDER_SRATE", 48000, true)
reaper.GetSetProjectInfo(0, "RENDER_CHANNELS", 2, true)
reaper.GetSetProjectInfo(0, "RENDER_TAILFLAG", 0, true)
for _, index in ipairs(config.render) do
  local value = presets > 1 and index / (presets - 1) or 0
  reaper.TrackFX_SetParamNormalized(track, fx, presetParam, value)
  local name = "preset-" .. index
  reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", name, true)
  local started = reaper.time_precise()
  reaper.Main_OnCommand(42230, 0) -- Render project, last settings, auto-close
  local _, shown = reaper.TrackFX_GetFormattedParamValue(track, fx, presetParam, "")
  record("rendered", string.format(',"preset":%d,"name":%s,"file":%s,"seconds":%.3f',
    index, jsonString(shown), jsonString(config.renderDir .. "/" .. name .. ".wav"),
    reaper.time_precise() - started))
end

-- The last preset of the list stays and is saved with the project.
local saved = presets > 1 and 1 or 0
reaper.TrackFX_SetParamNormalized(track, fx, presetParam, saved)
reaper.Main_SaveProject(0, false)
record("saved", string.format(',"preset":%.4f', saved))

-- Live: play the item and take the track's peak.
local start = reaper.time_precise()
local peak = 0
reaper.SetEditCurPos(0, false, false)
reaper.OnPlayButton()
local function playing()
  local now = reaper.time_precise() - start
  peak = math.max(peak, reaper.Track_GetPeakInfo(track, 0), reaper.Track_GetPeakInfo(track, 1))
  if now < math.max(4, config.showEditor or 0) then
    if reaper.GetPlayState() & 1 == 0 and now < 1 then reaper.OnPlayButton() end
    reaper.defer(playing)
    return
  end
  reaper.OnStopButton()
  record("played", string.format(',"peak":%.6f,"audio":%d', peak, reaper.Audio_IsRunning()))
  if (config.showEditor or 0) > 0 then reaper.TrackFX_Show(track, fx, 2) end
  -- The project opens again: the plugin restores its preset.
  reaper.Main_openProject("noprompt:" .. config.project)
  local reopened = reaper.GetTrack(0, 0)
  local value = reopened and reaper.TrackFX_GetParamNormalized(reopened, 0, presetParam) or -1
  record("reopened", string.format(',"preset":%.4f', value))
  quit()
end
reaper.defer(playing)
