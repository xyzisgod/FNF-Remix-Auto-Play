# Rhythm Battle AutoPlayer

Autoplayer for Rhythm Battle on Roblox. Rayfield UI, PC and mobile input, tap and long-note support.

Made with love 💖

## Features

- Rayfield UI with three tabs: Main, Timing, Keys
- Tap notes and long (hold) notes
- Live scroll-speed tracking per lane, no fixed speed needed
- Keyboard input on PC, multi-finger touch input on mobile
- Rebindable lane keys and toggle hotkey
- Every timing value adjustable with sliders
- Settings save and load automatically

## Install

Run in your executor:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/xyzisgod/FNF-Remix-Auto-Play/refs/heads/main/main.lua"))()
```

## Usage

1. Join a match.
2. Open the AutoPlayer window.
3. Turn on **Autoplay** (or press the toggle key, default `F6`).
4. Turn it off any time. All held keys release automatically.

## Tabs

### Main

| Control | What it does |
|---|---|
| Autoplay | Master on/off switch |
| Toggle key | Hotkey for Autoplay (default `F6`, PC only) |
| Input mode | `Auto`, `Keyboard` or `Touch` |
| Touch method | `Touch` (multi-finger) or `Mouse` (single pointer fallback) |
| Tap X / Y offset | Shifts the tap point from the lane receptor center |
| Release all keys | Releases every held lane |
| Unload | Stops the script and closes the UI |

### Timing

| Slider | What it does |
|---|---|
| Hit offset | Moves the hit line in pixels. Raise or lower if hits land early or late |
| Tail offset | Same, for the release point of long notes |
| Input latency | Compensates for input delay, in ms |
| Late window | How long after the line a note can still be hit, in ms |
| Tap duration | How long a tap key or touch is held, in ms |
| Lookahead | How far ahead notes are tracked, in seconds |
| Min lookahead | Lower bound on lookahead, in pixels |
| Long note min length | Notes shorter than this count as taps |
| Max hold time | Safety cap on any single hold, in seconds |

### Keys

Rebind the four lane keys. Defaults: `A` `S` `W` `D`.

## Mobile

- Phones have no keyboard, so `Auto` input mode switches to touch.
- The script taps the center of each lane receptor, one finger per lane.
- The `F6` hotkey does not work on phones. Use the Autoplay toggle in the window.
- If taps land in the wrong spot, adjust **Tap X / Y offset**.
- If nothing registers, try **Touch method: Mouse**. This only handles one lane at a time.
- Touch event support depends on your executor.

## Troubleshooting

**Hits are early or late.** Adjust Hit offset, then Input latency.

**Long notes release too soon or too late.** Adjust Tail offset.

**Notes get missed on fast songs.** Raise Lookahead and Late window a little.

**Nothing happens.** Check Autoplay is on and a match is running. The script only reads the match UI while it is visible.

**Wrong keys press.** Open the Keys tab and set your actual lane binds.

**UI does not load.** Your executor may block the Rayfield loader. Try again or switch executors.

## Notes

- Not tested on every executor. Behavior varies, especially touch input on mobile.
- Using scripts in Roblox can get your account banned. Use an alt account.

## Credits

- [Rayfield](https://docs.sirius.menu/rayfield) UI library by Sirius
