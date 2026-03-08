# Scheduled Looper

A live looper for REAPER that turns the timeline into a scheduled performance tool. Draw colored MIDI items to define when recording and playback happen — a companion JSFX plugin captures and plays back audio in real time with crossfading.

The inspiration is how Bink Beats uses Ableton: the loop architecture is designed ahead of time as a template, freeing the performer to focus entirely on playing. The same template can be performed multiple times, each time producing a different result.

## Installation

**Via ReaPack:**

1. Extensions > ReaPack > Import repositories
2. Paste: `https://raw.githubusercontent.com/bosterho/Scheduled-Looper/main/index.xml`
3. Extensions > ReaPack > Browse packages > find "Scheduled Looper" > Install

This installs the Lua script into Scripts and the JSFX plugin into Effects/Ostertoaster.

**Requirements:** [ReaImGui](https://forum.cockos.com/showthread.php?t=250419) (for the UI)

## How it works

### The two rules

1. A **red** MIDI item named `rec` = record audio during that region
2. A **green** MIDI item named `play` = play back the recorded audio during that region

### Groups

Items are sorted by position and grouped per track:

- Each `rec` item starts a new **group**
- All `play` items after a `rec` (and before the next `rec`) belong to that group
- `play` items before the first `rec` on a track are ignored

**Example:** `rec, play, play, rec, play` produces two groups:
- Group 1: first rec + two plays
- Group 2: second rec + one play

### Playback flow

1. When the playhead enters a `rec` region, the JSFX records incoming audio into a buffer
2. When the playhead reaches a `play` region, the JSFX plays back the buffer with crossfading
3. Audio items are exported to the timeline incrementally as the playhead passes each region
4. After stopping, any remaining regions are exported

### Double buffering

When multiple groups exist on a track, the JSFX uses two audio buffers (A and B). While one buffer plays back a previous recording, the other records new audio. This allows seamless rec-play-rec patterns without audio cutoff.

## Features

- **Crossfade control** — per-track crossfade slider (5ms to 1000ms), persisted in the project
- **Reverse playback** — name a play clip with `rev` (e.g., `play rev`) to play the recording in reverse
- **Mute clips** — mute individual rec or play MIDI items to disable them without deleting
- **Solo/mute tracks** — track mute and solo are respected
- **Automatic track setup** — the script configures record arm, monitor input, and audio input on managed tracks
- **Clean exit** — monitor input is turned off when the script closes

## Interface

A small ImGui window provides controls:

| Button | What it does |
|---|---|
| Add rec clip | Creates a red MIDI item named `rec` at the edit cursor (default 1 measure) |
| Add play clip | Creates a green MIDI item named `play` at the edit cursor (length matches most recent rec) |

The crossfade amount is controlled via the JSFX slider embedded in the track control panel.

## File structure

| File | Installed to | Description |
|---|---|---|
| `Ostertoaster_LooperJSFX.lua` | Scripts/ | Lua companion script — scans tracks, manages gmem, exports audio, ImGui UI |
| `scheduled_looper.jsfx` | Effects/Ostertoaster/ | JSFX plugin — real-time audio capture and playback with crossfading |
