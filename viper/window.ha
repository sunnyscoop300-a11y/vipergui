// ViperGui — window, frame loop and input. Backend-neutral: the actual
// window comes from the Wayland backend (pure Hare, wayland.ha) or SDL2
// (sdl-nosdl.ha). Build with `-T +nosdl` for a Hare-only binary.
use os;
use strings;
use time;

// Something went wrong talking to the backend.
export type error = !str;

// Returns a human-readable message for an [[error]].
export fn strerror(err: error) str = err;

// Input edges (presses, typed text, wheel) waiting for the next frame.
// A key going down, repeating or coming up, in the order it happened.
export type keyevent = struct {
	hid: u16,     // USB HID scancode (0 for text that came without a key)
	down: bool,
	repeat: bool, // key repeat while held
	text: rune,   // the character it typed, or '\0'
};

export type edges = struct {
	events: [64]keyevent,
	nevents: size,
	mouse_pressed: bool,
	mouse_released: bool,
	clicks: u8,
	keys_pressed: [512]bool,
	keys_typed: [512]bool,
	typed: [256]u8,
	ntyped: size,
	wheel: int,
};

// Mouse buttons, as bits in [[mouse_buttons]] and [[mouse_clicks]].
export def LEFT_BUTTON: u8 = 1;
export def RIGHT_BUTTON: u8 = 2;
export def MIDDLE_BUTTON: u8 = 4;

// The backend behind a window (internal to ViperGui).
export type backend = (*sdl_backend | *wl_backend);

// A ViperGui window. Owns a software framebuffer that everything draws into.
export type window = struct {
	be: backend,
	width: int,
	height: int,
	pixels: []u32,
	theme: theme,

	// Input state, refreshed by [[frame]]. Keys are USB HID scancodes.
	mouse_x: int,
	mouse_y: int,
	mouse_down: bool,
	mouse_pressed: bool,
	mouse_released: bool,
	buttons: u8,              // buttons held (LEFT_BUTTON | ...)
	clicks: u8,               // buttons that went down this frame
	cursor_hidden: bool,
	keys: [512]u8,
	keys_pressed: [512]bool,
	keys_typed: [512]bool,    // like keys_pressed, but with key repeat
	typed: [256]u8,           // UTF-8 text typed this frame
	ntyped: size,
	wheel: int,               // mouse wheel steps this frame (+ = up)
	events: [64]keyevent,     // key events this frame, in order
	nevents: size,

	// Edge events collected since the last frame. Backends write here (they
	// may read events at any time, e.g. while waiting in present), and
	// frame() hands them to the app, so nothing gets lost between frames.
	pend: edges,

	// Drawing clip rectangle, see [[clip]].
	clip_x0: int,
	clip_y0: int,
	clip_x1: int,
	clip_y1: int,

	// Immediate-mode widget state.
	hot: u64,
	active: u64,

	// Timing.
	last_ms: u64,
	dt: f64,
	frames: u64,
};

// Name of the backend in use: "wayland" or "sdl".
export fn backend_name(win: *window) str = match (win.be) {
case *wl_backend => yield "wayland";
case *sdl_backend => yield "sdl";
};

// Opens a window of the given size. Free it with [[close]].
//
// On a Wayland session the pure-Hare Wayland backend is used; otherwise (or
// with VIPER_BACKEND=sdl) SDL2. VIPER_BACKEND=wayland forces Wayland.
export fn open(title: str, width: int, height: int) (*window | error | nomem) = {
	const want = os::tryenv("VIPER_BACKEND", "");
	const wayland = want == "wayland"
		|| (want != "sdl" && os::getenv("WAYLAND_DISPLAY") is str);

	let be: (backend | void) = void;
	let wl_err = "";
	if (wayland) {
		match (wl_open(title, width, height)) {
		case let b: *wl_backend =>
			be = b;
		case let e: error =>
			if (want == "wayland") return e;
			wl_err = e;
		case nomem =>
			return nomem;
		};
	};
	if (be is void) {
		match (sdl_open(title, width, height)) {
		case let b: *sdl_backend =>
			be = b;
		case let e: error =>
			// Report the Wayland problem if that was the first choice.
			return if (len(wl_err) > 0) wl_err: error else e;
		case nomem =>
			return nomem;
		};
	};

	const pixels: []u32 = alloc([0u32...], (width * height): size)?;
	const win = alloc(window {
		be = be as backend,
		width = width,
		height = height,
		pixels = pixels,
		theme = jade,
		clip_x1 = width,
		clip_y1 = height,
		last_ms = now_ms(),
		dt = 1.0 / 60.0,
		...
	})?;
	set_default_icon(win);
	return win;
};

// Closes the window and releases everything it owns.
export fn close(win: *window) void = {
	match (win.be) {
	case let be: *sdl_backend => sdl_close(be);
	case let be: *wl_backend => wl_close(be);
	};
	free(win.pixels);
	free(win);
};

fn now_ms() u64 = {
	const t = time::now(time::clock::MONOTONIC);
	return t.sec: u64 * 1000 + t.nsec: u64 / 1000000;
};

