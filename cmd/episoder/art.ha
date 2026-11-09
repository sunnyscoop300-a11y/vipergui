// EPISODER — the scenery, drawn once with ViperGui's shapes: a blood-red
// dusk over the mountains, a full moon, a torii gate, stone lanterns and
// an old battle banner.
use ascii;
use math;
use viper;

def C_BLACK: u32 = 0xff0c0709;
def C_DARK: u32 = 0xff17090c;
def C_PANEL: u32 = 0xe6160a0d;
def C_RED: u32 = 0xffd8202a;
def C_RED_DIM: u32 = 0xff7a141a;
def C_RED_GLOW: u32 = 0xffff3b3b;
def C_TEXT: u32 = 0xfff4ece6;
def C_DIM: u32 = 0xffb8a8a8;
def C_GREEN: u32 = 0xff3ccf4e;
def C_GOLD: u32 = 0xffffc04a;

// An image-sized "window" to draw into with ViperGui's functions.
fn canvas(w: int, h: int) viper::image =
	viper::image { w = w, h = h, pixels = alloc([0u32...], (w * h): size)! };

// The whole background behind the window, made once.
fn make_scenery(win: *viper::window) viper::image = {
	const w = win.width, h = win.height;
	let img = canvas(w, h);
	// Sky: night purple at the top, burning red at the horizon.
	for (let y = 0; y < h; y += 1) {
		const t = y: f64 / (h: f64 * 0.62);
		const c = if (t < 1.0) viper::mix(0xff1a0e2c, 0xff8a1f2a, t * t)
			else viper::mix(0xff8a1f2a, 0xff1a0a0c, (t - 1.0) * 2.4);
		for (let x = 0; x < w; x += 1) img.pixels[(y * w + x): size] = c;
	};
	// Paint the rest with the window's functions: point it at the image.
	const saved = win.pixels;
	win.pixels = img.pixels;
	viper::noclip(win);

	// Stars.
	let seed = 4242u32;
	for (let i = 0; i < 140; i += 1) {
		seed = seed * 1103515245 + 12345;
		const x = ((seed >> 8) % w: u32): int;
		seed = seed * 1103515245 + 12345;
		const y = ((seed >> 8) % (h: u32 / 3)): int;
		viper::pixel(win, x, y, if (i % 4 == 0) 0xffffe8f0 else 0xff9d86b8);
	};
	// The moon, with a haze around it.
	const mx = w - 330, my = 120;
	for (let r = 120; r > 60; r -= 6) {
		glow(win, mx, my, r, 0xff8a3a6a, ((120 - r) / 4): u32);
	};
	viper::circle(win, mx, my, 62, 0xffd7a8d8);
	viper::circle(win, mx - 18, my - 12, 13, 0xffc394c8);
	viper::circle(win, mx + 20, my + 16, 9, 0xffc394c8);
	viper::circle(win, mx + 6, my - 28, 6, 0xffc394c8);

	// Mountains: far violet, near almost black.
	ridge(win, h * 50 / 100, 70.0, 0.006, 1.7, 0xff3a1630);
	ridge(win, h * 58 / 100, 60.0, 0.011, 4.1, 0xff26101e);
	// A pagoda on the far ridge.
	pagoda(win, w - 250, h * 42 / 100, 0xff1a0a14);
	// The torii, right of centre.
	torii(win, w - 340, h * 55 / 100, 1.25);
	// The near ground.
	ridge(win, h * 72 / 100, 26.0, 0.02, 0.4, 0xff120709);
	viper::rect(win, 0, h * 78 / 100, w, h - h * 78 / 100, 0xff0d0507);
	// Stone lanterns, lit.
	lantern(win, 110, h - 70);
	lantern(win, w - 70, h - 120);
	// A torn red banner on a pole.
	banner(win, w - 120, h * 36 / 100);

	win.pixels = saved;
	viper::noclip(win);
	return img;
};

fn glow(win: *viper::window, cx: int, cy: int, r: int, col: u32, a: u32) void = {
	for (let y = -r; y <= r; y += 1) {
		const yy = cy + y;
		if (yy < 0 || yy >= win.height) continue;
		const half = math::sqrtf64((r * r - y * y): f64): int;
		for (let x = cx - half; x <= cx + half; x += 1) {
			if (x < 0 || x >= win.width) continue;
			blend(win, x, yy, col, a);
		};
	};
};

