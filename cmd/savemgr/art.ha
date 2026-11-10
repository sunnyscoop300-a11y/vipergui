// HPO STEAM SAVE MANAGER — colours, neon panels, covers and icons, all drawn
// with ViperGui's shapes.
use math;
use strings;
use viper;

def C_BG: u32 = 0xff050b1e;
def C_PANEL: u32 = 0xff0a1430;
def C_CARD: u32 = 0xff0c1a3c;
def C_CARD_HI: u32 = 0xff112452;
def C_CYAN: u32 = 0xff22c8ff;
def C_CYAN_DIM: u32 = 0xff1a5f9a;
def C_YELLOW: u32 = 0xfff2d417;
def C_YEL_HI: u32 = 0xfffff06a;
def C_TEXT: u32 = 0xfff2f6ff;
def C_DIM: u32 = 0xffa9b6d6;
def C_INK: u32 = 0xff081024;
def C_GREEN: u32 = 0xff2fd15a;
def C_GREEN_DK: u32 = 0xff0f4a24;
def C_RED: u32 = 0xffff4d5e;
def C_FIELD: u32 = 0xff071027;

fn mix(a: u32, b: u32, t: f64) u32 = {
	const t = if (t < 0.0) 0.0 else if (t > 1.0) 1.0 else t;
	let out = 0xff000000u32;
	for (let s = 0u32; s < 24; s += 8) {
		const x = ((a >> s) & 0xff): f64, y = ((b >> s) & 0xff): f64;
		out |= ((x + (y - x) * t): u32 & 0xff) << s;
	};
	return out;
};

fn vgrad(win: *viper::window, x: int, y: int, w: int, h: int, top: u32, bot: u32) void = {
	for (let i = 0; i < h; i += 1) {
		viper::rect(win, x, y + i, w, 1, mix(top, bot, i: f64 / (if (h > 1) h - 1 else 1): f64));
	};
};

// A panel with a neon rim.
fn neon(win: *viper::window, x: int, y: int, w: int, h: int, r: int, rim: u32, fill: u32) void = {
	viper::round_rect(win, x - 2, y - 2, w + 4, h + 4, r + 2, mix(rim, C_BG, 0.6));
	viper::round_rect(win, x, y, w, h, r, rim);
	viper::round_rect(win, x + 2, y + 2, w - 4, h - 4, r - 1, fill);
};

fn bold(win: *viper::window, x: int, y: int, s: str, col: u32) void = {
	viper::text(win, x, y, s, col);
	viper::text(win, x + 1, y, s, col);
};

fn bold2(win: *viper::window, x: int, y: int, s: str, col: u32) void = {
	viper::text_scaled(win, x, y, s, col, 2);
	viper::text_scaled(win, x + 1, y, s, col, 2);
};

// A lightning bolt in the box (x, y, w, h).
fn bolt(win: *viper::window, x: int, y: int, w: int, h: int, col: u32) void = {
	const pts: [7](f64, f64) = [(0.62, 0.0), (0.18, 0.56), (0.46, 0.56),
		(0.30, 1.0), (0.84, 0.40), (0.56, 0.40), (0.74, 0.0)];
	let p: [7](f64, f64) = [(0.0, 0.0)...];
	for (let i = 0z; i < len(pts); i += 1) {
		p[i] = (x: f64 + pts[i].0 * w: f64, y: f64 + pts[i].1 * h: f64);
	};
	viper::polygon(win, p, col);
};

