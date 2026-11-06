// ViperGui — SDL2 backend (X11, Windows-less fallback, etc.).
// Left out of the build with `hare build -T +nosdl`; see sdl+nosdl.ha.
use strings;
use types::c;

export type sdl_window = opaque;
export type sdl_renderer = opaque;
export type sdl_texture = opaque;
type sdl_surface = opaque;

def SDL_INIT_VIDEO: u32 = 0x00000020;
def SDL_WINDOWPOS_CENTERED: int = 0x2FFF0000;
def SDL_WINDOW_SHOWN: u32 = 0x00000004;
def SDL_RENDERER_ACCELERATED: u32 = 0x00000002;
def SDL_RENDERER_PRESENTVSYNC: u32 = 0x00000004;
def SDL_PIXELFORMAT_ARGB8888: u32 = 0x16362004;
def SDL_TEXTUREACCESS_STREAMING: int = 1;

def SDL_QUIT: u32 = 0x100;
def SDL_KEYDOWN: u32 = 0x300;
def SDL_TEXTINPUT: u32 = 0x303;
def SDL_KEYUP: u32 = 0x301;
def SDL_MOUSEWHEEL: u32 = 0x403;
def SDL_MOUSEBUTTONDOWN: u32 = 0x401;
def SDL_MOUSEBUTTONUP: u32 = 0x402;
def SDL_BUTTON_LEFT: u8 = 1;

@symbol("SDL_Init") fn sdl_init(flags: u32) int;
@symbol("SDL_Quit") fn sdl_quit() void;
@symbol("SDL_GetError") fn sdl_geterror() *const c::char;

@symbol("SDL_CreateWindow") fn sdl_createwindow(
	title: *const c::char,
	x: int, y: int, w: int, h: int,
	flags: u32,
) nullable *sdl_window;
@symbol("SDL_DestroyWindow") fn sdl_destroywindow(w: *sdl_window) void;

@symbol("SDL_CreateRenderer") fn sdl_createrenderer(
	w: *sdl_window, index: int, flags: u32,
) nullable *sdl_renderer;
@symbol("SDL_DestroyRenderer") fn sdl_destroyrenderer(r: *sdl_renderer) void;

@symbol("SDL_CreateTexture") fn sdl_createtexture(
	r: *sdl_renderer, format: u32, access: int, w: int, h: int,
) nullable *sdl_texture;
@symbol("SDL_DestroyTexture") fn sdl_destroytexture(t: *sdl_texture) void;
@symbol("SDL_UpdateTexture") fn sdl_updatetexture(
	t: *sdl_texture, rect: nullable *opaque, pixels: *opaque, pitch: int,
) int;
@symbol("SDL_RenderCopy") fn sdl_rendercopy(
	r: *sdl_renderer, t: *sdl_texture,
	src: nullable *opaque, dst: nullable *opaque,
) int;
@symbol("SDL_RenderPresent") fn sdl_renderpresent(r: *sdl_renderer) void;

// SDL_Event is a 56-byte union; we only read the leading u32 type tag.
type sdl_event = [7]u64;
@symbol("SDL_PollEvent") fn sdl_pollevent(ev: *sdl_event) int;

@symbol("SDL_ShowCursor") fn sdl_showcursor(toggle: int) int;
@symbol("SDL_GetMouseState") fn sdl_getmousestate(x: *int, y: *int) u32;
@symbol("SDL_GetKeyboardState") fn sdl_getkeyboardstate(
	numkeys: nullable *int,
) *[*]u8;
@symbol("SDL_CreateRGBSurfaceFrom") fn sdl_creatergbsurfacefrom(
	pixels: *opaque, w: int, h: int, depth: int, pitch: int,
	rmask: u32, gmask: u32, bmask: u32, amask: u32,
) nullable *sdl_surface;
@symbol("SDL_FreeSurface") fn sdl_freesurface(s: *sdl_surface) void;
@symbol("SDL_SetWindowIcon") fn sdl_setwindowicon(w: *sdl_window, icon: *sdl_surface) void;
@symbol("SDL_StartTextInput") fn sdl_starttextinput() void;

fn sdl_err() str = c::tostr_unsafe(sdl_geterror());

// Internal to ViperGui.
export type sdl_backend = struct {
	win: *sdl_window,
	ren: *sdl_renderer,
	tex: *sdl_texture,
};

fn sdl_open(title: str, width: int, height: int) (*sdl_backend | error | nomem) = {
	if (sdl_init(SDL_INIT_VIDEO) != 0) {
		return sdl_err(): error;
	};
	const ctitle = c::fromstr(title)?;
	defer free(ctitle);

	const sdlwin = match (sdl_createwindow(ctitle,
		SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
		width, height, SDL_WINDOW_SHOWN)) {
	case null =>
		return sdl_err(): error;
	case let w: *sdl_window =>
		yield w;
	};
	const ren = match (sdl_createrenderer(sdlwin, -1,
		SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC)) {
	case null =>
		// Fall back to whatever renderer SDL can give us.
		yield match (sdl_createrenderer(sdlwin, -1, 0)) {
		case null =>
			return sdl_err(): error;
		case let r: *sdl_renderer =>
			yield r;
		};
	case let r: *sdl_renderer =>
		yield r;
	};
	const tex = match (sdl_createtexture(ren, SDL_PIXELFORMAT_ARGB8888,
		SDL_TEXTUREACCESS_STREAMING, width, height)) {
	case null =>
		return sdl_err(): error;
	case let t: *sdl_texture =>
		yield t;
	};
	sdl_starttextinput();
	return alloc(sdl_backend { win = sdlwin, ren = ren, tex = tex })?;
};

