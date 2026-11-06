// JADE — isometric drawing. The garden is a 13 x 13 grid seen from above
// at an angle: grid x runs toward the lower right of the screen, grid y
// toward the lower left, and z goes up. Everything that stands up is
// sorted back to front and drawn in that order (the painter's way).
use math;
use sort;
use viper;

def TW: f64 = 44.0;       // tile width on screen
def TH: f64 = 22.0;       // tile height on screen
def ZH: f64 = 26.0;       // one unit of height on screen
// Where grid corner (0, 0) lands (moves a little when the screen shakes).
let OX: f64 = 430.0;
let OY: f64 = 196.0;

fn iso(x: f64, y: f64, z: f64) (f64, f64) =
	(OX + (x - y) * TW / 2.0, OY + (x + y) * TH / 2.0 - z * ZH);

fn clamp8(v: f64) u32 = if (v < 0.0) 0 else if (v > 255.0) 255 else v: u32;

// Blends a filled ellipse over what is there (for shadows and glows).
fn blend_ellipse(win: *viper::window, cx: f64, cy: f64, rx: f64, ry: f64,
		col: u32, a: u32) void = {
	if (rx < 1.0 || ry < 1.0) return;
	const y0 = (cy - ry): int, y1 = (cy + ry): int + 1;
	const cr = (col >> 16) & 0xff, cg = (col >> 8) & 0xff, cb = col & 0xff;
	for (let y = y0; y <= y1; y += 1) {
		if (y < win.clip_y0 || y >= win.clip_y1) continue;
		const t = (y: f64 - cy) / ry;
		if (t * t >= 1.0) continue;
		const half = rx * math::sqrtf64(1.0 - t * t);
		let x0 = (cx - half): int, x1 = (cx + half): int;
		if (x0 < win.clip_x0) x0 = win.clip_x0;
		if (x1 >= win.clip_x1) x1 = win.clip_x1 - 1;
		for (let x = x0; x <= x1; x += 1) {
			let p = &win.pixels[(y * win.width + x): size];
			const r = ((*p >> 16) & 0xff) * (255 - a) + cr * a;
			const g = ((*p >> 8) & 0xff) * (255 - a) + cg * a;
			const b = (*p & 0xff) * (255 - a) + cb * a;
			*p = 0xff000000 | (r / 255) << 16 | (g / 255) << 8 | b / 255;
		};
	};
};

fn quad(win: *viper::window, a: (f64, f64), b: (f64, f64), c: (f64, f64),
		d: (f64, f64), col: u32) void = {
	const pts: [4](f64, f64) = [a, b, c, d];
	viper::polygon(win, pts, col);
};

// A box standing on cell (x, y), inset from the cell's edges, from height
// z0 to z1. Only the three faces you can see are drawn.
fn draw_box(win: *viper::window, x: f64, y: f64, inset: f64, z0: f64, z1: f64,
		top: u32, left: u32, right: u32) void = {
	const ax = x + inset, ay = y + inset;
	const bx = x + 1.0 - inset, by = y + 1.0 - inset;
	// Corners: A back, B right, C front, D left.
	quad(win, iso(ax, by, z1), iso(bx, by, z1), iso(bx, by, z0), iso(ax, by, z0), left);
	quad(win, iso(bx, by, z1), iso(bx, ay, z1), iso(bx, ay, z0), iso(bx, by, z0), right);
	quad(win, iso(ax, ay, z1), iso(bx, ay, z1), iso(bx, by, z1), iso(ax, by, z1), top);
};

// ---- The background, drawn once ----