fn blend(win: *viper::window, x: int, y: int, col: u32, a: u32) void = {
	let p = &win.pixels[(y * win.width + x): size];
	const ia = 255 - a;
	const r = (((*p >> 16) & 0xff) * ia + ((col >> 16) & 0xff) * a) / 255;
	const g = (((*p >> 8) & 0xff) * ia + ((col >> 8) & 0xff) * a) / 255;
	const b = ((*p & 0xff) * ia + (col & 0xff) * a) / 255;
	*p = 0xff000000 | r << 16 | g << 8 | b;
};

// Darkens (or tints) a rectangle: col over it with alpha a.
fn shade(win: *viper::window, x: int, y: int, w: int, h: int, col: u32, a: u32) void = {
	for (let yy = y; yy < y + h; yy += 1) {
		if (yy < win.clip_y0 || yy >= win.clip_y1) continue;
		for (let xx = x; xx < x + w; xx += 1) {
			if (xx < win.clip_x0 || xx >= win.clip_x1) continue;
			blend(win, xx, yy, col, a);
		};
	};
};

fn ridge(win: *viper::window, base: int, amp: f64, freq: f64, phase: f64, col: u32) void = {
	for (let x = 0; x < win.width; x += 1) {
		const fx = x: f64;
		const top = base: f64 - amp * (0.55 + 0.3 * math::sinf64(fx * freq + phase)
			+ 0.18 * math::sinf64(fx * freq * 2.9 + phase * 2.0)
			+ 0.08 * math::absf64(math::sinf64(fx * freq * 7.3)));
		viper::rect(win, x, top: int, 1, win.height - top: int, col);
	};
};

fn torii(win: *viper::window, cx: int, ground: int, s: f64) void = {
	const red: u32 = 0xff9e1b22, dark: u32 = 0xff5a0d12, black: u32 = 0xff160a0c;
	const pw = (14.0 * s): int, ph = (150.0 * s): int, span = (150.0 * s): int;
	// Pillars.
	viper::rect(win, cx - span / 2, ground - ph, pw, ph, red);
	viper::rect(win, cx + span / 2 - pw, ground - ph, pw, ph, red);
	viper::rect(win, cx - span / 2 + pw - 4, ground - ph, 4, ph, dark);
	viper::rect(win, cx + span / 2 - 4, ground - ph, 4, ph, dark);
	// The lower beam (nuki) and the top beams (kasagi, curving up).
	viper::rect(win, cx - span / 2 - 10, ground - ph + (32.0 * s): int, span + 20, (9.0 * s): int, red);
	const top = ground - ph - (6.0 * s): int;
	const pts: [6](f64, f64) = [
		((cx - span / 2 - 34): f64, (top - 16): f64),
		((cx + span / 2 + 34): f64, (top - 16): f64),
		((cx + span / 2 + 22): f64, (top + 2): f64),
		(cx: f64 + span: f64 * 0.2, (top + 6): f64),
		(cx: f64 - span: f64 * 0.2, (top + 6): f64),
		((cx - span / 2 - 22): f64, (top + 2): f64),
	];
	viper::polygon(win, pts, black);
	viper::rect(win, cx - span / 2 - 14, top + 6, span + 28, (10.0 * s): int, red);
	// The plaque in the middle.
	viper::rect(win, cx - 9, top + 14, 18, 22, black);
};

fn pagoda(win: *viper::window, cx: int, base: int, col: u32) void = {
	for (let i = 0; i < 4; i += 1) {
		const w = 70 - i * 13, y = base - i * 24;
		const roof: [4](f64, f64) = [((cx - w): f64, y: f64), ((cx + w): f64, y: f64),
			((cx + w - 12): f64, (y - 10): f64), ((cx - w + 12): f64, (y - 10): f64)];
		viper::polygon(win, roof, col);
		viper::rect(win, cx - w + 22, y, (w - 22) * 2, 14, col);
		// A lit window.
		viper::rect(win, cx - 4, y + 3, 8, 7, 0xff7a3020);
	};
	viper::rect(win, cx - 2, base - 118, 4, 22, col);
};

fn lantern(win: *viper::window, cx: int, ground: int) void = {
	const stone: u32 = 0xff2a2224, edge: u32 = 0xff3a3034;
	glow(win, cx, ground - 64, 54, 0xffff9a3a, 18);
	viper::rect(win, cx - 26, ground - 12, 52, 12, stone);
	viper::rect(win, cx - 8, ground - 48, 16, 36, stone);
	viper::rect(win, cx - 22, ground - 56, 44, 8, edge);
	viper::rect(win, cx - 16, ground - 84, 32, 28, stone);
	viper::rect(win, cx - 10, ground - 80, 20, 20, 0xffffb050);
	viper::rect(win, cx - 6, ground - 76, 12, 12, 0xffffe0a0);
	const roof: [3](f64, f64) = [((cx - 30): f64, (ground - 84): f64),
		((cx + 30): f64, (ground - 84): f64), (cx: f64, (ground - 106): f64)];
	viper::polygon(win, roof, edge);
};

