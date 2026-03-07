-- Scheduled Looper (JSFX Companion)
-- Scans tracks for rec/play MIDI items, writes current group to gmem per track.
-- Exports buffer before advancing to the next group on the same track.

local reaper = reaper
local SCRIPT_NAME = "Scheduled Looper (JSFX)"

reaper.gmem_attach("scheduled_looper")

-- ─── State ───────────────────────────────────────────────────────────────────

local script_running = true
local bypassed = false
local last_scan_time = 0
local SCAN_INTERVAL = 1.0
local PRE_ROLL = 0.05
local POST_ROLL = 0.05
local last_play_state = reaper.GetPlayState()

-- Per-track data: keyed by track pointer
--   .groups = ordered list of { rec_item, play_items={}, track }
--   .current = index into .groups (the group currently written to gmem)
--   .exported = true if current group's buffer was already exported
--   .cleared  = true if current group's old audio was already cleared
local track_data = {}

-- ─── Item helpers ────────────────────────────────────────────────────────────

local function get_item_name(item)
  local take = reaper.GetActiveTake(item)
  if not take then return "" end
  local _, name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
  return name:lower()
end

local function is_item_muted(item)
  return reaper.GetMediaItemInfo_Value(item, "B_MUTE") == 1
end

local function get_item_pos(item)
  return reaper.GetMediaItemInfo_Value(item, "D_POSITION")
end

local function get_item_len(item)
  return reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
end

-- ─── Track scanning ─────────────────────────────────────────────────────────