fn make_background() viper::image = {
	let px: []u32 = alloc([0u32...], (W * H): size)!;
	for (let y = 0; y < H; y += 1) {
		// Night blue at the top, warm dusk at the horizon, mist below.
		const t = y: f64 / H: f64;
		const c = if (t < 0.55) viper::mix(0xff141238, 0xffb0506a, t / 0.55)
			else viper::mix(0xffb0506a, 0xff2a1a2e, (t - 0.55) / 0.45);
		for (let x = 0; x < W; x += 1) px[(y * W + x): size] = c;
	};
	let img = viper::image { w = W, h = H, pixels = px };
	// Stars.
	let seed = 12345u32;
	for (let i = 0; i < 90; i += 1) {
		seed = seed * 1103515245 + 12345;
		const x = ((seed >> 8) % W: u32): int;
		seed = seed * 1103515245 + 12345;
		const y = ((seed >> 8) % 220): int;
		px[(y * W + x): size] = if (i % 3 == 0) 0xffffffff else 0xffb8b0e0;
	};
	// The moon.
	disc(&img, 700.0, 96.0, 44.0, 0xfff8eccc);
	disc(&img, 686.0, 88.0, 10.0, 0xffe8dab8);
	disc(&img, 714.0, 112.0, 7.0, 0xffe8dab8);
	// Two rows of mountains.
	mountains(&img, 330.0, 90.0, 0.011, 0xff3a2246);
	mountains(&img, 380.0, 70.0, 0.017, 0xff2a1834);
	return img;
};

fn disc(img: *viper::image, cx: f64, cy: f64, r: f64, col: u32) void = {
	for (let y = (cy - r): int; y <= (cy + r): int; y += 1) {
		for (let x = (cx - r): int; x <= (cx + r): int; x += 1) {
			const dx = x: f64 - cx, dy = y: f64 - cy;
			if (dx * dx + dy * dy > r * r || x < 0 || y < 0 || x >= img.w || y >= img.h) continue;
			img.pixels[(y * img.w + x): size] = col;
		};
	};
};

fn mountains(img: *viper::image, base: f64, amp: f64, freq: f64, col: u32) void = {
	for (let x = 0; x < img.w; x += 1) {
		const fx = x: f64;
		const h = amp * (0.55 + 0.3 * math::sinf64(fx * freq)
			+ 0.15 * math::sinf64(fx * freq * 2.7 + 1.3)
			+ 0.1 * math::absf64(math::sinf64(fx * freq * 6.1)));
		for (let y = (base - h): int; y < img.h; y += 1) {
			if (y < 0) continue;
			img.pixels[(y * img.w + x): size] = col;
		};
	};
};

// ---- The garden ----

def C_GRASS1: u32 = 0xff3f8f62;
def C_GRASS2: u32 = 0xff378556;
def C_STONE: u32 = 0xff8a7a66;
def C_RED: u32 = 0xffb8322a;
def C_GOLD: u32 = 0xffe8b84a;
def C_JADE_ROOF: u32 = 0xff2f8f6a;

fn draw_floor(win: *viper::window, s: *state, clock: f64) void = {
	// The stone platform the garden stands on, walls included.
	const lo = -1.0, hi = N: f64 + 1.0;
	quad(win, iso(lo, hi, 0.0), iso(hi, hi, 0.0), iso(hi, hi, -0.9), iso(lo, hi, -0.9), 0xff5e5048);
	quad(win, iso(hi, hi, 0.0), iso(hi, lo, 0.0), iso(hi, lo, -0.9), iso(hi, hi, -0.9), 0xff40362f);
	quad(win, iso(lo, lo, 0.0), iso(hi, lo, 0.0), iso(hi, hi, 0.0), iso(lo, hi, 0.0), C_STONE);
	// A stone edge between the tiles and the wall.
	for (let y = 0; y < N; y += 1) for (let x = 0; x < N; x += 1) {
		const fx = x: f64, fy = y: f64;
		switch (s.grid[x][y]) {
		case cell::WATER =>
			const w = 0.5 + 0.5 * math::sinf64(clock * 2.0 + (x + y): f64 * 0.9);
			const c = viper::mix(0xff2a6a9a, 0xff3a86b4, w);
			quad(win, iso(fx, fy, -0.12), iso(fx + 1.0, fy, -0.12),
				iso(fx + 1.0, fy + 1.0, -0.12), iso(fx, fy + 1.0, -0.12), c);
			// A glint on the water.
			const (gx, gy) = iso(fx + 0.5, fy + 0.5, -0.12);
			viper::rect(win, (gx - 6.0 + w * 6.0): int, gy: int, 6, 1, 0xffa8dcff);
			// Lotus pads on some of it.
			if ((x * 7 + y * 3) % 4 == 0) {
				blend_ellipse(win, gx - 4.0, gy + 2.0, 8.0, 4.0, 0x3f9a4a, 255);
				viper::circle(win, (gx - 4.0): int, (gy + 1.0): int, 2, 0xffff9ad0);
			};
		case =>
			const c = if ((x + y) % 2 == 0) C_GRASS1 else C_GRASS2;
			quad(win, iso(fx, fy, 0.0), iso(fx + 1.0, fy, 0.0),
				iso(fx + 1.0, fy + 1.0, 0.0), iso(fx, fy + 1.0, 0.0), c);
		};
	};
};