fn banner(win: *viper::window, x: int, top: int) void = {
	viper::rect(win, x, top, 5, 260, 0xff2a1a14);
	const flag: [6](f64, f64) = [(x: f64 + 5.0, top: f64 + 8.0), (x: f64 + 70.0, top: f64 + 8.0),
		(x: f64 + 70.0, top: f64 + 170.0), (x: f64 + 52.0, top: f64 + 150.0),
		(x: f64 + 36.0, top: f64 + 176.0), (x: f64 + 5.0, top: f64 + 160.0)];
	viper::polygon(win, flag, 0xffa01a22);
	// A white crest: a ring with a five-point star.
	const cx = x: f64 + 37.0, cy = top: f64 + 70.0;
	viper::circle(win, cx: int, cy: int, 20, 0xffe8dcd0);
	viper::circle(win, cx: int, cy: int, 17, 0xffa01a22);
	for (let i = 0; i < 5; i += 1) {
		const a0 = -math::PI / 2.0 + i: f64 * 4.0 * math::PI / 5.0;
		const a1 = -math::PI / 2.0 + (i + 1): f64 * 4.0 * math::PI / 5.0;
		viper::line(win, (cx + math::cosf64(a0) * 15.0): int, (cy + math::sinf64(a0) * 15.0): int,
			(cx + math::cosf64(a1) * 15.0): int, (cy + math::sinf64(a1) * 15.0): int, 0xffe8dcd0);
	};
};

// The cover card, with the series' name on it.
fn make_cover(win: *viper::window, w: int, h: int) viper::image = {
	let img = canvas(w, h);
	for (let y = 0; y < h; y += 1) {
		const c = viper::mix(0xff2a0a10, 0xff0e0507, y: f64 / h: f64);
		for (let x = 0; x < w; x += 1) img.pixels[(y * w + x): size] = c;
	};
	const saved = win.pixels, sw = win.width, sh = win.height;
	win.pixels = img.pixels;
	win.width = w;
	win.height = h;
	viper::noclip(win);
	viper::circle(win, w / 2 + 30, 50, 34, 0xffb04050);
	viper::circle(win, w / 2 + 30, 50, 30, 0xffe07080);
	torii(win, w / 2, h - 50, 0.75);
	// A katana across it.
	for (let d = 0; d < 3; d += 1) {
		viper::line(win, 14, h - 30 + d, w - 20, 70 + d, 0xffd0d4dc);
	};
	viper::rect(win, 10, h - 36, 28, 10, 0xff3a2018);
	const big = ascii::strupper(SERIES)!;
	defer free(big);
	let scale = 3;
	for (scale > 1 && viper::text_width(big, scale) > w - 8) scale -= 1;
	title_text(win, (w - viper::text_width(big, scale)) / 2, h - 44, big, scale);
	win.pixels = saved;
	win.width = sw;
	win.height = sh;
	viper::noclip(win);
	return img;
};

// Big red title text with a dark outline and a hot edge.
fn title_text(win: *viper::window, x: int, y: int, s: str, scale: int) void = {
	for (let dy = -2; dy <= 2; dy += 1) for (let dx = -2; dx <= 2; dx += 1) {
		viper::text_scaled(win, x + dx, y + dy + 2, s, 0xff120507, scale);
	};
	viper::text_scaled(win, x, y - 1, s, C_RED_GLOW, scale);
	viper::text_scaled(win, x, y, s, C_RED, scale);
};

// A user picture scaled to cover w x h (cropped in the middle).
fn cover_fit(img: *viper::image, w: int, h: int) viper::image = {
	const k = if (w: f64 / img.w: f64 > h: f64 / img.h: f64) w: f64 / img.w: f64
		else h: f64 / img.h: f64;
	const sw = (img.w: f64 * k + 0.5): int, sh = (img.h: f64 * k + 0.5): int;
	let big = viper::resize(img, sw, sh)!;
	defer viper::image_free(&big);
	return viper::crop(&big, (sw - w) / 2, (sh - h) / 2, w, h)!;
};
