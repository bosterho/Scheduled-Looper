-- Scheduled Looper
-- A background script that turns REAPER's timeline into a scheduled live looper.
-- Requires ReaImGui extension.

local reaper = reaper
local SCRIPT_NAME = "Scheduled Looper"
local PRE_ROLL = 0.1       -- seconds to start recording before rec region

-- ─── State ───────────────────────────────────────────────────────────────────

local script_running = true
local bypassed = false
local groups = {}          -- built from scanning tracks
local prev_play_pos = -1   -- playhead position last cycle (in beats)
local last_scan_time = 0
local SCAN_INTERVAL = 1.0  -- rescan tracks every 1 second

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

local function get_item_pos_beats(item)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local _, _, _, fullbeats = reaper.TimeMap2_timeToBeats(0, pos)
  return fullbeats
end

local function get_item_end_beats(item)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local _, _, _, fullbeats = reaper.TimeMap2_timeToBeats(0, pos + len)
  return fullbeats
end

local function get_item_pos_time(item)
  return reaper.GetMediaItemInfo_Value(item, "D_POSITION")
end

local function get_item_len_time(item)
  return reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
end

local function is_midi_item(item)
  local take = reaper.GetActiveTake(item)
  if not take then return false end
  return reaper.TakeIsMIDI(take)
end


-- ─── Recording control ──────────────────────────────────────────────────────

local function arm_track(track)
  reaper.SetMediaTrackInfo_Value(track, "I_RECARM", 1)
end

local function disarm_track(track)
  reaper.SetMediaTrackInfo_Value(track, "I_RECARM", 0)
end

-- ─── Scanning & group building ───────────────────────────────────────────────