// Something to draw in depth order.
type thing = struct {
	depth: f64,
	kind: u8,
	x: f64,
	y: f64,
	i: size,
};

def T_WALL: u8 = 0;
def T_PILLAR: u8 = 1;
def T_PEACH: u8 = 2;
def T_GOLD: u8 = 3;
def T_BODY: u8 = 4;
def T_HEAD: u8 = 5;

fn back_to_front(a: const *opaque, b: const *opaque) int = {
	const a = a: *thing, b = b: *thing;
	return if (a.depth < b.depth) -1 else if (a.depth > b.depth) 1 else 0;
};

// Where part i of the snake is, between its last cell and the next.
fn part_pos(s: *state, i: size, f: f64) (f64, f64) = {
	const (x0, y0) = s.prev[i];
	const (x1, y1) = s.body[i];
	return (x0: f64 + (x1 - x0): f64 * f + 0.5, y0: f64 + (y1 - y0): f64 * f + 0.5);
};

fn draw_garden(win: *viper::window, s: *state, f: f64, clock: f64, dead: bool) void = {
	draw_floor(win, s, clock);
	if (!dead) draw_ahead(win, s);
	let things: []thing = [];
	defer free(things);
	// The temple wall around the garden.
	for (let i = -1; i <= N; i += 1) {
		append(things, thing { depth = (i - 1): f64, kind = T_WALL, x = i: f64, y = -1.0, ... })!;
		if (i >= 0) append(things, thing { depth = (i - 1): f64, kind = T_WALL, x = -1.0, y = i: f64, ... })!;
		append(things, thing { depth = (i + N): f64, kind = T_WALL, x = i: f64, y = N: f64, ... })!;
		if (i < N) append(things, thing { depth = (i + N): f64, kind = T_WALL, x = N: f64, y = i: f64, ... })!;
	};
	for (let y = 0; y < N; y += 1) for (let x = 0; x < N; x += 1) {
		if (s.grid[x][y] == cell::PILLAR) {
			append(things, thing { depth = (x + y): f64, kind = T_PILLAR,
				x = x: f64, y = y: f64, ... })!;
		};
	};
	append(things, thing { depth = (s.food.0 + s.food.1): f64 + 1.0, kind = T_PEACH,
		x = s.food.0: f64 + 0.5, y = s.food.1: f64 + 0.5, ... })!;
	if (s.gold_t > 0.0) {
		append(things, thing { depth = (s.gold.0 + s.gold.1): f64 + 1.0, kind = T_GOLD,
			x = s.gold.0: f64 + 0.5, y = s.gold.1: f64 + 0.5, ... })!;
	};
	// The snake, with an extra ball between parts so she looks whole.
	for (let i = 0z; i < s.n; i += 1) {
		const (x, y) = part_pos(s, i, f);
		append(things, thing { depth = x + y, kind = if (i == 0) T_HEAD else T_BODY,
			x = x, y = y, i = i * 2 })!;
		if (i + 1 < s.n) {
			const (x2, y2) = part_pos(s, i + 1, f);
			const mx = (x + x2) / 2.0, my = (y + y2) / 2.0;
			append(things, thing { depth = mx + my, kind = T_BODY, x = mx, y = my,
				i = i * 2 + 1 })!;
		};
	};
	sort::sort(things, size(thing), &back_to_front)!;

	// Shadows first, on the ground under everything.
	for (let t &.. things) {
		if (t.kind < T_PEACH) continue;
		const (sx, sy) = iso(t.x, t.y, 0.0);
		const r = if (t.kind == T_HEAD) 13.0 else 10.0;
		blend_ellipse(win, sx, sy, r, r * 0.5, 0x0a1a10, 110);
	};
	for (let t &.. things) switch (t.kind) {
	case T_WALL =>
		draw_box(win, t.x, t.y, 0.0, 0.0, 0.5, 0xffd8a440, 0xffa0281f, 0xff74201a);
	case T_PILLAR =>
		draw_pillar(win, t.x, t.y);
	case T_PEACH =>
		draw_peach(win, t.x, t.y, clock);
	case T_GOLD =>
		draw_dumpling(win, t.x, t.y, clock, s.gold_t);
	case T_BODY =>
		draw_part(win, s, t, dead);
	case T_HEAD =>
		draw_head(win, s, t.x, t.y, clock, dead);
	case => void;
	};

	// Where a pillar hides her, show her through it, faintly.
	if (!dead) for (let i = 0z; i < s.n; i += 1) {
		const (x, y) = part_pos(s, i, f);
		if (!behind_pillar(s, (x - 0.5 + 0.5): int, (y - 0.5 + 0.5): int)) continue;
		const (sx, sy) = iso(x, y, if (i == 0) 0.5 else 0.42);
		const r = if (i == 0) 12.0 else 9.0 - i: f64 / s.n: f64 * 4.0;
		blend_ellipse(win, sx, sy, r, r, 0x7fe4b4, 110);
	};

	// Markers over the food, on top of everything, so a peach behind the
	// snake or a wall can always be found.
	food_marker(win, s.food.0: f64 + 0.5, s.food.1: f64 + 0.5, clock, 0xffff8a6a);
	if (s.gold_t > 0.0) {
		food_marker(win, s.gold.0: f64 + 0.5, s.gold.1: f64 + 0.5, clock + 1.0, 0xffffd23a);
	};
};