local function scan_track(track)
  local num_items = reaper.CountTrackMediaItems(track)
  local entries = {}
  for i = 0, num_items - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local name = get_item_name(item)
    if name == "rec" then
      entries[#entries + 1] = { type = "rec", item = item }
    elseif name == "play" then
      entries[#entries + 1] = { type = "play", item = item }
    end
  end

  local track_groups = {}
  local current_group = nil
  for _, entry in ipairs(entries) do
    if entry.type == "rec" then
      current_group = { rec_item = entry.item, play_items = {}, track = track }
      track_groups[#track_groups + 1] = current_group
    elseif entry.type == "play" and current_group then
      current_group.play_items[#current_group.play_items + 1] = entry.item
    end
  end
  return track_groups
end

local function scan_all_tracks()
  local new_data = {}
  local num_tracks = reaper.CountTracks(0)
  for t = 0, num_tracks - 1 do
    local track = reaper.GetTrack(0, t)
    local groups = scan_track(track)
    if #groups > 0 then
      -- Preserve current index if track already had data
      local old = track_data[track]
      new_data[track] = {
        groups = groups,
        current = old and old.current or 1,
        exported = old and old.exported or false,
        cleared = old and old.cleared or false,
      }
    end
  end
  track_data = new_data
end

-- ─── JSFX management ───────────────────────────────────────────────────────

local JSFX_ADD_NAME = "JS:scheduled_looper"
local jsfx_managed = {}

local function remove_all_jsfx()
  local num_tracks = reaper.CountTracks(0)
  for t = 0, num_tracks - 1 do
    local track = reaper.GetTrack(0, t)
    for i = reaper.TrackFX_GetCount(track) - 1, 0, -1 do
      local _, name = reaper.TrackFX_GetFXName(track, i, "")
      if name and name:lower():find("scheduled looper") then
        reaper.TrackFX_Delete(track, i)
      end
    end
  end
  jsfx_managed = {}
end

local function ensure_jsfx_on_tracks()
  local tracks_to_embed = {}
  for track in pairs(track_data) do
    if not jsfx_managed[track] then
      local fx_idx = reaper.TrackFX_AddByName(track, JSFX_ADD_NAME, false, -1)
      if fx_idx >= 0 then
        local track_idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") - 1
        reaper.TrackFX_SetParam(track, fx_idx, 0, track_idx)
        tracks_to_embed[track] = true
      end
      jsfx_managed[track] = true
    end
  end
  if next(tracks_to_embed) then
    local saved_sel = {}
    for s = 0, reaper.CountSelectedTracks(0) - 1 do
      saved_sel[#saved_sel + 1] = reaper.GetSelectedTrack(0, s)
    end
    for s = 0, reaper.CountTracks(0) - 1 do
      reaper.SetTrackSelected(reaper.GetTrack(0, s), false)
    end
    for track in pairs(tracks_to_embed) do
      reaper.SetTrackSelected(track, true)
    end
    reaper.Main_OnCommand(42340, 0)
    for s = 0, reaper.CountTracks(0) - 1 do
      reaper.SetTrackSelected(reaper.GetTrack(0, s), false)
    end
    for _, tr in ipairs(saved_sel) do
      reaper.SetTrackSelected(tr, true)
    end
  end
end

-- ─── gmem sync (Lua → JSFX) ─────────────────────────────────────────────────

local function write_gmem()
  reaper.gmem_write(1, bypassed and 1 or 0)
  for track, td in pairs(track_data) do
    local group = td.groups[td.current]
    if not group then goto continue end
    local track_idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") - 1
    local base = 100 + track_idx * 50
    local rec_start = get_item_pos(group.rec_item)
    local rec_end = rec_start + get_item_len(group.rec_item)
    reaper.gmem_write(base, rec_start)
    reaper.gmem_write(base + 1, rec_end)
    reaper.gmem_write(base + 2, is_item_muted(group.rec_item) and 1 or 0)
    reaper.gmem_write(base + 3, #group.play_items)
    for j, play_item in ipairs(group.play_items) do
      local pbase = base + 4 + (j - 1) * 3
      local ps = get_item_pos(play_item)
      reaper.gmem_write(pbase, ps)
      reaper.gmem_write(pbase + 1, ps + get_item_len(play_item))
      reaper.gmem_write(pbase + 2, is_item_muted(play_item) and 1 or 0)
    end
    ::continue::
  end
end

-- ─── Export logic ─────────────────────────────────────────────────────────────

local pending_export = nil
local export_queue = {}
local saved_edit_cursor = nil

local function get_track_below(track)
  local idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")
  if idx < reaper.CountTracks(0) then
    return reaper.GetTrack(0, idx)
  end
  return nil
end

local function clear_group_audio(group)
  local audio_track = get_track_below(group.track)
  if not audio_track then return end
  local ranges = {}
  local rs = get_item_pos(group.rec_item)
  ranges[#ranges + 1] = { rs, rs + get_item_len(group.rec_item) + 0.01 }
  for _, play_item in ipairs(group.play_items) do
    local ps = get_item_pos(play_item)
    ranges[#ranges + 1] = { ps, ps + get_item_len(play_item) }
  end
  local changed = false
  for i = reaper.CountTrackMediaItems(audio_track) - 1, 0, -1 do
    local item = reaper.GetTrackMediaItem(audio_track, i)
    local take = reaper.GetActiveTake(item)
    if take and not reaper.TakeIsMIDI(take) then
      local ipos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local iend = ipos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      for _, r in ipairs(ranges) do
        if ipos < r[2] and iend > r[1] then
          reaper.DeleteTrackMediaItem(audio_track, item)
          changed = true
          break
        end
      end
    end
  end
  if changed then reaper.UpdateArrange() end
end

local function snapshot_audio_items(track)
  local snap = {}
  if track then
    for i = 0, reaper.CountTrackMediaItems(track) - 1 do
      snap[reaper.GetTrackMediaItem(track, i)] = true
    end
  end
  return snap
end

local function find_new_audio_item(track, snapshot)
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    if not snapshot[item] then
      local take = reaper.GetActiveTake(item)
      if take and not reaper.TakeIsMIDI(take) then
        return item
      end
    end
  end
  return nil
end

local function place_at_play_regions(group, audio_track, src_filename, rec_len)
  reaper.PreventUIRefresh(1)
  for _, play_item in ipairs(group.play_items) do
    if not is_item_muted(play_item) then
      local play_pos = get_item_pos(play_item)
      local play_len = get_item_len(play_item)
      local play_end = play_pos + play_len
      local n_copies = math.ceil(play_len / rec_len)
      for c = 0, n_copies - 1 do
        local grid_pos = play_pos + c * rec_len
        local remaining = play_end - grid_pos
        local copy_len = math.min(rec_len, remaining)
        local new_item = reaper.AddMediaItemToTrack(audio_track)
        local new_take = reaper.AddTakeToMediaItem(new_item)
        local new_source = reaper.PCM_Source_CreateFromFile(src_filename)
        reaper.SetMediaItemTake_Source(new_take, new_source)
        reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", grid_pos)
        reaper.SetMediaItemInfo_Value(new_item, "D_LENGTH", copy_len)
        local fade_in = (c == 0) and PRE_ROLL or 0.005
        local fade_out = (c == n_copies - 1) and POST_ROLL or 0.005
        reaper.SetMediaItemInfo_Value(new_item, "D_FADEINLEN", fade_in)
        reaper.SetMediaItemInfo_Value(new_item, "D_FADEOUTLEN", fade_out)
      end
    end
  end
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
end

local function queue_export(group, track)
  local track_idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") - 1
  export_queue[#export_queue + 1] = {
    group = group,
    track_idx = track_idx,
    rec_start = get_item_pos(group.rec_item),
  }
end

local function process_export()
  if not pending_export and #export_queue > 0 then
    local next_exp = table.remove(export_queue, 1)
    if not saved_edit_cursor then
      saved_edit_cursor = reaper.GetCursorPosition()
    end
    clear_group_audio(next_exp.group)
    local audio_track = get_track_below(next_exp.group.track)
    local pre_snap = snapshot_audio_items(audio_track)
    reaper.SetEditCurPos(next_exp.rec_start, false, false)
    reaper.gmem_write(21, next_exp.track_idx + 1)
    reaper.gmem_write(20, next_exp.track_idx + 1) -- trigger = track_idx + 1
    pending_export = {
      group = next_exp.group, phase = "wait", tick = 0,
      audio_track = audio_track, pre_snap = pre_snap,
    }
  end

  if not pending_export then return end
  local pe = pending_export

  if pe.phase == "wait" then
    pe.tick = pe.tick + 1
    if reaper.gmem_read(20) == 0 then
      pe.phase = "place"
    elseif pe.tick > 60 then
      pending_export = nil
      if #export_queue == 0 and saved_edit_cursor then
        reaper.SetEditCurPos(saved_edit_cursor, false, false)
        saved_edit_cursor = nil
      end
    end

  elseif pe.phase == "place" then
    if pe.audio_track then
      local rec_len = get_item_len(pe.group.rec_item)
      local item = find_new_audio_item(pe.audio_track, pe.pre_snap)
      if item then
        local take = reaper.GetActiveTake(item)
        local source = take and reaper.GetMediaItemTake_Source(take)
        local src_filename = source and reaper.GetMediaSourceFileName(source)
        if src_filename and src_filename ~= "" then
          place_at_play_regions(pe.group, pe.audio_track, src_filename, rec_len)
        end
      end
    end
    pending_export = nil
    if #export_queue == 0 and saved_edit_cursor then
      reaper.SetEditCurPos(saved_edit_cursor, false, false)
      saved_edit_cursor = nil
    end
  end
end

-- ─── Main loop ───────────────────────────────────────────────────────────────

local function looper_tick()
  if not script_running then return end

  -- Periodic rescan
  local now = reaper.time_precise()
  local needs_rescan = now - last_scan_time >= SCAN_INTERVAL
  if not needs_rescan then
    for _, td in pairs(track_data) do
      for _, g in ipairs(td.groups) do
        if not reaper.ValidatePtr(g.rec_item, "MediaItem*") then
          needs_rescan = true
          break
        end
      end
      if needs_rescan then break end
    end
  end
  if needs_rescan then
    scan_all_tracks()
    ensure_jsfx_on_tracks()
    last_scan_time = now
  end

  local play_state = reaper.GetPlayState()

  -- On play start: pick the right starting group for each track
  if last_play_state == 0 and play_state > 0 then
    local pos = reaper.GetPlayPosition()
    for _, td in pairs(track_data) do
      -- Find which group the playhead is in or approaching
      td.current = 1
      td.exported = false
      td.cleared = false
      for i, g in ipairs(td.groups) do
        local rec_end = get_item_pos(g.rec_item) + get_item_len(g.rec_item)
        if pos < rec_end + POST_ROLL then
          td.current = i
          break
        end
        -- Past this group entirely — mark it as already done
        if i == #td.groups then
          td.current = i
          td.exported = true
        end
      end
    end
  end

  -- During playback: advance groups and trigger exports
  if play_state > 0 then
    local pos = reaper.GetPlayPosition()
    for track, td in pairs(track_data) do
      if reaper.GetMediaTrackInfo_Value(track, "B_MUTE") == 1 then goto next_track end

      local group = td.groups[td.current]
      if not group then goto next_track end

      -- Clear old audio when entering current group's rec region
      if not td.cleared then
        local rec_start = get_item_pos(group.rec_item)
        if pos >= rec_start - PRE_ROLL then
          clear_group_audio(group)
          td.cleared = true
        end
      end

      -- Check if we need to advance to the next group
      local next_group = td.groups[td.current + 1]
      if next_group and not td.exported then
        local next_rec_start = get_item_pos(next_group.rec_item)
        -- Export before the next rec region starts (give some lead time)
        if pos >= next_rec_start - PRE_ROLL - 0.5 then
          local track_idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") - 1
          local buf_len = reaper.gmem_read(10 + track_idx)
          if buf_len > 0 then
            queue_export(group, track)
          end
          td.exported = true
        end
      end

      -- Actually advance when playhead reaches next rec region
      if next_group then
        local next_rec_start = get_item_pos(next_group.rec_item)
        if pos >= next_rec_start - PRE_ROLL then
          td.current = td.current + 1
          td.exported = false
          td.cleared = false
          -- Clear the new group's old audio
          clear_group_audio(next_group)
          td.cleared = true
        end
      end

      ::next_track::
    end
  end

  -- Auto-export when transport stops
  if last_play_state > 0 and play_state == 0 then
    for track, td in pairs(track_data) do
      if reaper.GetMediaTrackInfo_Value(track, "B_MUTE") == 1 then goto skip end
      if td.exported then goto skip end
      local group = td.groups[td.current]
      if not group then goto skip end
      local track_idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") - 1
      local buf_len = reaper.gmem_read(10 + track_idx)
      if buf_len > 0 then
        queue_export(group, track)
        td.exported = true
      end
      ::skip::
    end
  end

  last_play_state = play_state

  write_gmem()
  process_export()
  reaper.defer(looper_tick)
end

-- ─── Actions ─────────────────────────────────────────────────────────────────

local function get_one_measure_seconds()
  local _, bpi = reaper.GetProjectTimeSignature2(0)
  local tempo = reaper.Master_GetTempo()
  return (60 / tempo) * bpi
end

local function create_midi_item(track, position, length, name, color)
  local item = reaper.CreateNewMIDIItemInProj(track, position, position + length)
  if not item then return nil end
  local take = reaper.GetActiveTake(item)
  if take then
    reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", name, true)
  end
  local native = reaper.ColorToNative(
    (color >> 16) & 0xFF,
    (color >> 8) & 0xFF,
    color & 0xFF
  )
  reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", native | 0x01000000)
  reaper.UpdateArrange()
  return item
end

local function action_add_rec()
  local track = reaper.GetSelectedTrack(0, 0)
  if not track then
    reaper.ShowMessageBox("Select a track first.", SCRIPT_NAME, 0)
    return
  end
  create_midi_item(track, reaper.GetCursorPosition(), get_one_measure_seconds(), "rec", 0xFF0000)
  scan_all_tracks()
end

local function action_add_play()
  local track = reaper.GetSelectedTrack(0, 0)
  if not track then
    reaper.ShowMessageBox("Select a track first.", SCRIPT_NAME, 0)
    return
  end
  create_midi_item(track, reaper.GetCursorPosition(), get_one_measure_seconds(), "play", 0x00FF00)
  scan_all_tracks()
end

-- ─── ImGui interface ─────────────────────────────────────────────────────────

local ctx = reaper.ImGui_CreateContext(SCRIPT_NAME)
local font = reaper.ImGui_CreateFont("sans-serif", 14)
reaper.ImGui_Attach(ctx, font)

local function imgui_loop()
  reaper.ImGui_PushFont(ctx, font)
  local visible, open = reaper.ImGui_Begin(ctx, SCRIPT_NAME, true)

  if visible then
    if reaper.ImGui_Button(ctx, "Add Rec Clip") then
      action_add_rec()
    end

    reaper.ImGui_SameLine(ctx)

    if reaper.ImGui_Button(ctx, "Add Play Clip") then
      action_add_play()
    end

    reaper.ImGui_SameLine(ctx)

    if reaper.ImGui_Button(ctx, bypassed and "Resume" or "Bypass") then
      bypassed = not bypassed
    end

    local has_tracks = false
    for _ in pairs(track_data) do has_tracks = true; break end

    if has_tracks then
      reaper.ImGui_Separator(ctx)
      local exporting = pending_export or #export_queue > 0

      for track, td in pairs(track_data) do
        local _, track_name = reaper.GetTrackName(track)
        local track_idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") - 1
        local buf_frames = reaper.gmem_read(10 + track_idx)
        local srate = reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)
        if srate == 0 then srate = 44100 end

        local group = td.groups[td.current]
        if group then
          if buf_frames > 0 then
            reaper.ImGui_Text(ctx, string.format("%s [%d/%d]: %.1fs",
              track_name, td.current, #td.groups, buf_frames / srate))
            reaper.ImGui_SameLine(ctx)
            if not exporting and reaper.ImGui_SmallButton(ctx, "Export##" .. track_idx) then
              queue_export(group, track)
              td.exported = true
            end
          else
            reaper.ImGui_TextDisabled(ctx, string.format("%s [%d/%d]: empty",
              track_name, td.current, #td.groups))
          end
        end
      end

      if exporting then
        reaper.ImGui_Separator(ctx)
        reaper.ImGui_Text(ctx, "Exporting...")
      end
    end

    reaper.ImGui_End(ctx)
  end

  reaper.ImGui_PopFont(ctx)

  if open then
    reaper.defer(imgui_loop)
  else
    script_running = false
    remove_all_jsfx()
  end
end

-- ─── Start ───────────────────────────────────────────────────────────────────

reaper.atexit(function()
  remove_all_jsfx()
end)

remove_all_jsfx()
scan_all_tracks()
ensure_jsfx_on_tracks()
reaper.defer(looper_tick)
reaper.defer(imgui_loop)
