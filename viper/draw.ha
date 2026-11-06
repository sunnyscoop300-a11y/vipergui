// ViperGui — 2D drawing into the window framebuffer.
use math;
use strings;

// A 0xAARRGGBB color.
export type color = u32;

// Builds an opaque color from red, green and blue.
export fn rgb(r: u8, g: u8, b: u8) color =
	0xff000000 | (r: u32 << 16) | (g: u32 << 8) | b: u32;

// Linearly mixes two colors; t = 0 gives a, t = 1 gives b.
export fn mix(a: color, b: color, t: f64) color = {
	if (t <= 0.0) return a;
	if (t >= 1.0) return b;
	return 0xff000000 | ch(a, b, 16, t) | ch(a, b, 8, t) | ch(a, b, 0, t);
};

fn ch(a: color, b: color, shift: u32, t: f64) u32 = {
	const ca = ((a >> shift) & 0xff): f64;
	const cb = ((b >> shift) & 0xff): f64;
	return ((ca + (cb - ca) * t): u32 & 0xff) << shift;
};

// Restricts all drawing (except [[clear]]) to a rectangle. Useful for
// scrolling areas. Call [[noclip]] to draw everywhere again.
export fn clip(win: *window, x: int, y: int, w: int, h: int) void = {
	win.clip_x0 = if (x < 0) 0 else x;
	win.clip_y0 = if (y < 0) 0 else y;
	win.clip_x1 = if (x + w > win.width) win.width else x + w;
	win.clip_y1 = if (y + h > win.height) win.height else y + h;
};

// Removes the clipping rectangle set by [[clip]].
export fn noclip(win: *window) void = clip(win, 0, 0, win.width, win.height);

// Fills the whole window with one color.
export fn clear(win: *window, col: color) void = {
	for (let i = 0z; i < len(win.pixels); i += 1) {
		win.pixels[i] = col;
	};
};

// Sets a single pixel (ignored when outside the clip area).
export fn pixel(win: *window, x: int, y: int, col: color) void = {
	if (x < win.clip_x0 || y < win.clip_y0
			|| x >= win.clip_x1 || y >= win.clip_y1) return;
	win.pixels[(y * win.width + x): size] = col;
};

// Draws a filled rectangle.
export fn rect(win: *window, x: int, y: int, w: int, h: int, col: color) void = {
	const x0 = if (x < win.clip_x0) win.clip_x0 else x;
	const y0 = if (y < win.clip_y0) win.clip_y0 else y;
	const x1 = if (x + w > win.clip_x1) win.clip_x1 else x + w;
	const y1 = if (y + h > win.clip_y1) win.clip_y1 else y + h;
	for (let yy = y0; yy < y1; yy += 1) {
		const row = yy * win.width;
		for (let xx = x0; xx < x1; xx += 1) {
			win.pixels[(row + xx): size] = col;
		};
	};
};

// Draws a rectangle outline.
export fn outline(win: *window, x: int, y: int, w: int, h: int, col: color) void = {
	rect(win, x, y, w, 1, col);
	rect(win, x, y + h - 1, w, 1, col);
	rect(win, x, y, 1, h, col);
	rect(win, x + w - 1, y, 1, h, col);
};

// Draws a filled rectangle with rounded corners.
export fn round_rect(win: *window, x: int, y: int, w: int, h: int, r: int, col: color) void = {
	if (r * 2 > h) r = h / 2;
	if (r * 2 > w) r = w / 2;
	rect(win, x + r, y, w - 2 * r, h, col);
	rect(win, x, y + r, r, h - 2 * r, col);
	rect(win, x + w - r, y + r, r, h - 2 * r, col);
	for (let dy = 0; dy < r; dy += 1) {
		for (let dx = 0; dx < r; dx += 1) {
			const ex = r - dx - 1, ey = r - dy - 1;
			if (ex * ex + ey * ey > r * r) continue;
			pixel(win, x + r - 1 - ex, y + r - 1 - ey, col);
			pixel(win, x + w - r + ex, y + r - 1 - ey, col);
			pixel(win, x + r - 1 - ex, y + h - r + ey, col);
			pixel(win, x + w - r + ex, y + h - r + ey, col);
		};
	};
};

// Draws a line using Bresenham's algorithm.
export fn line(win: *window, x0: int, y0: int, x1: int, y1: int, col: color) void = {
	const dx = if (x1 > x0) x1 - x0 else x0 - x1;
	const dy = if (y1 > y0) y0 - y1 else y1 - y0;
	const sx = if (x0 < x1) 1 else -1;
	const sy = if (y0 < y1) 1 else -1;
	let err = dx + dy;
	let x = x0, y = y0;
	for (true) {
		pixel(win, x, y, col);
		if (x == x1 && y == y1) break;
		const e2 = 2 * err;
		if (e2 >= dy) { err += dy; x += sx; };
		if (e2 <= dx) { err += dx; y += sy; };
	};
};