// Starts a new frame: caps the frame rate at ~60 FPS, reads input and
// returns false once the user has asked to close the window.
//
//	for (viper::frame(win)) { ... viper::present(win); };
export fn frame(win: *window) bool = {
	let now = now_ms();
	const elapsed = now - win.last_ms;
	if (elapsed < 16) {
		time::sleep((16 - elapsed): i64 * time::MILLISECOND);
		now = now_ms();
	};
	win.dt = (now - win.last_ms): f64 / 1000.0;
	if (win.dt > 0.1) win.dt = 0.1;
	win.last_ms = now;
	win.frames += 1;

	const alive = match (win.be) {
	case let be: *sdl_backend => yield sdl_poll(win, be);
	case let be: *wl_backend => yield wl_poll(win, be);
	};
	if (!alive) return false;
	latch_input(win);

	// Release widget focus once the mouse button is no longer involved.
	if (!win.mouse_down && !win.mouse_released) {
		win.active = 0;
	};
	win.hot = 0;
	return true;
};

// Shows everything drawn this frame.
export fn present(win: *window) void = {
	match (win.be) {
	case let be: *sdl_backend => sdl_present(win, be);
	case let be: *wl_backend => wl_present(win, be);
	};
};

// Adds UTF-8 text to what [[typed]] returns next frame (used by backends).
fn add_typed(win: *window, s: []u8) void = {
	for (let b .. s) {
		if (win.pend.ntyped < len(win.pend.typed)) {
			win.pend.typed[win.pend.ntyped] = b;
			win.pend.ntyped += 1;
		};
	};
};

// Records a key event for [[key_events]] (used by backends).
fn add_keyevent(win: *window, ev: keyevent) void = {
	if (win.pend.nevents < len(win.pend.events)) {
		win.pend.events[win.pend.nevents] = ev;
		win.pend.nevents += 1;
	};
};

// Hands the collected edge events to the app for this frame.
fn latch_input(win: *window) void = {
	win.mouse_pressed = win.pend.mouse_pressed;
	win.mouse_released = win.pend.mouse_released;
	win.clicks = win.pend.clicks;
	win.keys_pressed = win.pend.keys_pressed;
	win.keys_typed = win.pend.keys_typed;
	win.typed = win.pend.typed;
	win.ntyped = win.pend.ntyped;
	win.wheel = win.pend.wheel;
	win.events = win.pend.events;
	win.nevents = win.pend.nevents;
	win.pend = edges { ... };
};

// Seconds since the previous frame.
export fn delta(win: *window) f64 = win.dt;

// Milliseconds on a monotonic clock; handy as a random seed.
export fn ticks() u32 = now_ms(): u32;

// Physical keys (USB HID scancodes, as used by SDL).
export type key = enum uint {
	A = 4, B, C, D, E, F, G, H, I, J, K, L, M,
	N, O, P, Q, R, S, T, U, V, W, X, Y, Z,
	RETURN = 40,
	KP_ENTER = 88,
	ESCAPE = 41,
	BACKSPACE = 42,
	TAB = 43,
	SPACE = 44,
	RIGHT = 79,
	LEFT = 80,
	DOWN = 81,
	UP = 82,
};

// True while the key is held.
export fn key_down(win: *window, k: key) bool = win.keys[k: size] != 0;

// True only on the frame the key went down.
export fn key_pressed(win: *window, k: key) bool = win.keys_pressed[k: size];

// Current mouse position.
export fn mouse(win: *window) (int, int) = (win.mouse_x, win.mouse_y);

// True on the frame the key went down and again on each key repeat.
// Use this for things like backspace in text fields.
export fn key_typed(win: *window, k: key) bool = win.keys_typed[k: size];

// The text (UTF-8) the user typed this frame, e.g. "a" or "æ".
export fn typed(win: *window) str = {
	return strings::fromutf8_unsafe(win.typed[..win.ntyped]);
};

// Every key press, repeat and release this frame, in order, with the
// character each one typed. Emulators and games that need key releases
// or exact ordering use this instead of [[key_pressed]] and [[typed]].
export fn key_events(win: *window) []keyevent = win.events[..win.nevents];

// Mouse wheel steps this frame (positive = scrolled up).
export fn wheel(win: *window) int = win.wheel;

// The mouse buttons held down now: LEFT_BUTTON, RIGHT_BUTTON and
// MIDDLE_BUTTON as bits.
export fn mouse_buttons(win: *window) u8 = win.buttons;

// The buttons that went down this frame, even if already let go again (a
// quick tap on a touchpad can start and end between two frames).
export fn mouse_clicks(win: *window) u8 = win.clicks;

// Shows or hides the system's mouse pointer over the window, for programs
// that draw their own (games, emulators).
export fn show_cursor(win: *window, on: bool) void = {
	if (win.cursor_hidden == !on) return;
	win.cursor_hidden = !on;
	match (win.be) {
	case let be: *sdl_backend => sdl_cursor(be, on);
	case let be: *wl_backend => wl_cursor(win, be);
	};
};

// True only on the frame the left mouse button went down.
export fn mouse_pressed(win: *window) bool = win.mouse_pressed;
