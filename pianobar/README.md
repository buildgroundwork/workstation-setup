# Pianobar

Auto-restarting wrapper, watchdog, and tmux integration for [pianobar](https://github.com/PromyLOPh/pianobar) — a terminal Pandora client.

## What's here

| File | Purpose | Installed to |
|---|---|---|
| `pianobar-loop` | Foreground wrapper that restarts pianobar on crash or network error. Includes a sliding-window rate limiter that gives up if pianobar is permanently broken. | `$HOMEBREW_DIR/bin/pianobar-loop` (symlink) |
| `pianobar-respawn` | One-shot helper: kills the running `pianobar` so the wrapper respawns it. Use after audio device changes (e.g. swapping headphones) or to break out of a wedged state. | `$HOMEBREW_DIR/bin/pianobar-respawn` (symlink) |
| `eventcmd` | Pianobar event handler. Updates `/tmp/pianobar_nowplaying` (consumed by tmux status line) and writes a quit-sentinel on `userquit` so the wrapper knows to exit. | `~/.config/pianobar/eventcmd` (symlink) |
| `toggle` | Pause/resume helper bound to the tmux `Ctrl-b P p` keybinding. | `~/.config/pianobar/toggle` (symlink) |
| `config.shared` | Committed config fragment with `audio_quality`, `fifo`, `event_command`. Uses `%HOME%` placeholder which `setup.sh` substitutes with `$HOME`. | (concatenated, see below) |
| `config.local.example` | Template for the uncommitted per-machine config. | (copied to `config.local` on first install) |
| `config.local` | Per-machine secrets (`user`, `password_command`). **Gitignored.** Must exist before `setup.sh` will build the live config. | (concatenated, see below) |

## Config assembly

Pianobar reads exactly one user config file (`~/.config/pianobar/config`) and supports no `include` directive. To split shared defaults from per-machine secrets, `setup.sh`:

1. Reads `config.shared`.
2. Substitutes `%HOME%` with the current `$HOME`.
3. Concatenates `config.local` after it.
4. Writes the result to `~/.config/pianobar/config`.

This means **the live config is rebuilt every time `setup.sh` runs.** Don't hand-edit `~/.config/pianobar/config` — your changes will be overwritten. Edit `config.shared` (and commit) or `config.local` (and don't) instead.

## Initial setup on a new machine

1. Run `setup.sh`. It will create `~/.workstation/pianobar/config.local` from the example and exit with a warning if the file didn't already exist. (Or do it yourself: `cp config.local.example config.local`.)
2. Edit `config.local`: set your real email in both the `user =` line and the keychain lookup in `password_command`.
3. Store the password in Keychain:

   ```sh
   security add-generic-password -s pianobar -a YOUR_EMAIL -w
   ```

   Paste the password when prompted.
4. Re-run `setup.sh`. It will now build the live config.
5. Run `pianobar-loop` in any terminal. The first time, pianobar will prompt for a station — pick one. Subsequent runs auto-resume the last station from `~/.config/pianobar/state`.

## How the wrapper handles failures

Pianobar is prone to wedging when its TCP connection to Pandora's tuner API goes stale (a known long-standing bug, especially under VPN or laptop sleep/wake). The audio thread keeps streaming the current song while the control thread is blocked reading from a dead socket — looks fine for a few minutes, then silence.

`pianobar-loop` does **not** try to detect a wedge automatically. Earlier versions had a watchdog using socket-state and event-heartbeat heuristics, but both signals false-positived often enough to interrupt healthy playback (a long song with no events, or the normal between-songs window when the tuner socket is briefly CLOSED). Killing pianobar mid-song to "fix" a non-existent wedge was worse than the original bug.

Instead: when audio actually stops, hit **`Ctrl-b P K`** (or run `pianobar-respawn`) to kick it. You're a better wedge-detector than any heuristic.

What the wrapper *does* handle automatically:

- Pianobar crashes or exits with a network error → wrapper restarts it within 2 seconds
- You press `q` → eventcmd writes `~/.config/pianobar/quit-sentinel`, wrapper exits cleanly
- You press Ctrl-C → trap kills pianobar and the wrapper exits
- More than 5 restarts in any 120-second window → wrapper gives up with exit 1, so persistent breakage (bad credentials, no audio device, Pandora outage) is loud and visible

## Tmux keybindings (set in `~/.workstation/tmux.conf`)

After `Ctrl-b P` (enters the `pianobar` keybinding table):

| Key | Action |
|---|---|
| `p` / `P` | Pause/resume (via `toggle` script) |
| `n` | Next song |
| `+` | Love current song |
| `-` | Ban current song |
| `k` / `K` | Kill pianobar (wrapper respawns it) — use after device changes or wedges |

## Runtime files (NOT in this repo)

These live in `~/.config/pianobar/` and are created by pianobar itself or by the wrapper. They are mutable per-machine state and should never be committed:

- `state` — pianobar's persisted state (autostart_station, volume)
- `ctl` — named pipe for control commands
- `quit-sentinel` — clean-quit signal from eventcmd to the wrapper
- `config` — the assembled live config (rebuilt by `setup.sh`)
