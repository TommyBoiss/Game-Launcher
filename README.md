# Game Launcher

A sandboxed Linux game launcher using [Firejail](https://firejail.wordpress.com/) and [UMU Launcher](https://github.com/Open-Wine-Components/umu-launcher) with GE-Proton.

## Requirements

- `firejail`
- `umu-run`
- `curl`, `tar`, `sha512sum` (for automatic Proton downloads)

## Usage

1. Configure paths, Proton, and defaults (interactive):

   ```sh
   ./init.sh
   ```

2. Launch a game:

   ```sh
   ./launch-game.sh
   ```

   You'll be prompted to pick a game from your game root directory and an executable.

## Options

| Flag | Description |
|---|---|
| `--net-none` | Disable all network access (default) |
| `--net-full` | Allow full network access (weakens sandbox) |
| `--allow-dbus` | Enable filtered D-Bus session bus access |
| `--ignore-seccomp` | Disable Firejail seccomp filtering (weakens sandbox) |
| `--proton-log` | Enable Proton/UMU debug logging |
| `--gameid ID` | Set the UMU game ID |
| `--help` | Show usage |

Paths and defaults are stored in `~/.config/umu-wrapper/config.sh` and can be overridden per-run, e.g. `GAME_ROOT=$HOME/OtherGames ./launch-game.sh`. Re-run `./init.sh` to reconfigure.

## Notes
This script was made in a day so I could run windows games in a sandbox.