// Draws a filled circle.
export fn circle(win: *window, cx: int, cy: int, r: int, col: color) void = {
	for (let y = -r; y <= r; y += 1) {
		for (let x = -r; x <= r; x += 1) {
			if (x * x + y * y <= r * r + r) {
				pixel(win, cx + x, cy + y, col);
			};
		};
	};
};

// Fills a polygon (any shape, even-odd rule). Points are (x, y) pairs.
export fn polygon(win: *window, pts: [](f64, f64), col: color) void = {
	if (len(pts) < 3) return;
	let ymin = pts[0].1, ymax = pts[0].1;
	for (let p .. pts) {
		if (p.1 < ymin) ymin = p.1;
		if (p.1 > ymax) ymax = p.1;
	};
	let y0 = math::floorf64(ymin): int, y1 = math::floorf64(ymax): int + 1;
	if (y0 < win.clip_y0) y0 = win.clip_y0;
	if (y1 > win.clip_y1) y1 = win.clip_y1;
	let xs: [32]f64 = [0.0...];
	for (let y = y0; y < y1; y += 1) {
		const yc = y: f64 + 0.5;
		let n = 0z;
		for (let i = 0z; i < len(pts) && n < len(xs); i += 1) {
			const a = pts[i], b = pts[(i + 1) % len(pts)];
			if ((a.1 <= yc && b.1 > yc) || (b.1 <= yc && a.1 > yc)) {
				xs[n] = a.0 + (yc - a.1) * (b.0 - a.0) / (b.1 - a.1);
				n += 1;
			};
		};
		// Insertion sort; polygons here have few edges.
		for (let i = 1z; i < n; i += 1) {
			const v = xs[i];
			let j = i;
			for (j > 0 && xs[j - 1] > v; j -= 1) xs[j] = xs[j - 1];
			xs[j] = v;
		};
		for (let i = 0z; i + 1 < n; i += 2) {
			const xa = math::floorf64(xs[i] + 0.5): int;
			const xb = math::floorf64(xs[i + 1] + 0.5): int;
			rect(win, xa, y, xb - xa, 1, col);
		};
	};
};

// Fills a regular hexagon. Flat top when pointy is false (like a honeycomb
// cell lying on its side), pointy top when true. r is center-to-corner.
export fn hexagon(win: *window, cx: f64, cy: f64, r: f64, col: color, pointy: bool = false) void = {
	let pts: [6](f64, f64) = [(0.0, 0.0)...];
	const off = if (pointy) math::PI / 6.0 else 0.0;
	for (let i = 0z; i < 6; i += 1) {
		const a = off + i: f64 * math::PI / 3.0;
		pts[i] = (cx + r * math::cosf64(a), cy + r * math::sinf64(a));
	};
	polygon(win, pts, col);
};

// Maps a rune to its index in the built-in font: ASCII and Latin-1
// (æøå ÆØÅ é ü ...). Common typographic punctuation is mapped to the
// nearest ASCII; everything else becomes '?'.
fn glyph(r: rune) size = {
	const c = r: u32;
	if (c >= 32 && c <= 126) return (c - 32): size;
	if (c >= 160 && c <= 255) return (c - 160 + 95): size;
	const sub: rune = switch (r) {
	case '‘', '’', '‚', '′' => yield '\'';
	case '“', '”', '„', '″' => yield '"';
	case '–', '—', '−', '‐' => yield '-';
	case '…' => yield '.';
	case '•', '·' => yield '*';
	case '\t' => yield ' ';
	case => yield '?';
	};
	return (sub: u32 - 32): size;
};

// Number of characters (runes) in a string.
export fn runes(s: str) int = {
	let n = 0;
	let it = strings::iter(s);
	for (let _r => strings::next(&it)) n += 1;
	return n;
};

// Width in pixels of a string drawn with [[text_scaled]] at the given scale.
export fn text_width(s: str, scale: int) int = runes(s) * FONT_W * scale;

// Draws UTF-8 text with the built-in 8x16 font.
export fn text(win: *window, x: int, y: int, s: str, col: color) void =
	text_scaled(win, x, y, s, col, 1);

// Like [[text]], but each font pixel becomes a scale x scale block.
export fn text_scaled(win: *window, x: int, y: int, s: str, col: color, scale: int) void = {
	let cx = x;
	let it = strings::iter(s);
	for (let r => strings::next(&it)) {
		// Skip glyphs that are entirely outside the clip area.
		if (cx >= win.clip_x1 || y >= win.clip_y1
				|| y + FONT_H * scale <= win.clip_y0) {
			cx += FONT_W * scale;
			continue;
		};
		const g = glyph(r);
		for (let row = 0; row < FONT_H; row += 1) {
			const bits = font[g][row];
			if (bits == 0) continue;
			for (let col_ = 0; col_ < FONT_W; col_ += 1) {
				if (bits & (0x80u8 >> col_: u8) == 0) continue;
				if (scale == 1) {
					pixel(win, cx + col_, y + row, col);
				} else {
					rect(win, cx + col_ * scale, y + row * scale,
						scale, scale, col);
				};
			};
		};
		cx += FONT_W * scale;
	};
};