fn food_marker(win: *viper::window, x: f64, y: f64, clock: f64, col: u32) void = {
	const bob = math::sinf64(clock * 4.0) * 0.12;
	const (tx, ty) = iso(x, y, 1.75 + bob);
	const (_, py) = iso(x, y, 0.9);
	// A dotted line down toward the food.
	for (let yy = ty + 10.0; yy < py; yy += 6.0) {
		viper::rect(win, tx: int - 1, yy: int, 2, 2, col);
	};
	const tri: [3](f64, f64) = [(tx - 9.0, ty - 8.0), (tx + 9.0, ty - 8.0), (tx, ty + 6.0)];
	const out: [3](f64, f64) = [(tx - 12.0, ty - 10.0), (tx + 12.0, ty - 10.0), (tx, ty + 9.0)];
	viper::polygon(win, out, 0xff1a1010);
	viper::polygon(win, tri, col);
};

// Outlines the cell she is about to enter: green if it's free, red if not.
fn draw_ahead(win: *viper::window, s: *state) void = {
	const d = if (s.nq > 0) s.queue[0] else s.d;
	const (dx, dy) = dvec(d);
	const x = s.body[0].0 + dx, y = s.body[0].1 + dy;
	if (!inside(x, y)) return;
	const col: u32 = if (blocked(s, x, y, true)) 0xffff5a4a else 0xffa8f0c8;
	const fx = x: f64, fy = y: f64;
	const a = iso(fx, fy, 0.01), b = iso(fx + 1.0, fy, 0.01);
	const c = iso(fx + 1.0, fy + 1.0, 0.01), e = iso(fx, fy + 1.0, 0.01);
	const pts = [a, b, c, e, a];
	for (let i = 0z; i < 4; i += 1) {
		viper::line(win, pts[i].0: int, pts[i].1: int, pts[i + 1].0: int, pts[i + 1].1: int, col);
		viper::line(win, pts[i].0: int, pts[i].1: int + 1, pts[i + 1].0: int, pts[i + 1].1: int + 1, col);
	};
};

