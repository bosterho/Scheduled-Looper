# Scheduled Looper

A Lua script for REAPER that turns the timeline into a scheduled live looper.

## What it does

You draw colored MIDI items on tracks to define when recording and playback should happen. A background Lua script watches the playhead and manages audio items accordingly. REAPER handles all recording and playback natively — no plugins required.

### The two rules

1. A **red** MIDI item named `rec` = record audio during that region
2. A **green** MIDI item named `play` = play back the recorded audio during that region

The inspiration is how Bink Beats uses Ableton: the loop architecture is designed ahead of time as a template, freeing the performer to focus entirely on playing. The same template can be performed multiple times, each time producing a different result.

---

## How it works

### Groups

The script sorts all `rec` and `play` MIDI items on a track by timeline position and groups them:

- Each `rec` item starts a new **group**
- All `play` items after a `rec` (and before the next `rec`) belong to that group
- If two `rec` items appear in a row with no `play` between them, the first rec's group has no play items — recording still happens, but nothing gets populated
- `play` items before the first `rec` on a track are ignored

A group has:

| Property      | Description                                              |
|---------------|----------------------------------------------------------|
| rec_item      | The red MIDI item defining the record region             |
| play_items    | Array of green MIDI items that belong to this rec        |
| audio_item    | Handle to the most recently recorded audio item          |

**Example:** a track with `rec, play, play, rec, play` produces two groups:
- Group 1: first rec + two plays
- Group 2: second rec + one play

Muted MIDI items are ignored by the script (see Mute behaviour below).

### Templates

A template is just the collection of MIDI items across your tracks. Saving the REAPER project saves the template. No separate file format needed.

---

## Script behaviour

### Startup

1. Register a defer loop that runs every cycle
2. Scan the project for looper tracks (identified by having red/green MIDI items following the naming convention)
3. Build groups from those items (sorted by position, grouped as described above)
4. Cache item counts per track for later diffing

### Main loop (runs every cycle)

For each group:

1. Get current playhead position in beats
2. If playhead **just entered** the `rec` region: arm the track for recording
3. If playhead **just exited** the `rec` region: disarm the track, then:
   - Diff item count on the track to find the newly created audio item
   - Populate this group's unmuted play regions (not other groups' play regions)

### Populating play regions

When a recording completes for a group:

For each **unmuted** green `play` item in **that group**:
1. Remove any existing audio item under that play item
2. Duplicate the new recording to the play item's position
3. Trim or extend to match the play item's length

### Length mismatch rules

| Situation                          | Behaviour                                        |
|------------------------------------|--------------------------------------------------|
| Play item shorter than recording   | Trim — play only the first N beats               |
| Play item longer than recording    | Audio plays to its end, remainder is silence      |

### Mute behaviour

Muting a MIDI item is how you disable it without deleting it:

- **Muted rec item**: the script ignores the record region entirely — no recording happens, existing audio in play regions is untouched
- **Muted play item**: the script skips that play region — won't place or remove audio there, preserving whatever is already in place

This replaces a dedicated lock system. The user just mutes/unmutes clips directly in REAPER, which is already a familiar workflow.

### Clear behaviour

- Removes audio items from all play regions on the track
- Resets buffer_state to `empty` and layer_count to 0
- Does **not** remove or modify `rec`/`play` MIDI items — the schedule is preserved

---

## Interface

A small ImGui window (via ReaImGui) provides all controls:

| Button                    | What it does                                                                                  |
|---------------------------|-----------------------------------------------------------------------------------------------|
| Add rec clip              | Creates a red MIDI item named `rec` at the edit cursor on the selected track (default 4 bars) |
| Add play clip             | Creates a green MIDI item named `play` at the edit cursor (length matches most recent rec)    |
| Clear slot                | Clears buffer, removes audio from play regions, preserves schedule                            |
| Start / Stop looper       | Toggles the background defer loop on and off                                                  |

The script launches the ImGui window on startup. The looper defer loop and the ImGui render loop run together.

## Quantization

All MIDI items snap to REAPER's grid. The script reads positions in beats directly from the API — no extra quantization logic needed. The user sets their grid resolution before drawing clips.

---

## Open questions

1. **Item detection**: Diffing item count is the proposed approach for finding newly recorded audio. Needs validation that REAPER always creates exactly one item per record pass.

2. **DAW loop behaviour**: If the project loops, rec and play clips re-trigger each iteration. This is desired. Confirm the defer loop handles transport loopback correctly.

---

## File structure

```
Scheduled Looper/
  looper.lua       -- main background script + toolbar actions
  SPEC.md          -- this file
```