// A cover when there is no picture: a gradient, the initials and a pad.
fn draw_cover(win: *viper::window, x: int, y: int, w: int, h: int, name: str, seed: size) void = {
	const tops: [4]u32 = [0xff2a4cc0, 0xff6a2aa8, 0xff127a8a, 0xffa8542a];
	viper::round_rect(win, x - 1, y - 1, w + 2, h + 2, 6, C_CYAN_DIM);
	vgrad(win, x, y, w, h, tops[seed % 4], 0xff070b1c);
	draw_icon(win, icon::GAMEPAD, x + w / 2, y + h / 2 - 8, mix(C_TEXT, tops[seed % 4], 0.3));
	// Up to three initials.
	let ini: [3]u8 = [0...];
	let n = 0z, start = true;
	for (let c .. strings::toutf8(name)) {
		if (c == ' ' || c == ':' || c == '-') {
			start = true;
		} else if (start && n < 3 && c < 0x80) {
			ini[n] = c;
			n += 1;
			start = false;
		} else {
			start = false;
		};
	};
	const s = strings::fromutf8_unsafe(ini[..n]);
	bold(win, x + (w - viper::text_width(s, 1)) / 2, y + h - 22, s, C_YEL_HI);
};

// ---- Icons, drawn around (cx, cy) ----

type icon = enum {
	GAMEPAD, CLOUD_UP, RESTORE, SYNC, FOLDER, COG, LOG, INFO,
	STAR, STAR_FULL, CHECK, SEARCH, CALENDAR, EXTERNAL, DOTS, DISC,
};

