<p align="center"><img src="assets/logo/vipergui-logo.png" alt="ViperGui" width="520"></p>

A lightweight GUI framework for Hare. *Simple. Fast. Flexible. Built for Hare.*

Version **0.3.2**.

## How it works

- **Immediate mode** – widgets are plain function calls inside your frame loop.
  No callbacks needed (Hare has no closures): a button just returns `true`
  the frame it is clicked.
- **Software rendering** – everything draws into a `[]u32` framebuffer.
- **Two backends** – a Wayland backend written in pure Hare (no libwayland:
  its own wire protocol, shared-memory buffers, pointer and keyboard), and
  SDL2 as a fallback for X11. Wayland is used automatically on a Wayland
  session; `VIPER_BACKEND=sdl` or `=wayland` forces one.
- **Built-in 8x16 bitmap font** – ASCII + Latin-1, so æøå work. No font library.
- **PNG loader in pure Hare** – own inflate/DEFLATE, no zlib or libpng.

```hare
use viper;

export fn main() void = {
	const win = viper::open("Hello", 640, 480)!;
	defer viper::close(win);
	let on = false;
	for (viper::frame(win)) {
		viper::clear(win, win.theme.bg);
		if (viper::button(win, "Strike!", 20, 20)) {
			on = !on;
		};
		viper::checkbox(win, "Night theme", 20, 60, &on);
		viper::present(win);
	};
};
```

## Build and run

Needs Hare 0.25 or newer. The default build also needs SDL2 development
files for the X11 fallback:

```sh
# Debian / Nebula:  sudo apt install libsdl2-dev
# Void / Duff:      sudo xbps-install SDL2-devel
make run
```

On Wayland you can skip SDL2 entirely: `make HARE_ONLY=1` builds static,
100 % Hare binaries with no C libraries at all (not even libc).

`make test` runs the unit tests.

## Jade — a 3D game on a 2D library

`cmd/jade` is snake in a temple garden, in real 3D. ViperGui only gives
a window and a pixel buffer, so Jade brings its own small software 3D
renderer (`r3d.ha`, about 300 lines): a camera with perspective, triangles
clipped against the near plane and filled with a z-buffer, one light,
distance fog, and a few shapes (boxes, prisms, pyramids, faceted balls).
`scene3d.ha` builds the garden from them every frame, about 1500
triangles, and steers the cameras: behind the snake (default), from above
(Q/E turn it), or the old isometric view drawn with plain 2D shapes.
Press C to switch.

## Mastodon chat

Needs `curl` and an OpenRouter key:

```sh
export OPENROUTER_API_KEY=sk-or-...
make chat
```

Optional: `MASTODON_MODEL` (default `google/gemini-4-argon`), `MASTODON_DIR`
(sprites/persona folder). See `assets/mastodon/LÆS-MIG.txt` for sprites.

## API (0.2.0)

| Area     | Functions |
|----------|-----------|
| Window   | `open`, `close`, `frame`, `present`, `delta`, `ticks`, `backend_name` |
| Input    | `key_down`, `key_pressed`, `key_typed`, `typed`, `key_events` (ordered presses/releases with text, for games and emulators), `wheel`, `mouse`, `mouse_pressed`, `mouse_buttons` / `mouse_clicks` (left, right and middle as bits), `show_cursor` (hide the system pointer) |
| Drawing  | `clear`, `pixel`, `rect`, `round_rect`, `polygon`, `hexagon`, `outline`, `line`, `circle`, `text`, `text_scaled`, `text_width`, `runes`, `rgb`, `mix`, `clip`, `noclip` |
| Images   | `load_png`, `decode_png`, `resize`, `crop`, `split_sheet`, `draw_image`, `image_free`, `set_icon` |
| Data     | `gunzip` (gzip in memory, with the PNG decoder's inflate) |
| Audio    | `audio_open`, `audio_pump`, `play`, `tone`, `melody`, `sound_add`, `load_wav`, `set_muted`, `audio_stream` (raw 44.1 kHz samples, e.g. from an emulator) |
| Widgets  | `label`, `panel`, `button`, `checkbox`, `slider`, `progress`, `textbox` |
| Themes   | `jade`, `night` (or build your own `theme` struct) |

## Layout

```
viper/window.ha    window, frame loop, input (backend-neutral)
viper/wayland.ha   Wayland backend in pure Hare
viper/sdl-nosdl.ha SDL2 backend (left out with -T +nosdl)
viper/sdl+nosdl.ha stand-in used in Hare-only builds
viper/draw.ha      2D drawing + text
viper/font.ha      built-in 8x16 font, ASCII + Latin-1 (from DejaVu Sans Mono)
viper/image.ha     PNG decoder (incl. inflate), resize, alpha drawing
viper/audio.ha     mixer + synth; streams PCM to pw-cat/paplay/aplay
viper/theme.ha     themes
viper/widgets.ha   immediate-mode widgets
cmd/demo/          widgets + "Viper vs. Dumplings" mini game   (make run)
cmd/flappy/        Flappy Crane                               (make flappy)
cmd/mastodon/      AI chat with Mastodon via OpenRouter       (make chat)
cmd/bines/         Bines: honeycomb match-3 game, with Queen Evalin
                   and her scepter booster                    (make play)
cmd/jade/          Jade: snake in 3D in a temple garden, with
                   its own software 3D renderer               (make slange)
cmd/episoder/      Episoder: episode tracker for a series you
                   describe in serie.txt (see assets/episoder/
                   eksempel.txt), with notes, stats and
                   "play next" (xdg-open)                     (make episoder)
cmd/samling/       Samling: tracker for a family of series and
                   films from samling.txt (see assets/samling/
                   eksempel.txt), seasons, stats, MEGA sync   (make samling)
assets/mastodon/   sprites + persona for the chat
assets/crane/      Crane sprite sheet for Flappy Crane
assets/logo/       logo + icon (SVG and PNG 16-512 px)
```

Inspired by Viper from Kung Fu Panda.

## License

MIT, see [LICENSE](LICENSE). [Shifu](https://github.com/sunnyscoop300-a11y/shifu),
a DOS emulator, is built on ViperGui.
