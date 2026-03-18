# Ostertoaster Timeline Looper

A live looper for REAPER that puts your recordings directly on the timeline as audio items, so you can edit and arrange them after recording.

## TL;DR

1. Install the script and run it from Actions
2. Place red "rec" clips and green "play" clips on a track as MIDI items
3. Hit Record - when the playhead crosses a rec clip it records, when it crosses a play clip it loops what was recorded
4. Audio appears on the timeline as items you can move, edit, and arrange
5. Add take FX to play clips and they'll be heard during live playback AND copied to exported items
6. Crossfade slider on the TCP controls seamless loop transitions

## Install

1. Install [ReaImGui](https://forum.cockos.com/showthread.php?t=250419) if you don't have it
2. Install [js_ReaScriptAPI](https://forum.cockos.com/showthread.php?t=212174) (recommended, for smooth FX editing)
3. Extensions > ReaPack > Import repositories
4. Paste: `https://raw.githubusercontent.com/bosterho/Timeline-Looper/main/index.xml`
5. Extensions > ReaPack > Browse packages > find "Ostertoaster Timeline Looper" > Install
6. The script appears under Actions > "Ostertoaster Timeline Looper"

## How It Works

### Concept

Traditional loopers hide your audio inside a plugin. This looper uses the REAPER timeline itself: you define where to record and where to loop using MIDI items as visual markers, and everything you record gets exported as real audio items you can see, edit, slice, and rearrange.

### Clips

- **Rec clips** (red/muted-pink MIDI items named "rec"): define where the looper records incoming audio
- **Play clips** (green MIDI items named "play"): define where the recorded audio loops back

Clips are organized into **groups**: each rec clip starts a new group, and subsequent play clips belong to that group until the next rec clip appears. A group represents one recording pass and all the places it loops.

### Recording and Playback Flow

1. Press Record in REAPER (the looper requires REAPER's transport to be in record mode)
2. As the playhead enters a rec clip, the JSFX captures incoming audio into an internal buffer
3. As the playhead enters a play clip, the JSFX plays back the buffer in a loop with crossfading
4. If a play clip is longer than the recorded audio, the buffer loops seamlessly
5. When the playhead reaches the next rec clip, the Lua script swaps buffers (double-buffering) so the old recording continues playing while the new one records
6. After each recording finishes, the buffer is exported as an audio item on the Audio track below

### Double Buffering

The JSFX uses two audio buffers (A and B). While one buffer records the current group, the other holds the previous group's audio for playback. The Lua script manages buffer swapping:

- On advance to next group: swap the rec buffer, keep the play buffer
- When all play clips from the old group finish: switch the play buffer to match the new rec buffer

This ensures playback is never interrupted during recording.

### Track Architecture

When the script starts, it creates a folder structure for each looper track:

```
Parent Track (volume/pan/effects for the whole looper)
  JSFX Track (rec/play MIDI items + Timeline Looper JSFX + mirrored FX)
  Audio Track (exported audio items)
```

The script also creates a **Mic track** at the top of the project:
- Has the Timeline Looper Input JSFX which captures mic input via gmem
- Armed for monitoring (not recording to disk)
- Master send disabled (you monitor via your audio interface's direct monitoring)

### Crossfade

Each JSFX instance has a crossfade slider (5-1000ms) visible on the TCP. This controls:
- Pre-roll: how much audio before the rec/play region boundaries is captured
- Post-roll: how much audio after boundaries is captured
- Fade-in/fade-out lengths on exported audio items
- Loop iteration crossfade (when play clips loop the buffer)

The crossfade value is persisted per track in the project's ExtState.

## Features

### Take Envelopes (Volume and Pan)

Add volume or pan envelopes directly on play clip takes (the MIDI items). These are:
- Applied in real-time during JSFX playback via linear interpolation
- Copied to exported audio items with proper time-slicing for looped copies
- Scaled by playrate so they stretch correctly when play clips have non-1.0 rates

Pan uses REAPER's stereo balance law: `L *= min(1, 1+pan)`, `R *= min(1, 1-pan)`.

### Take FX (Item Effects)

Add any FX to play clip takes (right-click item > Take FX). The looper:

1. **Mirrors FX to the track chain**: copies take FX as track FX after the JSFX, one set per play clip
2. **Multi-channel routing**: JSFX outputs each clip on its own stereo channel pair, mirrored FX process only their clip's channels via pin mappings, a summing JSFX folds everything back to stereo
3. **Dynamic bypass**: FX are bypassed when their clip isn't active, unbypassed 0.5s before the clip starts (to avoid clicks)
4. **Parameter sync**: take FX parameter values are synced to mirrored track FX every scan cycle (~1s), deferred while mouse is held for smooth editing
5. **FX parameter envelopes**: automation on take FX parameters is copied to hidden track FX envelopes, time-shifted to match clip positions
6. **Exported items**: take FX and their parameter envelopes are copied to exported audio items, with envelope slicing for looped copies

The FX chain structure on the JSFX track when take FX are present:
```
[0] Timeline Looper JSFX (outputs per-clip stereo pairs)
[1] Mirrored FX for play clip 1 (pin-mapped to ch 0-1)
[2] Mirrored FX for play clip 2 (pin-mapped to ch 2-3)
[3] Mirrored FX for play clip 3 (pin-mapped to ch 4-5)
... up to 8 clips
[N] Timeline Looper Sum (sums ch 2-15 into ch 0-1)
```

When no play clips have take FX, the track stays at 2 channels with just the JSFX (no overhead).

### Playrate

Change a play clip's take playrate to speed up or slow down playback:
- JSFX uses fractional buffer indexing with linear interpolation for smooth pitch shifting
- Loop iteration length scales with playrate
- Crossfade boundaries are adjusted
- Exported items get matching playrate with "Preserve pitch" disabled (since the JSFX can't pitch-stretch)
- Take envelopes scale correctly with playrate

### Reverse Playback

Name a play clip "play rev" (or anything containing both "play" and "rev") to reverse playback. The buffer reads backwards. Exported items are reversed using REAPER's take reverse.

### Muting and Solo

- Muting a rec clip skips recording for that group
- Muting a play clip skips playback for that clip
- Track mute/solo is respected via `is_track_silenced()`

### Audio Export

When enabled (checkbox in the UI), recorded audio is exported to the Audio track:
- Export triggers after the rec region + crossfade + PDC delay have passed
- Exported items are placed incrementally as the playhead passes each clip
- Remaining items are placed when transport stops
- Each exported item gets: correct position, length, crossfade, snap offset, playrate, take envelopes, take FX, and FX parameter envelopes
- Looped play clips get multiple audio items with item grouping and time-sliced envelopes

### Auto-Start

The script installs a startup hook so it automatically runs when you reopen the project (if it was running when you last saved). This can be disabled by closing the script window before saving.

## Plugin Delay Compensation (PDC)

If you add latency-inducing FX after the JSFX on the track chain (or on parent tracks), the looper compensates:

- **Recording**: buffer write position is shifted back by PDC so content aligns with real transport time
- **Playback**: raw `play_position` is used (already PDC-ahead), downstream FX delay cancels it out
- **Export timing**: Lua waits extra PDC time before triggering export since the JSFX finishes recording late
- PDC is recomputed on each rescan (~1s) by summing PDC from all FX after the JSFX and up the parent chain

## UI

The script opens a small ReaImGui window with:
- Status indicator (Recording / Idle)
- Refresh button (re-scans tracks and re-adds JSFX after adding new rec/play clips)
- Export audio checkbox

Keyboard shortcuts are forwarded to REAPER when the window has focus (Space = play/stop, Home/End = go to start/end).

## Cleanup

When the script exits (close the window or toggle the action off):
- Mirrored FX and summing JSFX are removed from all JSFX tracks
- Track channel counts reset to 2
- Input JSFX removed from the Mic track
- Mic track disarmed and monitoring disabled
- All JSFX instances removed

The Mic track itself is preserved and identified by GUID on next startup, so it won't be duplicated.

## Files

| File | Purpose |
|------|---------|
| `Ostertoaster_Timeline Looper.lua` | Main Lua companion script (scanning, gmem, exports, FX mirroring, ImGui UI) |
| `Timeline Looper.jsfx` | JSFX plugin for real-time audio capture and playback with crossfading |
| `Timeline Looper Input.jsfx` | Input capture JSFX for the Mic track (writes audio to gmem) |
| `Timeline Looper Sum.jsfx` | Channel summing JSFX (folds multi-channel per-clip output to stereo) |

The Lua script auto-syncs all JSFX files from the Scripts folder to `Effects/Ostertoaster/` on startup.

## Technical Details

### gmem Layout

The JSFX and Lua communicate via named shared memory (`timeline_looper`):

| Slot | Purpose |
|------|---------|
| `[0]` | Export trigger (track_index + 1, 0 = none) |
| `[1]` | Export target track index |
| `[100 + idx]` | Rec buffer: main frames feedback |
| `[200 + idx]` | Crossfade duration (seconds) |
| `[300 + idx]` | Rec buffer: pre-roll frame count |
| `[400 + idx]` | Rec buffer index (0=A, 1=B) |
| `[500 + idx]` | Play buffer index (0=A, 1=B) |
| `[600 + idx]` | Export buffer index (0=A, 1=B) |
| `[700 + idx]` | Play buffer: main frames |
| `[800 + idx]` | Play buffer: pre-roll frame count |
| `[900 + idx]` | PDC offset (samples, from Lua) |
| `[950 + idx]` | Multi-channel mode (1 = per-clip channels, 0 = mix) |
| `[1000 + idx*100]` | Per-track rec/play region data (start, end, flags, playrate per clip) |
| `[5000 + idx*200 + clip*9]` | Volume envelope points per play clip (up to 4 points) |
| `[7000 + idx*200 + clip*9]` | Pan envelope points per play clip (up to 4 points) |

### JSFX Internals

- **Buffer layout**: BUF_A at offset 0, BUF_B at offset BUF_STRIDE (stereo interleaved, up to ~41s at 48kHz)
- **State tracking**: ST_A/ST_B store per-buffer state (total length, write position, pre-roll length, main length, flags)
- **@block**: caches all gmem data to prevent mid-block race conditions with Lua
- **@sample**: recording writes to rec buffer with PDC correction; playback reads from play buffer with crossfading, envelope application, and per-clip channel output
- **@gfx**: handles export trigger (calls `export_buffer_to_project`) and displays status
- **Multi-channel**: when `multichan` flag is set, each play clip outputs to its own stereo pair (spl0-1, spl2-3, etc.); otherwise all clips mix to spl0-1

### Lua Script Structure

- **Startup**: syncs JSFX files, removes old instances, scans tracks, creates starter clips if needed, sets up Mic track and JSFX instances
- **Scan** (~1s interval): validates items, rescans tracks, persists crossfade values, computes PDC, syncs FX containers and parameters
- **Tick** (~30Hz): detects record transitions, manages group advancement, buffer swapping, export queuing/processing, incremental audio placement, FX bypass toggling
- **FX mirroring**: structural changes (add/remove FX) trigger full rebuild; parameter changes sync via `TrackFX_SetParam`; envelope changes detected via hashing
- **Export pipeline**: queue > wait for JSFX export > find exported item > compute params > place rec audio > place play audio (with looping, crossfade, envelopes, FX)
