# darkroom

A macOS utility that turns your display gamma to **red-only** — perfect for darkroom, low-light, or night photography work.

## How it works

`darkroom` sets the display's gamma tables so only the red channel is active (green and blue are zeroed out). A background daemon (`darkroomd`) re-applies the gamma table every 500ms to fight interference from ColorSync and display management tools.

## Usage

```
darkroom on       # Enable darkroom mode
darkroom off      # Restore normal gamma
darkroom status   # Check current state
darkroom toggle   # Toggle on/off
darkroom stop     # Restore normal gamma and stop the background daemon
```

The daemon starts automatically on first use. `make install` stops an existing
installed daemon before replacing its executable, so the next command always
runs the newly installed version.

## Build

```sh
swift build -c release
```

To install:

```sh
make install
```

## License

MIT
