// SAMLING — what is drawn when there is no mockup: night-blue gradients,
// lightning bolts, covers and the little line icons. All made from
// ViperGui's shapes; no pictures from any series.
use math;
use viper;

def C_BG: u32 = 0xff080f2e;
def C_SIDE: u32 = 0xff070b28;
def C_PANEL: u32 = 0xff0d1b4d;
def C_CARD: u32 = 0xff0a1851;
def C_DEEP: u32 = 0xff071443;
def C_BORDER: u32 = 0xff2b34b3;
def C_GLOW: u32 = 0xff4a6bff;
def C_YELLOW: u32 = 0xffe9b80f;
def C_YEL_HI: u32 = 0xffffd43c;
def C_TEXT: u32 = 0xfff2f4ff;
def C_DIM: u32 = 0xffaeb8dc;
def C_INK: u32 = 0xff0b1030;     // text on yellow
def C_CYAN: u32 = 0xff21b8fe;
def C_SEEN: u32 = 0xff2da6e6;
def C_SEEN_DK: u32 = 0xff1466b0;
def C_UNSEEN: u32 = 0xff17255e;
def C_TRACK: u32 = 0xff0a1745;
def C_GREEN: u32 = 0xff2fbf4a;

fn mix(a: u32, b: u32, t: f64) u32 = {
	const t = if (t < 0.0) 0.0 else if (t > 1.0) 1.0 else t;
	let out = 0xff000000u32;
	for (let s = 0u32; s < 24; s += 8) {
		const x = ((a >> s) & 0xff): f64, y = ((b >> s) & 0xff): f64;
		out |= ((x + (y - x) * t): u32 & 0xff) << s;
	};
	return out;
};

// A vertical gradient.
fn vgrad(win: *viper::window, x: int, y: int, w: int, h: int, top: u32, bot: u32) void = {
	for (let i = 0; i < h; i += 1) {
		viper::rect(win, x, y + i, w, 1, mix(top, bot, i: f64 / (if (h > 1) h - 1 else 1): f64));
	};
};