fn draw_pillar(win: *viper::window, x: f64, y: f64) void = {
	// A stone foot, the red lacquered pillar, a gold band, a jade roof.
	draw_box(win, x, y, 0.1, 0.0, 0.18, 0xffb0a088, 0xff807060, 0xff605040);
	draw_box(win, x, y, 0.22, 0.18, 1.1, 0xffd04a3a, C_RED, 0xff7a1e1a);
	draw_box(win, x, y, 0.2, 0.86, 0.96, C_GOLD, 0xffc08a2a, 0xff8a5e1a);
	draw_box(win, x, y, 0.02, 1.1, 1.22, 0xff4ab88a, C_JADE_ROOF, 0xff1e6048);
	// The roof's point.
	const (tx, ty) = iso(x + 0.5, y + 0.5, 1.6);
	const pts: [3](f64, f64) = [(tx, ty), iso(x + 1.0, y + 1.0, 1.22), iso(x + 0.0, y + 1.0, 1.22)];
	viper::polygon(win, pts, C_JADE_ROOF);
	const pts2: [3](f64, f64) = [(tx, ty), iso(x + 1.0, y + 0.0, 1.22), iso(x + 1.0, y + 1.0, 1.22)];
	viper::polygon(win, pts2, 0xff1e6048);
	viper::circle(win, tx: int, ty: int, 2, C_GOLD);
};

// A shaded ball: dark rim, body colour, a lighter top and a shine.
fn ball(win: *viper::window, x: f64, y: f64, r: f64, dark: u32, base: u32, light: u32) void = {
	viper::circle(win, x: int, y: int, r: int, dark);
	viper::circle(win, (x - r * 0.08): int, (y - r * 0.1): int, (r * 0.86): int, base);
	viper::circle(win, (x - r * 0.25): int, (y - r * 0.32): int, (r * 0.45): int, light);
	viper::circle(win, (x - r * 0.35): int, (y - r * 0.45): int, (r * 0.16): int, 0xffeefff6);
};

fn draw_part(win: *viper::window, s: *state, t: *thing, dead: bool) void = {
	// Thinner toward the tail.
	const k = t.i: f64 / (s.n * 2): f64;
	const r = 10.0 - k * 4.0;
	const (sx, sy) = iso(t.x, t.y, 0.42);
	const stripe = (t.i / 2) % 4 == 2;
	if (dead) {
		ball(win, sx, sy, r, 0xff3a3a32, 0xff6a7064, 0xff9aa094);
	} else if (stripe) {
		ball(win, sx, sy, r, 0xff0e4a30, 0xff2a9a66, 0xff6ad8a0);
		// Gold markings down her back.
		viper::circle(win, sx: int, (sy - r * 0.55): int, (r * 0.28): int, C_GOLD);
	} else {
		ball(win, sx, sy, r, 0xff0e4a30, 0xff2fae74, 0xff7fe4b4);
	};
};