local function scan_track(track, audio_track)
  local track_groups = {}
  local items = {}

  -- Collect all rec/play MIDI items on this track
  local num_items = reaper.CountTrackMediaItems(track)
  for i = 0, num_items - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    if is_midi_item(item) then
      local name = get_item_name(item)
      if name == "rec" then
        items[#items + 1] = { item = item, type = "rec", pos = get_item_pos_beats(item) }
      elseif name == "play" then
        items[#items + 1] = { item = item, type = "play", pos = get_item_pos_beats(item) }
      end
    end
  end

  -- Sort by timeline position
  table.sort(items, function(a, b) return a.pos < b.pos end)

  -- Group: each rec starts a new group, plays attach to the current group
  local current_group = nil
  for _, entry in ipairs(items) do
    if entry.type == "rec" then
      current_group = {
        rec_item = entry.item,
        play_items = {},
        audio_item = nil,
        track = track,           -- control track (MIDI items)
        audio_track = audio_track, -- track below, for recording/playback
        was_inside_rec = false,
        play_regions_populated = false,
      }
      track_groups[#track_groups + 1] = current_group
    elseif entry.type == "play" and current_group then
      current_group.play_items[#current_group.play_items + 1] = entry.item
    end
    -- play items before any rec are ignored
  end

  return track_groups
end

local function scan_all_tracks()
  groups = {}


  local num_tracks = reaper.CountTracks(0)
  for i = 0, num_tracks - 1 do
    local track = reaper.GetTrack(0, i)
    -- Audio track is the track just below; skip if it doesn't exist
    local audio_track = (i + 1 < num_tracks) and reaper.GetTrack(0, i + 1) or nil
    local track_groups = scan_track(track, audio_track)
    if #track_groups > 0 and audio_track then
      for _, g in ipairs(track_groups) do
        groups[#groups + 1] = g
      end
      -- Disarm audio tracks so they don't accidentally record
      disarm_track(audio_track)

    end
  end
end

-- ─── WAV file detection (for pre-placement during recording) ────────────────

local function snapshot_wav_files()
  local path = reaper.GetProjectPath("")
  local files = {}
  local i = 0
  while true do
    local fn = reaper.EnumerateFiles(path, i)
    if not fn then break end
    if fn:lower():match("%.wav$") then
      files[fn] = true
    end
    i = i + 1
  end
  return files, path
end

local function find_new_wav(dir, snapshot)
  local i = 0
  while true do
    local fn = reaper.EnumerateFiles(dir, i)
    if not fn then break end
    if fn:lower():match("%.wav$") and not snapshot[fn] then
      return dir .. "/" .. fn
    end
    i = i + 1
  end
  return nil
end

-- ─── Play region population ──────────────────────────────────────────────────

local function find_audio_items_under(track, play_item)
  -- Find non-MIDI items that overlap the play item's position/length
  local p_pos = get_item_pos_time(play_item)
  local p_end = p_pos + get_item_len_time(play_item)
  local found = {}

  local num_items = reaper.CountTrackMediaItems(track)
  for i = 0, num_items - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    if not is_midi_item(item) then
      local i_pos = get_item_pos_time(item)
      local i_end = i_pos + get_item_len_time(item)
      -- Check overlap
      if i_pos < p_end and i_end > p_pos then
        found[#found + 1] = item
      end
    end
  end
  return found
end


-- Pre-place into play regions from a WAV file path (during recording, before MediaItem exists)
local function populate_play_regions_from_file(group, wav_path)
  local rec_len = get_item_len_time(group.rec_item)
  local rec_start = get_item_pos_time(group.rec_item)
  local pre_roll_offset = group.actual_rec_start and (rec_start - group.actual_rec_start) or PRE_ROLL
  if pre_roll_offset < 0 then pre_roll_offset = 0 end

  reaper.PreventUIRefresh(1)

  for _, play_item in ipairs(group.play_items) do
    if not is_item_muted(play_item) then
      local play_pos = get_item_pos_time(play_item)
      local play_len = get_item_len_time(play_item)
      local play_end = play_pos + play_len

      -- Delete old audio under this play region
      local old_items = find_audio_items_under(group.audio_track, play_item)
      for j = #old_items, 1, -1 do
        reaper.DeleteTrackMediaItem(group.audio_track, old_items[j])
      end

      local n_copies = math.ceil(play_len / rec_len)

      for i = 0, n_copies - 1 do
        local grid_pos = play_pos + i * rec_len
        local copy_pos = grid_pos
        local remaining = play_end - grid_pos
        local copy_len = math.min(rec_len, remaining)
        local copy_offset = pre_roll_offset
        local snap_offset = 0

        if pre_roll_offset > 0 then
          copy_pos = copy_pos - pre_roll_offset
          copy_len = copy_len + pre_roll_offset
          copy_offset = 0
          snap_offset = pre_roll_offset
        end

        -- Extend slightly past play region end with fade-out to prevent click
        copy_len = copy_len + pre_roll_offset

        local new_item = reaper.AddMediaItemToTrack(group.audio_track)
        local new_take = reaper.AddTakeToMediaItem(new_item)
        local new_source = reaper.PCM_Source_CreateFromFile(wav_path)
        reaper.SetMediaItemTake_Source(new_take, new_source)
        reaper.SetMediaItemTakeInfo_Value(new_take, "D_STARTOFFS", copy_offset)

        reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", copy_pos)
        reaper.SetMediaItemInfo_Value(new_item, "D_LENGTH", copy_len)
        reaper.SetMediaItemInfo_Value(new_item, "D_SNAPOFFSET", snap_offset)
        reaper.SetMediaItemInfo_Value(new_item, "D_FADEINLEN", pre_roll_offset)
        reaper.SetMediaItemInfo_Value(new_item, "D_FADEOUTLEN", pre_roll_offset)
      end
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
end


-- ─── Main loop ───────────────────────────────────────────────────────────────

local function looper_tick()
  if not script_running then return end

  -- Periodic rescan: pick up added/removed/moved clips (only when not mid-recording)
  local now = reaper.time_precise()
  if now - last_scan_time >= SCAN_INTERVAL then
    local any_active = false
    for _, group in ipairs(groups) do
      if group.was_inside_rec or group.pending_populate_tick or group.pending_play_update then
        any_active = true
        break
      end
    end
    if not any_active then
      scan_all_tracks()
      last_scan_time = now
    end
  end

  -- Skip processing when bypassed
  if bypassed then
    reaper.defer(looper_tick)
    return
  end

  local play_state = reaper.GetPlayState()
  -- Only run when playing or recording (1=play, 5=play+record, 4=record)
  if play_state == 0 then
    prev_play_pos = -1
    reaper.defer(looper_tick)
    return
  end

  local _, _, _, play_pos = reaper.TimeMap2_timeToBeats(0, reaper.GetPlayPosition())

  for _, group in ipairs(groups) do
    if not is_item_muted(group.rec_item) then
      local rec_start = get_item_pos_beats(group.rec_item)
      local rec_end = get_item_end_beats(group.rec_item)

      -- Pre-roll: convert PRE_ROLL seconds to beats at current tempo
      local pre_roll_beats = PRE_ROLL * (reaper.Master_GetTempo() / 60)
      local trigger_start = rec_start - pre_roll_beats

      local is_in_pre_or_rec = play_pos >= trigger_start and play_pos < rec_end
      local was_active = group.was_inside_rec

      -- Just entered pre-roll zone: clean up rec region only, then arm + start recording
      -- Play region audio is left in place until populate replaces it
      if is_in_pre_or_rec and not was_active then
        reaper.PreventUIRefresh(1)
        local rec_audio = find_audio_items_under(group.audio_track, group.rec_item)
        for j = #rec_audio, 1, -1 do
          reaper.DeleteTrackMediaItem(group.audio_track, rec_audio[j])
        end
        group.audio_item = nil
        reaper.PreventUIRefresh(-1)
        reaper.UpdateArrange()

        group.play_regions_populated = false
        group.wav_snapshot, group.rec_dir = snapshot_wav_files()
        group.wav_found = nil
        group.actual_rec_start = reaper.GetPlayPosition()  -- capture actual recording start time
        arm_track(group.audio_track)
        if reaper.GetPlayState() == 1 then
          reaper.Main_OnCommand(1013, 0) -- Transport: Record
        end
      end

      -- While recording: scan filesystem for the new WAV file and pre-place
      if is_in_pre_or_rec and not group.play_regions_populated and group.wav_snapshot then
        if not group.wav_found then
          group.wav_found = find_new_wav(group.rec_dir, group.wav_snapshot)
        end
        if group.wav_found then
          populate_play_regions_from_file(group, group.wav_found)
          group.play_regions_populated = true
        end
      end

      -- Just exited rec region: stop recording + disarm
      if was_active and not is_in_pre_or_rec then
        if reaper.GetPlayState() & 4 ~= 0 then
          reaper.Main_OnCommand(1013, 0) -- Transport: Record (toggles off)
        end
        disarm_track(group.audio_track)
        -- Schedule re-populate with final post-roll measurements
        group.pending_populate_tick = 0
      end

      -- Phase 1: find recording item (safe, read-only + rec item fades)
      if group.pending_populate_tick then
        group.pending_populate_tick = group.pending_populate_tick + 1
        if group.pending_populate_tick >= 3 then
          local rec_item_audio = find_audio_items_under(group.audio_track, group.rec_item)
          local new_item = nil
          for _, item in ipairs(rec_item_audio) do
            if not is_midi_item(item) then
              new_item = item
              break
            end
          end

          if new_item then
            local audio_start = get_item_pos_time(new_item)
            local audio_len = get_item_len_time(new_item)
            local rec_start_time = get_item_pos_time(group.rec_item)
            local rec_len_time = get_item_len_time(group.rec_item)
            local pre_roll_offset = rec_start_time - audio_start
            if pre_roll_offset < 0 then pre_roll_offset = 0 end
            local post_roll = (audio_start + audio_len) - (rec_start_time + rec_len_time)
            if post_roll < 0 then post_roll = 0 end

            -- Set fades on the recording item itself (not playing, safe to modify)
            if pre_roll_offset > 0 then
              reaper.SetMediaItemInfo_Value(new_item, "D_SNAPOFFSET", pre_roll_offset)
              reaper.SetMediaItemInfo_Value(new_item, "D_FADEINLEN", pre_roll_offset)
            end
            if post_roll > 0 then
              reaper.SetMediaItemInfo_Value(new_item, "D_FADEOUTLEN", post_roll)
            end
            group.audio_item = new_item
            group.pending_play_update = true  -- schedule play region update
            group.pending_populate_tick = nil
          elseif group.pending_populate_tick > 200 then
            group.pending_populate_tick = nil
          end
        end
      end

      -- Phase 2: update play region items only when playhead is clear
      if group.pending_play_update and group.audio_item
         and reaper.ValidatePtr(group.audio_item, "MediaItem*")
         and reaper.ValidatePtr(group.rec_item, "MediaItem*") then
        local cur_time = reaper.GetPlayPosition()
        local playhead_clear = true
        for _, play_item in ipairs(group.play_items) do
          if not reaper.ValidatePtr(play_item, "MediaItem*") then
            group.pending_play_update = nil
            playhead_clear = false
            break
          end
          local ps = get_item_pos_time(play_item)
          local pe = ps + get_item_len_time(play_item) + PRE_ROLL
          if cur_time >= ps and cur_time < pe then
            playhead_clear = false
            break
          end
        end
        if playhead_clear then
          local rec_start_time = get_item_pos_time(group.rec_item)
          local rec_len_time = get_item_len_time(group.rec_item)
          local audio_start = get_item_pos_time(group.audio_item)
          local audio_len = get_item_len_time(group.audio_item)
          local pre_roll_offset = rec_start_time - audio_start
          if pre_roll_offset < 0 then pre_roll_offset = 0 end
          local post_roll = (audio_start + audio_len) - (rec_start_time + rec_len_time)
          if post_roll < 0 then post_roll = 0 end

          local src_take = reaper.GetActiveTake(group.audio_item)
          local src_source = src_take and reaper.GetMediaItemTake_Source(src_take)
          local src_filename = src_source and reaper.GetMediaSourceFileName(src_source)
          local src_offset = src_take and reaper.GetMediaItemTakeInfo_Value(src_take, "D_STARTOFFS") or 0

          if src_filename then
            reaper.PreventUIRefresh(1)
            for _, play_item in ipairs(group.play_items) do
              if not is_item_muted(play_item) then
                local play_pos = get_item_pos_time(play_item)
                local play_len = get_item_len_time(play_item)
                local play_end = play_pos + play_len

                -- Delete old pre-placed items
                local old_items = find_audio_items_under(group.audio_track, play_item)
                for j = #old_items, 1, -1 do
                  if old_items[j] ~= group.audio_item then
                    reaper.DeleteTrackMediaItem(group.audio_track, old_items[j])
                  end
                end

                -- Create exact copies
                local n_copies = math.ceil(play_len / rec_len_time)
                for i = 0, n_copies - 1 do
                  local grid_pos = play_pos + i * rec_len_time
                  local remaining = play_end - grid_pos
                  local base_len = math.min(rec_len_time, remaining)
                  local copy_pos = grid_pos - pre_roll_offset
                  local copy_len = base_len + pre_roll_offset + post_roll
                  local copy_offset = src_offset

                  local new_item = reaper.AddMediaItemToTrack(group.audio_track)
                  local new_take = reaper.AddTakeToMediaItem(new_item)
                  local new_source = reaper.PCM_Source_CreateFromFile(src_filename)
                  reaper.SetMediaItemTake_Source(new_take, new_source)
                  reaper.SetMediaItemTakeInfo_Value(new_take, "D_STARTOFFS", copy_offset)
                  reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", copy_pos)
                  reaper.SetMediaItemInfo_Value(new_item, "D_LENGTH", copy_len)
                  reaper.SetMediaItemInfo_Value(new_item, "D_SNAPOFFSET", pre_roll_offset)
                  reaper.SetMediaItemInfo_Value(new_item, "D_FADEINLEN", pre_roll_offset)
                  reaper.SetMediaItemInfo_Value(new_item, "D_FADEOUTLEN", post_roll)
                end
              end
            end
            reaper.PreventUIRefresh(-1)
            reaper.UpdateArrange()
          end
          group.pending_play_update = nil
        end
      end

      group.was_inside_rec = is_in_pre_or_rec
    end
  end

  prev_play_pos = play_pos
  reaper.defer(looper_tick)
end

-- ─── Actions ─────────────────────────────────────────────────────────────────

local function get_one_measure_seconds()
  local _, bpi = reaper.GetProjectTimeSignature2(0)
  local tempo = reaper.Master_GetTempo()
  return (60 / tempo) * bpi
end

local function create_midi_item(track, position, length, name, color)
  local end_pos = position + length
  local item = reaper.CreateNewMIDIItemInProj(track, position, end_pos)
  if not item then return nil end

  local take = reaper.GetActiveTake(item)
  if take then
    reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", name, true)
  end

  -- Set color (native + custom flag)
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

  local cursor = reaper.GetCursorPosition()
  create_midi_item(track, cursor, get_one_measure_seconds(), "rec", 0xFF0000)
  scan_all_tracks()
end

local function action_add_play()
  local track = reaper.GetSelectedTrack(0, 0)
  if not track then
    reaper.ShowMessageBox("Select a track first.", SCRIPT_NAME, 0)
    return
  end

  local cursor = reaper.GetCursorPosition()
  create_midi_item(track, cursor, get_one_measure_seconds(), "play", 0x00FF00)
  scan_all_tracks()
end

local function action_clear_slot()
  local track = reaper.GetSelectedTrack(0, 0)
  if not track then
    reaper.ShowMessageBox("Select a track first.", SCRIPT_NAME, 0)
    return
  end

  reaper.PreventUIRefresh(1)

  for _, group in ipairs(groups) do
    if group.track == track then
      for _, play_item in ipairs(group.play_items) do
        local old_items = find_audio_items_under(group.audio_track, play_item)
        for j = #old_items, 1, -1 do
          reaper.DeleteTrackMediaItem(group.audio_track, old_items[j])
        end
      end
      group.audio_item = nil
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
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

    if reaper.ImGui_Button(ctx, "Clear Slot") then
      action_clear_slot()
    end

    reaper.ImGui_SameLine(ctx)

    if reaper.ImGui_Button(ctx, bypassed and "Resume" or "Bypass") then
      bypassed = not bypassed
    end

    -- Show group info
    if #groups > 0 then
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_Text(ctx, string.format("%d group(s) active", #groups))
    end

    reaper.ImGui_End(ctx)
  end

  reaper.ImGui_PopFont(ctx)

  if open then
    reaper.defer(imgui_loop)
  else
    script_running = false
  end
end

-- ─── Entry point ─────────────────────────────────────────────────────────────

scan_all_tracks()
reaper.defer(looper_tick)
reaper.defer(imgui_loop)