// A panel with a glowing blue rim.
fn glass(win: *viper::window, x: int, y: int, w: int, h: int, r: int, fill: u32) void = {
	viper::round_rect(win, x - 1, y - 1, w + 2, h + 2, r + 1, 0xff1a2470);
	viper::round_rect(win, x, y, w, h, r, C_BORDER);
	viper::round_rect(win, x + 2, y + 2, w - 4, h - 4, r - 1, fill);
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

// Big title text with a dark edge.
fn loud_text(win: *viper::window, x: int, y: int, s: str, scale: int, col: u32) void = {
	for (let dy = -2; dy <= 3; dy += 1) for (let dx = -2; dx <= 2; dx += 1) {
		viper::text_scaled(win, x + dx, y + dy, s, 0xff3a0c10, scale);
	};
	viper::text_scaled(win, x, y, s, col, scale);
	viper::text_scaled(win, x, y - 1, s, mix(col, 0xffffffff, 0.35), scale);
};

fn bold(win: *viper::window, x: int, y: int, s: str, col: u32) void = {
	viper::text(win, x, y, s, col);
	viper::text(win, x + 1, y, s, col);
};

fn bold2(win: *viper::window, x: int, y: int, s: str, col: u32) void = {
	viper::text_scaled(win, x, y, s, col, 2);
	viper::text_scaled(win, x + 1, y, s, col, 2);
};

// A cover card: night sky, a bolt and the name.
fn draw_cover(win: *viper::window, x: int, y: int, w: int, h: int, name: str, n: size) void = {
	const tops: [3]u32 = [0xff1f3fa8, 0xff3a1d8a, 0xff12458f];
	viper::round_rect(win, x - 1, y - 1, w + 2, h + 2, 7, 0xff5a73ff);
	vgrad(win, x, y, w, h, tops[n % 3], 0xff060a26);
	for (let i = 0; i < 14; i += 1) {
		const sx = x + (i * 37 + n: int * 11) % w, sy = y + (i * 23 + n: int * 7) % (h / 2);
		viper::pixel(win, sx, sy, 0xffcfd8ff);
	};
	bolt(win, x + w / 4, y + h / 8, w / 2, h / 2, C_YELLOW);
	bolt(win, x + w / 4 + 3, y + h / 8, w / 2 - 6, h / 2 - 6, C_YEL_HI);
	// The name, as many lines as it takes.
	let lines: [3]str = [""...];
	const n = wrap(name, w - 8, lines);
	for (let i = 0z; i < n; i += 1) {
		const tw = viper::text_width(lines[i], 1);
		bold(win, x + (w - tw) / 2, y + h - 8 - (n - i): int * 17, lines[i], C_YEL_HI);
	};
};

// The top banner: a stormy sky with bolts and the collection's name.
fn draw_banner(win: *viper::window, x: int, y: int, w: int, h: int, name: str) void = {
	vgrad(win, x, y, w, h, 0xff0d1660, 0xff1c3db0);
	for (let i = 0; i < 40; i += 1) {
		viper::pixel(win, x + (i * 97) % w, y + (i * 31) % (h / 2), 0xffdfe6ff);
	};
	// A city at the bottom.
	for (let i = 0; i < 26; i += 1) {
		const bw = 18 + (i * 7) % 22, bh = 20 + (i * 29) % 46;
		const bx = x + i * w / 26;
		viper::rect(win, bx, y + h - bh, bw, bh, 0xff0a1450);
		for (let k = 0; k < bh / 9; k += 1) {
			if ((i + k) % 3 == 0) viper::rect(win, bx + 4, y + h - bh + 4 + k * 9, 3, 3, 0xff5f86ff);
		};
	};
	bolt(win, x + 40, y + 10, 70, h - 20, C_YELLOW);
	bolt(win, x + w - 130, y + 6, 80, h - 16, C_YELLOW);
	bolt(win, x + w - 230, y + 30, 40, h / 2, C_YEL_HI);
	const big = upper(name);
	defer free(big);
	let scale = 5;
	for (scale > 2 && viper::text_width(big, scale) > w - 300) scale -= 1;
	const tw = viper::text_width(big, scale);
	loud_text(win, x + (w - tw) / 2, y + (h - 16 * scale) / 2, big, scale, C_YELLOW);
};

// ---- Icons, drawn around (cx, cy) ----

type icon = enum { HOME, TV, FILM, STATS, CLOUD, COG, INFO, EYE, CHECK };

fn draw_icon(win: *viper::window, id: icon, cx: int, cy: int, col: u32) void = {
	switch (id) {
	case icon::HOME =>
		viper::line(win, cx - 9, cy - 1, cx, cy - 9, col);
		viper::line(win, cx, cy - 9, cx + 9, cy - 1, col);
		viper::line(win, cx - 9, cy, cx, cy - 8, col);
		viper::line(win, cx, cy - 8, cx + 9, cy, col);
		viper::outline(win, cx - 6, cy - 2, 12, 10, col);
		viper::rect(win, cx - 2, cy + 3, 4, 5, col);
	case icon::TV =>
		viper::outline(win, cx - 9, cy - 5, 18, 13, col);
		viper::outline(win, cx - 8, cy - 4, 16, 11, col);
		viper::line(win, cx - 4, cy - 10, cx, cy - 6, col);
		viper::line(win, cx + 4, cy - 10, cx, cy - 6, col);
	case icon::FILM =>
		viper::outline(win, cx - 9, cy - 3, 18, 11, col);
		viper::rect(win, cx - 9, cy - 8, 18, 4, col);
		for (let i = 0; i < 3; i += 1) viper::line(win, cx - 6 + i * 6, cy - 8, cx - 3 + i * 6, cy - 4, C_INK);
	case icon::STATS =>
		viper::rect(win, cx - 8, cy + 1, 3, 7, col);
		viper::rect(win, cx - 3, cy - 3, 3, 11, col);
		viper::rect(win, cx + 2, cy - 7, 3, 15, col);
		viper::rect(win, cx + 7, cy - 1, 2, 9, col);
	case icon::CLOUD =>
		viper::circle(win, cx - 4, cy + 1, 5, col);
		viper::circle(win, cx + 3, cy - 2, 6, col);
		viper::circle(win, cx + 7, cy + 3, 4, col);
		viper::circle(win, cx - 4, cy + 1, 3, C_INK);
		viper::circle(win, cx + 3, cy - 2, 4, C_INK);
		viper::circle(win, cx + 7, cy + 3, 2, C_INK);
		viper::rect(win, cx - 6, cy + 1, 13, 4, C_INK);
		viper::line(win, cx - 4, cy + 6, cx + 7, cy + 6, col);
	case icon::COG =>
		for (let i = 0; i < 4; i += 1) {
			const a = i: f64 * math::PI / 4.0;
			const dx = (math::cosf64(a) * 9.0): int, dy = (math::sinf64(a) * 9.0): int;
			viper::line(win, cx - dx, cy - dy, cx + dx, cy + dy, col);
		};
		viper::circle(win, cx, cy, 6, col);
		viper::circle(win, cx, cy, 3, C_INK);
	case icon::INFO =>
		viper::circle(win, cx, cy, 9, col);
		viper::circle(win, cx, cy, 7, C_INK);
		viper::rect(win, cx - 1, cy - 1, 2, 6, col);
		viper::rect(win, cx - 1, cy - 5, 2, 2, col);
	case icon::EYE =>
		for (let i = -10; i <= 10; i += 1) {
			const dy = (6.0 * (1.0 - (i * i): f64 / 100.0)): int;
			viper::pixel(win, cx + i, cy - dy, col);
			viper::pixel(win, cx + i, cy + dy, col);
		};
		viper::circle(win, cx, cy, 3, col);
	case icon::CHECK =>
		for (let d = 0; d < 3; d += 1) {
			viper::line(win, cx - 7, cy + d - 1, cx - 3, cy + 3 + d, col);
			viper::line(win, cx - 3, cy + 3 + d, cx + 7, cy - 6 + d, col);
		};
	};
};

// A green tick in a circle.
fn ok_badge(win: *viper::window, cx: int, cy: int) void = {
	viper::circle(win, cx, cy, 11, C_GREEN);
	draw_icon(win, icon::CHECK, cx, cy, 0xffffffff);
};