fn draw_head(win: *viper::window, s: *state, x: f64, y: f64, clock: f64, dead: bool) void = {
	const (sx, sy) = iso(x, y, 0.5);
	const r = 13.0;
	if (dead) {
		ball(win, sx, sy, r, 0xff3a3a32, 0xff6a7064, 0xff9aa094);
	} else {
		ball(win, sx, sy, r, 0xff0e4a30, 0xff34b87c, 0xff8aecc0);
	};
	// Which way she faces, on screen.
	const (dx, dy) = dvec(s.d);
	let fx = (dx - dy): f64 * TW / 2.0, fy = (dx + dy): f64 * TH / 2.0;
	const l = math::sqrtf64(fx * fx + fy * fy);
	fx /= l;
	fy /= l;
	const px = -fy, py = fx;   // sideways
	// Her tongue flicks now and then.
	if (!dead && math::sinf64(clock * 5.0) > 0.55) {
		const tx = sx + fx * (r + 9.0), ty = sy + fy * (r + 9.0) + 3.0;
		viper::line(win, (sx + fx * r): int, (sy + fy * r + 3.0): int, tx: int, ty: int, 0xffe03050);
		viper::line(win, tx: int, ty: int, (tx + fx * 4.0 + px * 3.0): int,
			(ty + fy * 4.0 + py * 3.0): int, 0xffe03050);
		viper::line(win, tx: int, ty: int, (tx + fx * 4.0 - px * 3.0): int,
			(ty + fy * 4.0 - py * 3.0): int, 0xffe03050);
	};
	// Eyes, looking ahead. Facing away from us, they're hidden behind.
	const away = fy < -0.1;
	for (let side = -1.0; side <= 1.0; side += 2.0) {
		const ex = sx + fx * r * 0.45 + px * r * 0.48 * side;
		const ey = sy + fy * r * 0.45 + py * r * 0.48 * side - r * 0.3;
		if (away && ey > sy - r * 0.2) continue;
		if (dead) {
			viper::line(win, (ex - 3.0): int, (ey - 3.0): int, (ex + 3.0): int, (ey + 3.0): int, 0xff1a1a1a);
			viper::line(win, (ex - 3.0): int, (ey + 3.0): int, (ex + 3.0): int, (ey - 3.0): int, 0xff1a1a1a);
			continue;
		};
		viper::circle(win, ex: int, ey: int, 4, 0xfffff8e0);
		viper::circle(win, (ex + fx * 1.5): int, (ey + fy * 1.5): int, 2, 0xff101810);
	};
	// A little gold crest on her head.
	if (!dead) {
		const cx = sx - fx * r * 0.2, cy = sy - fy * r * 0.2 - r * 0.85;
		const pts: [3](f64, f64) = [(cx, cy - 6.0), (cx - 4.0, cy + 2.0), (cx + 4.0, cy + 2.0)];
		viper::polygon(win, pts, C_GOLD);
	};
};

fn draw_peach(win: *viper::window, x: f64, y: f64, clock: f64) void = {
	const bob = 0.45 + math::sinf64(clock * 3.0) * 0.08;
	const (sx, sy) = iso(x, y, bob);
	ball(win, sx, sy, 9.0, 0xffc04a3a, 0xffff9a6a, 0xffffd0a8);
	viper::circle(win, (sx + 3.0): int, (sy + 2.0): int, 3, 0xffff6a72);
	// A leaf and a stem.
	viper::line(win, sx: int, (sy - 9.0): int, (sx + 1.0): int, (sy - 13.0): int, 0xff5a3a1a);
	const leaf: [4](f64, f64) = [(sx + 1.0, sy - 12.0), (sx + 6.0, sy - 16.0),
		(sx + 11.0, sy - 13.0), (sx + 5.0, sy - 10.0)];
	viper::polygon(win, leaf, 0xff4aa84a);
};

fn draw_dumpling(win: *viper::window, x: f64, y: f64, clock: f64, left: f64) void = {
	// Blinks when it's about to go.
	if (left < 2.0 && math::sinf64(clock * 18.0) < 0.0) return;
	const bob = 0.5 + math::sinf64(clock * 4.0) * 0.1;
	const (sx, sy) = iso(x, y, bob);
	const glow = 16.0 + math::sinf64(clock * 6.0) * 3.0;
	blend_ellipse(win, sx, sy, glow, glow, 0xffd86a, 90);
	ball(win, sx, sy + 2.0, 10.0, 0xffc8a060, 0xfffff2d8, 0xffffffff);
	// The pleats on top, and a gold dot.
	for (let i = -2; i <= 2; i += 1) {
		viper::line(win, sx: int, (sy - 6.0): int, (sx + i: f64 * 3.0): int, (sy - 1.0): int, 0xffc8a060);
	};
	viper::circle(win, sx: int, (sy - 7.0): int, 2, C_GOLD);
};
