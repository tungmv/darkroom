# darkroom

A macOS utility that turns your display gamma to **red-only** — perfect for darkroom, low-light, or night photography work.

The strength is adjustable: a menu bar app with a slider lets you go from a normal
display (0%) to fully red-only (100%), and the CLI accepts the same range.

## How it works

`darkroom` sets the display's gamma tables so the red channel passes through
unchanged while green and blue are attenuated by `1 - intensity`. At 100% green
and blue are zeroed out; at 40% they are at 60% strength, so the screen is
red-tinted rather than red-only, while red (and therefore overall brightness)
stays constant at every setting.

A background daemon (`darkroomd`) re-applies the gamma table every 500ms to fight
interference from ColorSync and display management tools.

## GUI (intensity slider)

```sh
make app        # build .build/Darkroom.app
make run-app    # build and launch it
```

The app lives in the menu bar — no Dock icon:

- **Slider** — 0–100% in 5% steps. Arrow keys nudge by 5% (Shift for 1%),
  `0` and `1` jump to off and full.
- **Presets** — 25 / 50 / 75 / 100%.
- **Switch** — quick on/off. Turning it back on restores your last strength.
- **Menu bar icon** — filled red while active, hollow while off; the tooltip
  shows the current percentage.
- **⌥⌘R** — toggle on/off from any app.

Each change is applied off the main thread and coalesced, so dragging the slider
sends one request at a time instead of a backlog. The last used strength is saved
in `~/.darkroom/intensity`.

Install it into `~/Applications` alongside the CLI:

```sh
make install    # installs darkroom, darkroomd, and Darkroom.app
```

## CLI

```
darkroom on                 # Enable darkroom mode (full strength)
darkroom on --intensity 40  # Enable at 40%
darkroom off                # Restore normal gamma
darkroom status             # Check current state and intensity
darkroom toggle             # Toggle on/off
darkroom intensity 40       # Set strength as a percentage (0-100)
darkroom intensity 0.4      # ... or as a fraction (0.0-1.0)
darkroom get                # Print the current strength as a percentage
darkroom gui                # Launch the menu bar app
darkroom stop               # Restore normal gamma and stop the daemon
```

The daemon starts automatically on first use. `make install` stops an existing
installed daemon before replacing its executable, so the next command always
runs the newly installed version. If a command the daemon doesn't understand is
sent anyway (an old `darkroomd` left over from a previous install), the client
retires that daemon and starts the new one.

When the screen is asleep or the session is locked, no display is "active", so
intensity changes are recorded and painted as soon as a display comes back.

## Build

```sh
swift build -c release
make app     # wrap the GUI into .build/Darkroom.app
make check   # unit tests + a real GUI → daemon round trip
```

To install:

```sh
make install
```

## License

MIT
