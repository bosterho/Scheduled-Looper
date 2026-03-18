# Ostertoaster Timeline Looper

A live looper for REAPER that puts your recordings directly on the timeline as audio items, so you can edit and arrange them after recording.

## TL;DR

1. Install the script and run it from Actions
2. Place red "rec" clips and green "play" clips on a track as MIDI items
3. Hit Record — when the playhead crosses a rec clip it records, when it crosses a play clip it loops what was recorded
4. Audio appears on the timeline as items you can move, edit, and arrange
5. Add take FX to play clips and they'll be heard during live playback AND copied to exported items
6. Crossfade slider on the TCP controls seamless loop transitions

## Install

1. Install [ReaImGui](https://forum.cockos.com/showthread.php?t=250419) if you don't have it
2. Install [js_ReaScriptAPI](https://forum.cockos.com/showthread.php?t=212174) (recommended, for smooth FX parameter editing)
3. Extensions > ReaPack > Import repositories
4. Paste: `https://raw.githubusercontent.com/bosterho/Timeline-Looper/main/index.xml`
5. Extensions > ReaPack > Browse packages > find "Ostertoaster Timeline Looper" > Install
6. The script appears under Actions > "Ostertoaster Timeline Looper"

## How It Works

### The Idea

Traditional loopers hide your audio inside a plugin. This looper uses the REAPER timeline itself — you define where to record and where to play back using colored MIDI items as visual markers, and everything you record gets exported as real audio items you can see, edit, slice, and rearrange.

### Clips and Groups

- **Rec clips** (pink/red MIDI items named "rec") — define where the looper captures incoming audio
- **Play clips** (green MIDI items named "play") — define where the recorded audio loops back

Clips are organized into **groups**: each rec clip starts a new group, and any play clips after it belong to that group until the next rec clip. Think of a group as "record this phrase, then loop it in these places."

**Example layout:**
```
|  rec  |  play  |  play  |  rec  |  play  |
|--group 1-------|--------|--group 2-------|
```

Group 1 records during the first rec clip, then loops that recording during both play clips. Group 2 records new audio and loops it in its own play clip.

### Recording and Playback

1. Hit Record in REAPER (the looper needs REAPER to be in record mode)
2. When the playhead enters a rec clip, the looper captures your audio input
3. When the playhead enters a play clip, you hear the recording looped back
4. If a play clip is longer than what was recorded, the audio loops seamlessly with crossfading
5. When the playhead reaches the next group's rec clip, the previous group's audio keeps playing while new audio records into a separate buffer (double-buffering)
6. After recording finishes, the audio is exported as items on the Audio track below

### Track Setup

When you first run the script, it automatically sets up:

- A **Mic track** at the top — this captures your audio input. It's armed for monitoring but doesn't record to disk. You hear yourself through your audio interface's direct monitoring, not through REAPER.
- A **folder structure** for each looper track:
  - **Parent track** — control volume/pan/effects for the whole looper
  - **JSFX track** — where your rec/play clips live, along with the looper plugin
  - **Audio track** — where exported audio items appear

If you already have a track with rec/play clips on it, the script wraps it in this folder structure automatically. If no clips exist, it creates starter rec and play clips at the cursor.

### First Time Use

1. Run the script — it creates a Mic track and starter clips on the selected track
2. Move the playhead to before the rec clip
3. Hit Record
4. Play or sing during the rec clip
5. Listen to it loop back during the play clip
6. Stop — your audio appears as items on the Audio track

### Adding More Clips

To add more rec/play clips to a track:
1. Create a new MIDI item (Insert > New MIDI item, or double-click in empty space)
2. Name it "rec" or "play" (right-click > Item properties, or F2)
3. Click the Refresh button in the looper window

You can have as many groups (rec + play sequences) as you want on a single track.

## Features

### Crossfade

Each looper track has a crossfade slider visible on the TCP (track control panel). This single control (5-1000ms) sets how smoothly audio transitions at boundaries:

- **At rec clip edges** — captures a bit of extra audio before and after the defined region
- **At loop points** — when a play clip loops the buffer, the end of one iteration crossfades into the start of the next
- **On exported items** — audio items get matching fade-in/fade-out lengths

**Use case:** Set a longer crossfade (200-500ms) for ambient/pad loops to get seamless transitions. Use a shorter crossfade (20-50ms) for rhythmic material where you want tight loop points.

### Take Volume and Pan Envelopes

You can draw volume and pan automation directly on the play clip's take envelopes.

**Use case — volume swell:** Draw a volume envelope that ramps from 0 to 1 over the first half of a play clip, creating a fade-in effect on your loop that you hear in real time and that gets baked into the exported audio.

**Use case — panning:** Draw a pan envelope that sweeps left to right over the duration of a play clip, creating stereo movement on your loop.

These envelopes:
- Are heard in real time during JSFX playback
- Are copied to exported audio items
- Scale correctly when you change the play clip's playrate
- Are properly sliced when the play clip is longer than the recording (each loop iteration gets its portion of the envelope)

### Take FX (Item Effects)

Add any FX directly to a play clip's take (right-click item > Take FX chain). The looper mirrors these FX onto the track so they're heard during live playback, not just on the exported audio.

**Use case — different reverb per section:** Put a short room reverb on one play clip and a long hall reverb on another. Each clip gets its own processing, and the FX automatically activate only when that clip is playing.

**Use case — filter sweep:** Add an EQ to a play clip, then draw an automation envelope on the EQ's frequency parameter. The filter sweep plays back in real time and gets copied to the exported audio.

**Use case — effect only on repeats:** Add a delay or distortion to a later play clip in the group. The first play clip loops clean, the second one loops with the effect.

How it works behind the scenes:
- The looper copies your take FX onto the JSFX track as regular track FX
- Each clip's FX are routed to only process that clip's audio (using multi-channel pin mapping)
- FX are bypassed when their clip isn't playing, and unbypassed just before the clip starts
- When you tweak a parameter on the take FX, the track FX updates to match (syncs on mouse-up so editing feels smooth)
- FX parameter automation envelopes are copied to hidden track envelopes so they affect live playback
- Everything — FX, parameters, and parameter envelopes — gets copied to the exported audio items too

### Playrate

Change a play clip's take playrate to speed up or slow down the loop.

**Use case — half-speed effect:** Set playrate to 0.5 on a play clip to hear your recording at half speed (one octave down), like a classic tape slow-down effect.

**Use case — double-time:** Set playrate to 2.0 to hear the recording at double speed for a chipmunk/glitch effect.

**Use case — subtle detune:** Set playrate to 0.99 or 1.01 for a subtle pitch-shifted layer when combined with a normal-speed play clip.

Playrate affects:
- Live playback pitch and speed (no time-stretching — pitch shifts proportionally)
- Loop iteration length (a 2x playrate means the buffer plays in half the time, so it loops twice as often)
- Exported audio items (they get the matching playrate with "Preserve pitch" off)
- Envelope timing (volume, pan, and FX envelopes all scale correctly)

### Reverse Playback

Name a play clip "play rev" (or anything containing both "play" and "rev") to play the recorded audio backwards.

**Use case — reverse reverb:** Record a note with reverb on the input, then play it back reversed for a reverse-reverb swell effect.

**Use case — ambient texture:** Combine a forward play clip and a reversed play clip of the same recording for layered ambient textures.

### Muting Clips

Mute any rec or play clip to skip it:

- **Muting a rec clip** — the looper doesn't record during that region. Useful for skipping a recording pass while keeping the arrangement structure.
- **Muting a play clip** — the looper doesn't play back during that region. Useful for silencing a loop in a specific section without deleting the clip.

Track-level mute and solo are also respected — if the track is muted or another track is soloed, the looper skips that track entirely.

### Audio Export

When the "Export audio" checkbox is enabled (default), recorded audio is placed as items on the Audio track:

- Items appear incrementally as the playhead passes each clip (you can see them being placed in real time)
- When you stop transport, any remaining items are placed immediately
- Each exported item gets all the properties from its source clip: position, length, crossfade, playrate, volume/pan envelopes, take FX, and FX parameter envelopes
- When a play clip loops the recording multiple times, each loop iteration becomes a separate audio item (grouped together for easy editing)

**Use case — arrangement building:** Record a chord progression, let it loop through several play clips across your song structure, then stop and rearrange the exported audio items to fine-tune the arrangement.

**Use case — offline editing:** Disable export while performing to keep things lightweight, then enable it and do one final pass to capture everything as audio.

### Multiple Looper Tracks

You can have rec/play clips on multiple tracks. Each track gets its own JSFX instance with independent recording, playback, and crossfade settings.

**Use case — multi-track looping:** Put rec/play clips on separate tracks for guitar, vocals, and keys. Each records and loops independently, but they're all synced to the same timeline positions.

### Plugin Delay Compensation (PDC)

If you add latency-inducing FX on the parent track or anywhere downstream of the JSFX, the looper automatically compensates. Recording, playback, and export timing all account for PDC so everything stays in sync.

**Use case — mixing while looping:** Add a compressor and EQ on the parent track to shape the overall sound. The looper adjusts its timing so the recorded audio lines up correctly despite the FX latency.

### Auto-Start

The script saves a startup hook so it automatically runs when you reopen the project (if it was running when you saved). Close the script window before saving to disable this.

## UI

The script opens a small window with:
- **Status indicator** — shows "RECORDING" (red) when transport is in record mode, "Idle" otherwise
- **Refresh button** — re-scans all tracks for rec/play clips and re-adds JSFX. Click this after adding new clips or tracks.
- **Export audio checkbox** — toggle whether recorded audio gets placed as items on the Audio track

Keyboard shortcuts work when the window has focus: Space (play/stop), Enter (play/stop), Home (go to start), End (go to end).

## Cleanup

When you close the script window (or toggle the action off), everything is cleaned up:
- All JSFX instances removed from tracks
- Mirrored FX removed
- Mic track disarmed and monitoring disabled, input JSFX removed
- Track channel counts reset

The Mic track itself is preserved — the script remembers it by GUID and reuses it on next startup. Your rec/play clips and exported audio items are untouched.

## Tips

- **Direct monitoring:** The Mic track has master send disabled. You should monitor your input through your audio interface's direct monitoring, not through REAPER's monitoring.
- **Crossfade sweet spot:** Start with the default 200ms crossfade. If you hear clicks at loop points, increase it. If loops feel sluggish, decrease it.
- **Long play clips:** A play clip can be any length — if it's longer than the recording, the audio loops seamlessly. Make a 1-bar recording and a 16-bar play clip for a sustained loop.
- **Offline FX tweaking:** Stop transport, click on a play clip's timeline position, and tweak its take FX. The looper activates that clip's FX at the cursor position so you can preview changes even when stopped.
- **Multiple play clips per group:** You can have several play clips after a single rec clip, each with different lengths, playrates, FX, or envelopes. They all loop the same recorded audio but process it differently.