fn draw_icon(win: *viper::window, id: icon, cx: int, cy: int, col: u32) void = {
	switch (id) {
	case icon::GAMEPAD =>
		viper::round_rect(win, cx - 11, cy - 6, 22, 13, 6, col);
		viper::round_rect(win, cx - 9, cy - 4, 18, 9, 4, C_INK);
		viper::rect(win, cx - 7, cy - 1, 6, 2, col);
		viper::rect(win, cx - 5, cy - 3, 2, 6, col);
		viper::circle(win, cx + 5, cy - 1, 1, col);
		viper::circle(win, cx + 7, cy + 2, 1, col);
	case icon::CLOUD_UP =>
		cloud(win, cx, cy, col);
		viper::line(win, cx, cy + 4, cx, cy - 3, col);
		viper::line(win, cx - 3, cy, cx, cy - 3, col);
		viper::line(win, cx + 3, cy, cx, cy - 3, col);
	case icon::RESTORE, icon::SYNC =>
		for (let i = 0; i < 30; i += 1) {
			const a = i: f64 * 2.0 * math::PI / 36.0 + (if (id == icon::SYNC) 0.4 else 1.2);
			viper::pixel(win, cx + (math::cosf64(a) * 8.0): int, cy + (math::sinf64(a) * 8.0): int, col);
			viper::pixel(win, cx + (math::cosf64(a) * 7.0): int, cy + (math::sinf64(a) * 7.0): int, col);
		};
		const t: [3](f64, f64) = [((cx - 10): f64, (cy - 3): f64), ((cx - 5): f64, (cy - 3): f64),
			((cx - 8): f64, (cy + 2): f64)];
		viper::polygon(win, t, col);
		if (id == icon::SYNC) {
			const u: [3](f64, f64) = [((cx + 10): f64, (cy + 3): f64), ((cx + 5): f64, (cy + 3): f64),
				((cx + 8): f64, (cy - 2): f64)];
			viper::polygon(win, u, col);
		};
	case icon::FOLDER =>
		viper::outline(win, cx - 9, cy - 5, 18, 12, col);
		viper::rect(win, cx - 9, cy - 7, 7, 3, col);
	case icon::COG =>
		for (let i = 0; i < 4; i += 1) {
			const a = i: f64 * math::PI / 4.0;
			const dx = (math::cosf64(a) * 9.0): int, dy = (math::sinf64(a) * 9.0): int;
			viper::line(win, cx - dx, cy - dy, cx + dx, cy + dy, col);
		};
		viper::circle(win, cx, cy, 6, col);
		viper::circle(win, cx, cy, 3, C_INK);
	case icon::LOG =>
		viper::outline(win, cx - 8, cy - 8, 16, 17, col);
		for (let i = 0; i < 3; i += 1) {
			viper::rect(win, cx - 5, cy - 4 + i * 4, 2, 2, col);
			viper::line(win, cx - 1, cy - 3 + i * 4, cx + 5, cy - 3 + i * 4, col);
		};
	case icon::INFO =>
		viper::circle(win, cx, cy, 9, col);
		viper::circle(win, cx, cy, 7, C_INK);
		viper::rect(win, cx - 1, cy - 1, 2, 6, col);
		viper::rect(win, cx - 1, cy - 5, 2, 2, col);
	case icon::STAR, icon::STAR_FULL =>
		let p: [10](f64, f64) = [(0.0, 0.0)...];
		for (let i = 0; i < 10; i += 1) {
			const a = -math::PI / 2.0 + i: f64 * math::PI / 5.0;
			const r = if (i % 2 == 0) 9.0 else 4.0;
			p[i] = (cx: f64 + math::cosf64(a) * r, cy: f64 + math::sinf64(a) * r);
		};
		if (id == icon::STAR_FULL) {
			viper::polygon(win, p, col);
		} else {
			for (let i = 0z; i < 10; i += 1) {
				const q = p[(i + 1) % 10];
				viper::line(win, p[i].0: int, p[i].1: int, q.0: int, q.1: int, col);
			};
		};
	case icon::CHECK =>
		for (let d = 0; d < 2; d += 1) {
			viper::line(win, cx - 5, cy + d, cx - 2, cy + 3 + d, col);
			viper::line(win, cx - 2, cy + 3 + d, cx + 5, cy - 4 + d, col);
		};
	case icon::SEARCH =>
		viper::circle(win, cx - 2, cy - 2, 6, col);
		viper::circle(win, cx - 2, cy - 2, 4, C_FIELD);
		for (let d = 0; d < 2; d += 1) viper::line(win, cx + 2 + d, cy + 2, cx + 7 + d, cy + 7, col);
	case icon::CALENDAR =>
		viper::outline(win, cx - 7, cy - 6, 14, 13, col);
		viper::rect(win, cx - 7, cy - 6, 14, 3, col);
		viper::rect(win, cx - 3, cy, 2, 2, col);
		viper::rect(win, cx + 2, cy, 2, 2, col);
	case icon::EXTERNAL =>
		viper::outline(win, cx - 7, cy - 5, 12, 12, col);
		viper::line(win, cx - 1, cy + 1, cx + 7, cy - 7, col);
		viper::line(win, cx + 2, cy - 7, cx + 7, cy - 7, col);
		viper::line(win, cx + 7, cy - 7, cx + 7, cy - 2, col);
	case icon::DOTS =>
		for (let i = -1; i <= 1; i += 1) viper::circle(win, cx + i * 5, cy, 1, col);
	case icon::DISC =>
		viper::circle(win, cx, cy, 9, col);
		viper::circle(win, cx, cy, 7, C_INK);
		viper::circle(win, cx + 2, cy - 1, 4, col);
		viper::circle(win, cx - 4, cy + 3, 2, col);
	};
};

fn cloud(win: *viper::window, cx: int, cy: int, col: u32) void = {
	viper::circle(win, cx - 5, cy + 2, 5, col);
	viper::circle(win, cx + 2, cy - 2, 7, col);
	viper::circle(win, cx + 7, cy + 3, 4, col);
	viper::circle(win, cx - 5, cy + 2, 3, C_INK);
	viper::circle(win, cx + 2, cy - 2, 5, C_INK);
	viper::circle(win, cx + 7, cy + 3, 2, C_INK);
	viper::rect(win, cx - 6, cy + 1, 13, 5, C_INK);
	viper::line(win, cx - 6, cy + 7, cx + 8, cy + 7, col);
};

// A green tick in a circle.
fn ok_badge(win: *viper::window, cx: int, cy: int, r: int) void = {
	viper::circle(win, cx, cy, r, C_GREEN);
	draw_icon(win, icon::CHECK, cx, cy, 0xffffffff);
};