fn sdl_close(be: *sdl_backend) void = {
	sdl_destroytexture(be.tex);
	sdl_destroyrenderer(be.ren);
	sdl_destroywindow(be.win);
	free(be);
	sdl_quit();
};

fn sdl_poll(win: *window, be: *sdl_backend) bool = {
	// Edge events (press/release) come from the event queue so that even
	// a click shorter than one frame is never lost.
	let ev: sdl_event = [0...];
	for (sdl_pollevent(&ev) != 0) {
		switch (ev[0]: u32) {
		case SDL_QUIT =>
			return false;
		case SDL_KEYDOWN =>
			// SDL_KeyboardEvent: repeat flag at byte 13, scancode at 16.
			const repeat = (ev[1] >> 40) & 0xff;
			const sc = ev[2]: u32: size;
			if (sc < len(win.pend.keys_pressed)) {
				if (repeat == 0) win.pend.keys_pressed[sc] = true;
				win.pend.keys_typed[sc] = true;
			};
			add_keyevent(win, keyevent {
				hid = sc: u16,
				down = true,
				repeat = repeat != 0,
				...
			});
		case SDL_KEYUP =>
			add_keyevent(win, keyevent { hid = ev[2]: u32: u16, ... });
		case SDL_TEXTINPUT =>
			// SDL_TextInputEvent: NUL-terminated UTF-8 at byte 12.
			const b = &ev: *[56]u8;
			let n = 12z;
			for (n < 44 && b[n] != 0) n += 1;
			add_typed(win, b[12..n]);
			// The text belongs to the key that just went down.
			match (strings::fromutf8(b[12..n])) {
			case let t: str =>
				let it = strings::iter(t);
				match (strings::next(&it)) {
				case let r: rune =>
					const k = win.pend.nevents;
					if (k > 0 && win.pend.events[k - 1].down &&
						win.pend.events[k - 1].text == '\0') {
						win.pend.events[k - 1].text = r;
					} else {
						add_keyevent(win, keyevent { down = true, text = r, ... });
					};
				case => void;
				};
			case => void;
			};
		case SDL_MOUSEWHEEL =>
			// SDL_MouseWheelEvent: y at byte 20.
			win.pend.wheel += (ev[2] >> 32): u32: i32: int;
		case SDL_MOUSEBUTTONDOWN =>
			// SDL_MouseButtonEvent: button at byte 16.
			if (ev[2]: u8 == SDL_BUTTON_LEFT) win.pend.mouse_pressed = true;
			win.pend.clicks |= switch (ev[2]: u8) {
			case 1 => yield LEFT_BUTTON;
			case 2 => yield MIDDLE_BUTTON;
			case 3 => yield RIGHT_BUTTON;
			case => yield 0u8;
			};
		case SDL_MOUSEBUTTONUP =>
			if (ev[2]: u8 == SDL_BUTTON_LEFT) win.pend.mouse_released = true;
		case => void;
		};
	};

	const ks = sdl_getkeyboardstate(null);
	for (let i = 0z; i < len(win.keys); i += 1) {
		win.keys[i] = ks[i];
	};
	let mx = 0, my = 0;
	const buttons = sdl_getmousestate(&mx, &my);
	win.mouse_down = buttons & 1 != 0;
	// SDL's mask: 1 left, 2 middle, 4 right.
	win.buttons = (if (buttons & 1 != 0) LEFT_BUTTON else 0u8) |
		(if (buttons & 4 != 0) RIGHT_BUTTON else 0u8) |
		(if (buttons & 2 != 0) MIDDLE_BUTTON else 0u8);
	win.mouse_x = mx;
	win.mouse_y = my;
	return true;
};

fn sdl_present(win: *window, be: *sdl_backend) void = {
	sdl_updatetexture(be.tex, null, &win.pixels[0]: *opaque, win.width * 4);
	sdl_rendercopy(be.ren, be.tex, null, null);
	sdl_renderpresent(be.ren);
};

fn sdl_icon(be: *sdl_backend, img: *image) void = {
	match (sdl_creatergbsurfacefrom(&img.pixels[0]: *opaque, img.w, img.h,
			32, img.w * 4, 0x00ff0000, 0x0000ff00, 0x000000ff, 0xff000000)) {
	case let surf: *sdl_surface =>
		sdl_setwindowicon(be.win, surf); // SDL copies the pixels
		sdl_freesurface(surf);
	case null => void;
	};
};

fn sdl_cursor(be: *sdl_backend, on: bool) void = {
	sdl_showcursor(if (on) 1 else 0);
};
