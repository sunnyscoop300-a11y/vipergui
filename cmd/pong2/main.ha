// Golden Pong 3D 2 — DEMO, in Cyberpunk 7000 style.
// You look down a neon tunnel from behind your see-through paddle. At the
// far end ZEBRA AI 7000 defends with its striped bat, and it learns where
// you like to shoot. Move your paddle while you hit to put spin on the
// ball and make it curve.
//
// Mouse (or the arrow keys / WASD) moves your paddle. Click / Space
// serves. Esc quits.
use fmt;
use math;
use strings;
use viper;

def W: int = 800;
def H: int = 600;
def CX: f64 = 400.0;
def CY: f64 = 300.0;
def F: f64 = 380.0;        // focal length: screen px per world unit at z = 0
def Z0: f64 = 1.0;         // camera distance to the near end of the tunnel
def DEPTH: f64 = 6.0;      // tunnel length
def HX: f64 = 1.0;         // tunnel half width
def HY: f64 = 0.75;        // tunnel half height
def R: f64 = 0.085;        // ball radius
def PW: f64 = 0.34;        // paddle half width
def PH: f64 = 0.25;        // paddle half height
def SEGS: int = 12;        // wall panels along the tunnel
def WIN_SCORE: int = 7;
def TRAIL: size = 12;
def FRAMES: size = 6;      // frames in each of the two animations
def GIF_T: f64 = 0.15;     // seconds per animation frame
def BASS_LOOP: f64 = 1.44; // length of the bass line (8 x 0.18 s)

def CYAN: viper::color = 0xff2ee6ff;
def PINK: viper::color = 0xffff2fd0;
def GOLD: viper::color = 0xffffc83a;
def DARK: viper::color = 0xff050816;
def WALL_A: viper::color = 0xff1f63d8;
def WALL_B: viper::color = 0xff1852be;
def GRID: viper::color = 0xff0b2c78;

type state = enum { TITLE, INTRO, READY, PLAYING, POINT, OVER };

type game = struct {
	st: state,
	t: f64,            // seconds since start
	st_t: f64,         // seconds in the current state
	bx: f64,           // the ball and its speed
	by: f64,
	bz: f64,
	vx: f64,
	vy: f64,
	vz: f64,
	spx: f64,          // spin: bends the ball sideways / up-down
	spy: f64,
	trail_x: [TRAIL]f64,
	trail_y: [TRAIL]f64,
	trail_z: [TRAIL]f64,
	px: f64,           // your paddle (z = 0)
	py: f64,
	pvx: f64,          // how fast your paddle moves (for spin)
	pvy: f64,
	zx: f64,           // ZEBRA AI 7000's bat (z = DEPTH)
	zy: f64,
	tx: f64,           // where the AI is heading
	ty: f64,
	me: int,
	ai: int,
	you_serve: bool,
	msg: str,
	// The AI's memory: how often your shots went to each corner.
	seen: [4]int,
	last_zone: int,
	streak: int,
	learn_msg: str,
	learn_t: f64,
	flash: f64,        // your paddle lights up after a hit
	sfx: int,          // 0 quiet, 1 paddle, 2 wall, 3 your point, 4 AI point, 5 learned
	rng: u32,
};

type pics = struct {
	arena: [FRAMES]viper::image,
	arena_ok: [FRAMES]bool,
	zebra: [FRAMES]viper::image,
	zebra_ok: [FRAMES]bool,
	glow_gold: viper::image,
	glow_pink: viper::image,
	paddle: viper::image,
	paddle_hit: viper::image,
};

const TAUNTS: [4]str = [
	"BEREGNET.",
	"FORUDSIGELIGT, MENNESKE.",
	"99,7% SANDSYNLIGHED.",
	"OPDATERER DATABASE...",
];

const ZONE_MSG: [4]str = [
	"MOENSTER FUNDET: OPPE TIL VENSTRE!",
	"MOENSTER FUNDET: OPPE TIL HOEJRE!",
	"MOENSTER FUNDET: NEDE TIL VENSTRE!",
	"MOENSTER FUNDET: NEDE TIL HOEJRE!",
];

const INTRO_LINES: [6]str = [
	"ZEBRA  7000",
	"ONLINE.",
	"Jeg har analyseret",
	"1.000.000 kampe.",
	"Jeg laerer dine skud.",
	"Du kan ikke vinde.",
];

// --- small helpers ---

fn absf(x: f64) f64 = if (x < 0.0) -x else x;
fn minf(a: f64, b: f64) f64 = if (a < b) a else b;
fn clampf(x: f64, lo: f64, hi: f64) f64 =
	if (x < lo) lo else if (x > hi) hi else x;

fn rnd(g: *game) f64 = {
	g.rng ^= g.rng << 13;
	g.rng ^= g.rng >> 17;
	g.rng ^= g.rng << 5;
	return g.rng: f64 / 4294967295.0;
};

// 3D -> 2D: x right, y down, z into the screen.
fn sx(x: f64, z: f64) f64 = CX + x * F / (z + Z0);
fn sy(y: f64, z: f64) f64 = CY + y * F / (z + Z0);
fn scale(z: f64) f64 = F / (z + Z0);

// Far things fade into the dark: that is what gives the tunnel depth.
fn fog(c: viper::color, z: f64) viper::color =
	viper::mix(c, DARK, clampf(z / DEPTH, 0.0, 1.0) * 0.7);

fn set_state(g: *game, s: state) void = {
	g.st = s;
	g.st_t = 0.0;
};

// Which corner of the far wall a point is in: 0 top left, 1 top right,
// 2 bottom left, 3 bottom right.
fn zone_of(x: f64, y: f64) int = (if (x > 0.0) 1 else 0) + (if (y > 0.0) 2 else 0);

// --- the game ---

fn new_match(g: *game) void = {
	g.me = 0;
	g.ai = 0;
	g.you_serve = true;
	g.zx = 0.0;
	g.zy = 0.0;
	g.tx = 0.0;
	g.ty = 0.0;
	g.seen = [0, 0, 0, 0];
	g.last_zone = -1;
	g.streak = 0;
	g.learn_t = 0.0;
	g.msg = "";
};

// Puts the ball on the serving paddle.
fn hold_ball(g: *game) void = {
	if (g.you_serve) {
		g.bx = g.px;
		g.by = g.py;
		g.bz = 0.1;
	} else {
		g.bx = g.zx;
		g.by = g.zy;
		g.bz = DEPTH - 0.1;
	};
	g.spx = 0.0;
	g.spy = 0.0;
	for (let i = 0z; i < TRAIL; i += 1) {
		g.trail_x[i] = g.bx;
		g.trail_y[i] = g.by;
		g.trail_z[i] = g.bz;
	};
};

fn launch(g: *game) void = {
	const sp = 3.6 + 0.15 * (g.me + g.ai): f64;
	g.vz = if (g.you_serve) sp else -sp;
	g.vx = (rnd(g) - 0.5) * 1.4;
	g.vy = (rnd(g) - 0.5) * 1.0;
	g.msg = "";
	if (g.you_serve) aim_ai(g);
	set_state(g, state::PLAYING);
};

// One small physics step of the ball: spin, movement and the walls.
// Returns true if it bounced off a wall.
fn ball_step(x: *f64, y: *f64, z: *f64, vx: *f64, vy: *f64, vz: f64,
		spx: *f64, spy: *f64, dt: f64) bool = {
	*vx += *spx * dt;
	*vy += *spy * dt;
	*spx *= 1.0 - minf(1.0, 0.9 * dt);
	*spy *= 1.0 - minf(1.0, 0.9 * dt);
	*x += *vx * dt;
	*y += *vy * dt;
	*z += vz * dt;
	let bounced = false;
	if (*x < -HX + R) {
		*x = -HX + R;
		*vx = absf(*vx);
		*spx *= 0.5;
		bounced = true;
	};
	if (*x > HX - R) {
		*x = HX - R;
		*vx = -absf(*vx);
		*spx *= 0.5;
		bounced = true;
	};
	if (*y < -HY + R) {
		*y = -HY + R;
		*vy = absf(*vy);
		*spy *= 0.5;
		bounced = true;
	};
	if (*y > HY - R) {
		*y = HY - R;
		*vy = -absf(*vy);
		*spy *= 0.5;
		bounced = true;
	};
	return bounced;
};

// Where the ball will reach the far wall, spin and bounces included.
fn predict(g: *game) (f64, f64) = {
	let x = g.bx, y = g.by, z = g.bz, vx = g.vx, vy = g.vy;
	let spx = g.spx, spy = g.spy;
	for (let i = 0; i < 3000 && z < DEPTH; i += 1) {
		ball_step(&x, &y, &z, &vx, &vy, g.vz, &spx, &spy, 1.0 / 120.0);
	};
	return (x, y);
};

// ZEBRA AI 7000 decides where to go. It guesses better as the match goes
// on, and much better in a corner where you have shot before.
fn aim_ai(g: *game) void = {
	const (lx, ly) = predict(g);
	let err = 0.45 - 0.04 * (g.me + g.ai): f64;
	if (err < 0.08) err = 0.08;
	if (g.seen[zone_of(lx, ly)] >= 2) err *= 0.35;
	g.tx = clampf(lx + (rnd(g) - 0.5) * 2.0 * err, -HX + PW, HX - PW);
	g.ty = clampf(ly + (rnd(g) - 0.5) * 2.0 * err * 0.75, -HY + PH, HY - PH);
};

// The AI remembers which corner your shot is going to.
fn learn(g: *game) void = {
	const (lx, ly) = predict(g);
	const zone = zone_of(lx, ly);
	g.seen[zone] += 1;
	if (zone == g.last_zone) g.streak += 1 else g.streak = 1;
	g.last_zone = zone;
	if (g.streak == 2) {
		g.learn_msg = ZONE_MSG[zone];
		g.learn_t = 2.2;
		g.sfx = 5;
	};
};

// While it waits, the AI guards the corner you shoot at the most.
fn favourite(g: *game) (f64, f64) = {
	let best = -1, most = 1;
	for (let i = 0; i < 4; i += 1) {
		if (g.seen[i] > most) {
			most = g.seen[i];
			best = i;
		};
	};
	if (best < 0) return (0.0, 0.0);
	const x = if (best % 2 == 1) HX / 2.0 else -HX / 2.0;
	const y = if (best >= 2) HY / 2.0 else -HY / 2.0;
	return (x, y);
};

fn point(g: *game, mine: bool) void = {
	if (mine) {
		g.me += 1;
		g.msg = "POINT TIL DIG!";
		g.sfx = 3;
	} else {
		g.msg = TAUNTS[g.ai: size % len(TAUNTS)];
		g.ai += 1;
		g.sfx = 4;
	};
	g.you_serve = !mine;
	set_state(g, state::POINT);
};

fn step_ball(g: *game, dt: f64) void = {
	for (let i = TRAIL - 1; i > 0; i -= 1) {
		g.trail_x[i] = g.trail_x[i - 1];
		g.trail_y[i] = g.trail_y[i - 1];
		g.trail_z[i] = g.trail_z[i - 1];
	};
	g.trail_x[0] = g.bx;
	g.trail_y[0] = g.by;
	g.trail_z[0] = g.bz;

	if (ball_step(&g.bx, &g.by, &g.bz, &g.vx, &g.vy, g.vz, &g.spx, &g.spy, dt)) {
		g.sfx = 2;
	};

	// Your end. Where you hit sets the angle; moving the paddle adds spin.
	if (g.bz <= 0.0 && g.vz < 0.0) {
		if (absf(g.bx - g.px) <= PW + R && absf(g.by - g.py) <= PH + R) {
			g.bz = 0.0;
			g.vz = clampf(-g.vz * 1.05, 3.0, 9.0);
			g.vx = clampf(g.vx * 0.5 + (g.bx - g.px) * 4.0, -3.0, 3.0);
			g.vy = clampf(g.vy * 0.5 + (g.by - g.py) * 4.0, -3.0, 3.0);
			g.spx = clampf(g.pvx * 0.8, -5.0, 5.0);
			g.spy = clampf(g.pvy * 0.8, -5.0, 5.0);
			g.flash = 0.25;
			g.sfx = 1;
			learn(g);
			aim_ai(g);
		} else {
			point(g, false);
		};
	};
	// ZEBRA AI 7000's end. Later in the match it puts spin on too.
	if (g.bz >= DEPTH && g.vz > 0.0) {
		if (absf(g.bx - g.zx) <= PW + R && absf(g.by - g.zy) <= PH + R) {
			g.bz = DEPTH;
			g.vz = -g.vz;
			g.vx = clampf(g.vx * 0.5 + (g.bx - g.zx) * 3.0, -3.0, 3.0);
			g.vy = clampf(g.vy * 0.5 + (g.by - g.zy) * 3.0, -3.0, 3.0);
			const curve = 0.4 * (g.me + g.ai): f64;
			g.spx = (rnd(g) - 0.5) * curve;
			g.spy = (rnd(g) - 0.5) * curve;
			g.sfx = 1;
		} else {
			point(g, true);
		};
	};
};

fn move_ai(g: *game, dt: f64) void = {
	let speed = 1.2 + 0.1 * (g.me + g.ai): f64;
	if (speed > 2.4) speed = 2.4;
	let (gx, gy) = favourite(g);
	if (g.st == state::PLAYING && g.vz > 0.0) {
		gx = g.tx;
		gy = g.ty;
	};
	g.zx = clampf(g.zx + clampf(gx - g.zx, -speed * dt, speed * dt), -HX + PW, HX - PW);
	g.zy = clampf(g.zy + clampf(gy - g.zy, -speed * dt, speed * dt), -HY + PH, HY - PH);
};

fn move_player(win: *viper::window, g: *game, dt: f64) void = {
	static let lmx = -1, lmy = -1;
	static let mouse_on = true;
	const ox = g.px, oy = g.py;
	if (win.mouse_x != lmx || win.mouse_y != lmy) mouse_on = true;
	lmx = win.mouse_x;
	lmy = win.mouse_y;
	const left = viper::key_down(win, viper::key::LEFT) || viper::key_down(win, viper::key::A);
	const right = viper::key_down(win, viper::key::RIGHT) || viper::key_down(win, viper::key::D);
	const up = viper::key_down(win, viper::key::UP) || viper::key_down(win, viper::key::W);
	const down = viper::key_down(win, viper::key::DOWN) || viper::key_down(win, viper::key::S);
	if (left || right || up || down) mouse_on = false;
	if (left) g.px -= 2.2 * dt;
	if (right) g.px += 2.2 * dt;
	if (up) g.py -= 2.2 * dt;
	if (down) g.py += 2.2 * dt;
	if (mouse_on && win.mouse_x >= 0 && win.mouse_y >= 0) {
		g.px = (win.mouse_x: f64 - CX) / F * Z0;
		g.py = (win.mouse_y: f64 - CY) / F * Z0;
	};
	g.px = clampf(g.px, -HX + PW, HX - PW);
	g.py = clampf(g.py, -HY + PH, HY - PH);
	// The paddle's speed, smoothed a little, gives the ball its spin.
	if (dt > 0.0) {
		g.pvx += ((g.px - ox) / dt - g.pvx) * minf(1.0, dt * 12.0);
		g.pvy += ((g.py - oy) / dt - g.pvy) * minf(1.0, dt * 12.0);
	};
};

fn update(win: *viper::window, g: *game) void = {
	const dt = viper::delta(win);
	g.t += dt;
	g.st_t += dt;
	if (g.learn_t > 0.0) g.learn_t -= dt;
	if (g.flash > 0.0) g.flash -= dt;
	const go = viper::mouse_pressed(win)
		|| viper::key_pressed(win, viper::key::SPACE)
		|| viper::key_pressed(win, viper::key::RETURN);
	move_player(win, g, dt);

	switch (g.st) {
	case state::TITLE =>
		if (go) set_state(g, state::INTRO);
	case state::INTRO =>
		if (go && g.st_t > 0.3) {
			new_match(g);
			set_state(g, state::READY);
		};
	case state::READY =>
		move_ai(g, dt);
		hold_ball(g);
		if (g.you_serve) {
			if (go) launch(g);
		} else if (g.st_t > 1.0) {
			launch(g);
		};
	case state::PLAYING =>
		step_ball(g, dt);
		move_ai(g, dt);
	case state::POINT =>
		move_ai(g, dt);
		if (g.st_t > 1.4) {
			if (g.me >= WIN_SCORE || g.ai >= WIN_SCORE) {
				g.msg = if (g.me >= WIN_SCORE) "DU SLOG ZEBRA  7000!"
					else "ZEBRA  7000 VANDT. SYSTEM UOVERVINDELIG.";
				set_state(g, state::OVER);
			} else {
				set_state(g, state::READY);
			};
		};
	case state::OVER =>
		if (go && g.st_t > 0.8) {
			new_match(g);
			set_state(g, state::READY);
		};
	};
};

// --- pictures ---

fn load_scaled(path: str, w: int, h: int) (viper::image | void) = {
	match (viper::load_png(path)) {
	case let loaded: viper::image =>
		let big = loaded;
		defer viper::image_free(&big);
		match (viper::resize(&big, w, h)) {
		case let small: viper::image =>
			return small;
		case nomem =>
			return;
		};
	case viper::imgerror =>
		return;
	};
};

// A soft round glow: col in the middle, fading to transparent.
fn make_glow(r: int, col: viper::color) viper::image = {
	const n = 2 * r;
	let px: []u32 = alloc([0u32...], (n * n): size)!;
	for (let y = 0; y < n; y += 1) {
		for (let x = 0; x < n; x += 1) {
			const dx = (x - r): f64 + 0.5, dy = (y - r): f64 + 0.5;
			const d = math::sqrtf64(dx * dx + dy * dy) / r: f64;
			if (d >= 1.0) continue;
			const a = ((1.0 - d) * (1.0 - d) * 170.0): u32;
			px[(y * n + x): size] = (a << 24) | (col & 0xffffff);
		};
	};
	return viper::image { w = n, h = n, pixels = px };
};

// Your see-through paddle: a blue glass panel with a glowing grid, a
// bright frame and a target square in the middle.
fn make_paddle(bright: bool) viper::image = {
	const w = (2.0 * PW * F / Z0): int, h = (2.0 * PH * F / Z0): int;
	let px: []u32 = alloc([0u32...], (w * h): size)!;
	const glass: u32 = if (bright) 0x6040c8ff else 0x402a8cff;
	const grid: u32 = if (bright) 0xd060e0ff else 0x9040a8ff;
	const frame: u32 = 0xff2ee6ff;
	for (let y = 0; y < h; y += 1) {
		for (let x = 0; x < w; x += 1) {
			let c = glass;
			if (x % (w / 4) == 0 || y % (h / 3) == 0) c = grid;
			if (x < 3 || y < 3 || x >= w - 3 || y >= h - 3) c = frame;
			// the target square in the middle
			const dx = absf((x - w / 2): f64), dy = absf((y - h / 2): f64);
			if ((dx <= 14.0 && dy <= 14.0) && (dx >= 11.0 || dy >= 11.0)) c = frame;
			if (dx <= 4.0 && dy <= 4.0) c = frame;
			px[(y * w + x): size] = c;
		};
	};
	return viper::image { w = w, h = h, pixels = px };
};

fn load_pics(p: *pics) void = {
	let buf: [64]u8 = [0...];
	for (let i = 0z; i < FRAMES; i += 1) {
		const a = fmt::bsprintf(buf, "assets/pong2/arena-{}.png", i)!;
		match (load_scaled(a, 800, 800)) {
		case let img: viper::image =>
			p.arena[i] = img;
			p.arena_ok[i] = true;
		case void => void;
		};
		const z = fmt::bsprintf(buf, "assets/pong2/zebra7000-{}.png", i)!;
		match (load_scaled(z, 420, 420)) {
		case let img: viper::image =>
			p.zebra[i] = img;
			p.zebra_ok[i] = true;
		case void => void;
		};
	};
	p.glow_gold = make_glow(30, GOLD);
	p.glow_pink = make_glow(48, PINK);
	p.paddle = make_paddle(false);
	p.paddle_hit = make_paddle(true);
};

fn free_pics(p: *pics) void = {
	for (let i = 0z; i < FRAMES; i += 1) {
		if (p.arena_ok[i]) viper::image_free(&p.arena[i]);
		if (p.zebra_ok[i]) viper::image_free(&p.zebra[i]);
	};
	viper::image_free(&p.glow_gold);
	viper::image_free(&p.glow_pink);
	viper::image_free(&p.paddle);
	viper::image_free(&p.paddle_hit);
};

// --- drawing ---

fn centered(win: *viper::window, y: int, s: str, sc: int, col: viper::color) void = {
	const x = (W - viper::text_width(s, sc)) / 2;
	viper::text_scaled(win, x + 2, y + 2, s, viper::rgb(0, 0, 0), sc);
	viper::text_scaled(win, x, y, s, col, sc);
};

fn glow_at(win: *viper::window, img: *viper::image, x: f64, y: f64) void =
	viper::draw_image(win, img, x: int - img.w / 2, y: int - img.h / 2);

// A filled 3D quad from four (x, y, z) corners.
fn quad(win: *viper::window, a: (f64, f64, f64), b: (f64, f64, f64),
		c: (f64, f64, f64), d: (f64, f64, f64), col: viper::color) void = {
	const pts: [4](f64, f64) = [
		(sx(a.0, a.2), sy(a.1, a.2)), (sx(b.0, b.2), sy(b.1, b.2)),
		(sx(c.0, c.2), sy(c.1, c.2)), (sx(d.0, d.2), sy(d.1, d.2))
	];
	viper::polygon(win, pts, col);
};

// A 3D line, two pixels thick.
fn line3(win: *viper::window, a: (f64, f64, f64), b: (f64, f64, f64), col: viper::color) void = {
	const ax = sx(a.0, a.2): int, ay = sy(a.1, a.2): int;
	const bx = sx(b.0, b.2): int, by = sy(b.1, b.2): int;
	viper::line(win, ax, ay, bx, by, col);
	viper::line(win, ax + 1, ay, bx + 1, by, col);
};

// The outline of the tunnel at depth z.
fn ring(win: *viper::window, z: f64, col: viper::color) void = {
	const x0 = sx(-HX, z): int, x1 = sx(HX, z): int;
	const y0 = sy(-HY, z): int, y1 = sy(HY, z): int;
	viper::outline(win, x0, y0, x1 - x0, y1 - y0, col);
};

// A shaded sphere: rings that get lighter towards the top left.
fn sphere(win: *viper::window, cx: f64, cy: f64, r: f64, base: viper::color, light: viper::color) void = {
	for (let k = 0; k < 7; k += 1) {
		const f = k: f64 / 7.0;
		const rr = r * (1.0 - f * 0.85);
		const off = (r - rr) * 0.55;
		viper::circle(win, (cx - off): int, (cy - off): int, rr: int,
			viper::mix(viper::mix(base, DARK, 0.25), light, f));
	};
};

// The neon decoration down the middle of the floor (y = HY) or the
// ceiling (y = -HY): a pink flare, a cyan strip, chevrons and a glowing eye.
fn neon_strip(win: *viper::window, y: f64, t: f64) void = {
	const n = 14z;
	let outer: [28](f64, f64) = [(0.0, 0.0)...];
	let inner: [28](f64, f64) = [(0.0, 0.0)...];
	for (let i = 0z; i < n; i += 1) {
		const z = i: f64 * DEPTH / (n - 1): f64;
		const w = 0.07 + 0.42 * math::expf64(-z * 1.1);
		outer[i] = (sx(w, z), sy(y, z));
		outer[2 * n - 1 - i] = (sx(-w, z), sy(y, z));
		inner[i] = (sx(w * 0.72, z), sy(y, z));
		inner[2 * n - 1 - i] = (sx(-w * 0.72, z), sy(y, z));
	};
	viper::polygon(win, outer, PINK);
	viper::polygon(win, inner, viper::mix(WALL_A, DARK, 0.35));
	quad(win, (-0.035, y, 0.0), (0.035, y, 0.0), (0.035, y, DEPTH), (-0.035, y, DEPTH),
		viper::mix(CYAN, DARK, 0.25));
	// The glowing eye.
	let eye: [20](f64, f64) = [(0.0, 0.0)...];
	let pupil: [20](f64, f64) = [(0.0, 0.0)...];
	for (let k = 0z; k < 20; k += 1) {
		const a = k: f64 * 2.0 * math::PI / 20.0;
		const z = 1.3 + math::sinf64(a) * 0.28;
		eye[k] = (sx(math::cosf64(a) * 0.34, z), sy(y, z));
		const zp = 1.3 + math::sinf64(a) * 0.14;
		pupil[k] = (sx(math::cosf64(a) * 0.17, zp), sy(y, zp));
	};
	viper::polygon(win, eye, CYAN);
	viper::polygon(win, pupil, DARK);
	// Chevrons pointing into the tunnel; they light up one after another.
	const lit = (t * 4.0): int % 3;
	for (let k = 0; k < 3; k += 1) {
		const z = 2.0 + k: f64 * 0.35;
		const col = if (k == lit) viper::rgb(255, 255, 255) else CYAN;
		line3(win, (-0.12, y, z), (0.0, y, z + 0.18), col);
		line3(win, (0.0, y, z + 0.18), (0.12, y, z), col);
	};
};

fn draw_tunnel(win: *viper::window, t: f64) void = {
	viper::clear(win, DARK);
	// Wall panels, far to near, fading into the distance.
	for (let k = SEGS - 1; k >= 0; k -= 1) {
		const z0 = k: f64 * DEPTH / SEGS: f64, z1 = (k + 1): f64 * DEPTH / SEGS: f64;
		const base = if (k % 2 == 0) WALL_A else WALL_B;
		const tb = fog(base, z0);
		const side = fog(viper::mix(base, DARK, 0.18), z0);
		quad(win, (-HX, -HY, z0), (HX, -HY, z0), (HX, -HY, z1), (-HX, -HY, z1), tb);
		quad(win, (-HX, HY, z0), (HX, HY, z0), (HX, HY, z1), (-HX, HY, z1), tb);
		quad(win, (-HX, -HY, z0), (-HX, HY, z0), (-HX, HY, z1), (-HX, -HY, z1), side);
		quad(win, (HX, -HY, z0), (HX, HY, z0), (HX, HY, z1), (HX, -HY, z1), side);
	};
	// The grid lines running down the tunnel.
	for (let s = 0; s < 6; s += 1) {
		const z0 = s: f64 * DEPTH / 6.0, z1 = (s + 1): f64 * DEPTH / 6.0;
		const col = fog(GRID, z0);
		for (let i = 1; i < 8; i += 1) {
			const x = -HX + i: f64 * HX / 4.0;
			line3(win, (x, -HY, z0), (x, -HY, z1), col);
			line3(win, (x, HY, z0), (x, HY, z1), col);
		};
		for (let j = 1; j < 6; j += 1) {
			const y = -HY + j: f64 * HY / 3.0;
			line3(win, (-HX, y, z0), (-HX, y, z1), col);
			line3(win, (HX, y, z0), (HX, y, z1), col);
		};
	};
	// The panel seams around the tunnel.
	for (let k = 1; k <= SEGS; k += 1) {
		ring(win, k: f64 * DEPTH / SEGS: f64, fog(GRID, k: f64 * DEPTH / SEGS: f64));
	};
	neon_strip(win, -HY, t);
	neon_strip(win, HY, t);
	// The black wall at the far end with a cyan frame.
	const x0 = sx(-HX, DEPTH): int, x1 = sx(HX, DEPTH): int;
	const y0 = sy(-HY, DEPTH): int, y1 = sy(HY, DEPTH): int;
	viper::rect(win, x0, y0, x1 - x0, y1 - y0, viper::rgb(0, 0, 0));
	viper::outline(win, x0, y0, x1 - x0, y1 - y0, CYAN);
	viper::outline(win, x0 - 1, y0 - 1, x1 - x0 + 2, y1 - y0 + 2, CYAN);
};

// ZEBRA AI 7000's bat: neon zebra stripes with a pink glowing frame.
fn draw_zebra_bat(win: *viper::window, g: *game, p: *pics) void = {
	const x0 = sx(g.zx - PW, DEPTH), x1 = sx(g.zx + PW, DEPTH);
	const y0 = sy(g.zy - PH, DEPTH), y1 = sy(g.zy + PH, DEPTH);
	const w = (x1 - x0): int, h = (y1 - y0): int;
	glow_at(win, &p.glow_pink, (x0 + x1) / 2.0, (y0 + y1) / 2.0);
	viper::rect(win, x0: int, y0: int, w, h, viper::rgb(240, 240, 255));
	// Slanted black stripes, kept inside the bat.
	viper::clip(win, x0: int, y0: int, w, h);
	const sw = (x1 - x0) / 7.0;
	for (let i = -2; i < 8; i += 2) {
		const a = x0 + i: f64 * sw;
		const stripe: [4](f64, f64) = [
			(a, y0), (a + sw, y0), (a + sw * 2.0, y1), (a + sw, y1)
		];
		viper::polygon(win, stripe, viper::rgb(10, 10, 20));
	};
	viper::noclip(win);
	viper::outline(win, x0: int, y0: int, w, h, PINK);
	viper::outline(win, x0: int - 1, y0: int - 1, w + 2, h + 2, PINK);
	viper::outline(win, x0: int - 2, y0: int - 2, w + 4, h + 4, viper::mix(PINK, DARK, 0.5));
};

fn draw_ball(win: *viper::window, g: *game, p: *pics) void = {
	// The cyan frame shows how deep in the tunnel the ball is.
	ring(win, g.bz, CYAN);
	// Its shadow on the floor.
	let pts: [10](f64, f64) = [(0.0, 0.0)...];
	for (let k = 0z; k < 10; k += 1) {
		const a = k: f64 * 2.0 * math::PI / 10.0;
		const z = g.bz + math::sinf64(a) * R * 1.2;
		pts[k] = (sx(g.bx + math::cosf64(a) * R * 1.4, z), sy(HY, z));
	};
	viper::polygon(win, pts, viper::mix(WALL_A, DARK, 0.75));
	// The light trail: it bends when the ball has spin.
	if (g.st == state::PLAYING) {
		for (let i = TRAIL; i > 1; i -= 1) {
			const k = i - 1;
			const f = k: f64 / TRAIL: f64;
			const tz = g.trail_z[k];
			const r = (R * scale(tz) * (1.0 - f * 0.8)): int;
			viper::circle(win, sx(g.trail_x[k], tz): int, sy(g.trail_y[k], tz): int, r,
				fog(viper::mix(GOLD, PINK, f), tz));
		};
	};
	const cx = sx(g.bx, g.bz), cy = sy(g.by, g.bz);
	glow_at(win, &p.glow_gold, cx, cy);
	sphere(win, cx, cy, R * scale(g.bz), GOLD, viper::rgb(255, 235, 160));
};

fn draw_player(win: *viper::window, g: *game, p: *pics) void = {
	const img = if (g.flash > 0.0) &p.paddle_hit else &p.paddle;
	viper::draw_image(win, img, sx(g.px - PW, 0.0): int, sy(g.py - PH, 0.0): int);
};

fn draw_score(win: *viper::window, g: *game) void = {
	let b1: [32]u8 = [0...], b2: [32]u8 = [0...];
	const me = fmt::bsprintf(b1, "DIG {}", g.me)!;
	const ai = fmt::bsprintf(b2, "{} ZEBRA 7000", g.ai)!;
	viper::text_scaled(win, 22, 14, me, viper::rgb(0, 0, 0), 3);
	viper::text_scaled(win, 20, 12, me, CYAN, 3);
	const x = W - 20 - viper::text_width(ai, 3);
	viper::text_scaled(win, x + 2, 14, ai, viper::rgb(0, 0, 0), 3);
	viper::text_scaled(win, x, 12, ai, PINK, 3);
};

fn draw_title(win: *viper::window, g: *game, p: *pics) void = {
	viper::clear(win, DARK);
	const f = (g.t / GIF_T): size % FRAMES;
	if (p.arena_ok[f]) {
		viper::draw_image(win, &p.arena[f], 0, -100);
	} else {
		centered(win, 200, "GOLDEN PONG 3D 2", 4, GOLD);
	};
	viper::rect(win, 0, 528, W, 56, DARK);
	if ((g.t * 2.0): int % 2 == 0) {
		centered(win, 546, "KLIK ELLER ENTER FOR AT STARTE", 2, CYAN);
	};
	viper::text_scaled(win, W - 70, 10, "DEMO", PINK, 2);
};

fn draw_intro(win: *viper::window, g: *game, p: *pics) void = {
	viper::clear(win, DARK);
	const f = (g.t / GIF_T): size % FRAMES;
	if (p.zebra_ok[f]) viper::draw_image(win, &p.zebra[f], 16, 90);
	viper::outline(win, 15, 89, 422, 422, PINK);
	// Typewriter text.
	let left = (g.st_t * 26.0): size;
	for (let i = 0z; i < len(INTRO_LINES) && left > 0; i += 1) {
		const line = INTRO_LINES[i];
		const n = if (left < len(line)) left else len(line);
		left -= n;
		const col = if (i == 0) PINK else if (i == len(INTRO_LINES) - 1) GOLD else CYAN;
		viper::text_scaled(win, 452, 140 + i: int * 40, strings::sub(line, 0, n), col, 2);
	};
	if (g.st_t > 3.5 && (g.t * 2.0): int % 2 == 0) {
		centered(win, 540, "KLIK FOR AT SPILLE", 2, GOLD);
	};
};

fn draw_game(win: *viper::window, g: *game, p: *pics) void = {
	draw_tunnel(win, g.t);
	draw_zebra_bat(win, g, p);
	draw_ball(win, g, p);
	draw_player(win, g, p);
	draw_score(win, g);

	if (g.learn_t > 0.0 && (g.t * 6.0): int % 2 == 0) {
		centered(win, 520, g.learn_msg, 2, PINK);
	};
	switch (g.st) {
	case state::TITLE, state::INTRO, state::PLAYING => void;
	case state::READY =>
		centered(win, 470, if (g.you_serve) "KLIK FOR AT SERVE"
			else "ZEBRA  7000 SERVERER...", 2, viper::rgb(240, 240, 240));
	case state::POINT =>
		centered(win, 470, g.msg, 2, if (g.msg == "POINT TIL DIG!") CYAN else PINK);
	case state::OVER =>
		viper::rect(win, 0, 240, W, 100, DARK);
		centered(win, 262, g.msg, 2, GOLD);
		if (g.st_t > 0.8) centered(win, 302, "KLIK FOR EN NY KAMP", 2, CYAN);
	};
};

export fn main() void = {
	const win = match (viper::open("Golden Pong 3D 2 - DEMO", W, H)) {
	case let w: *viper::window =>
		yield w;
	case let e: viper::error =>
		fmt::fatal("viper:", viper::strerror(e));
	case nomem =>
		fmt::fatal("viper: out of memory");
	};
	defer viper::close(win);

	const snd = viper::audio_open();
	defer viper::audio_close(snd);
	let s_hit = viper::tone(viper::wave::SQUARE, 660.0, 990.0, 0.07, 0.35, 0.002);
	defer viper::sound_free(&s_hit);
	let s_wall = viper::tone(viper::wave::TRIANGLE, 520.0, 440.0, 0.06, 0.4, 0.002);
	defer viper::sound_free(&s_wall);
	let s_me = viper::melody(viper::wave::TRIANGLE, [523.3, 659.3, 784.0, 1046.5], 0.07, 0.35);
	defer viper::sound_free(&s_me);
	let s_ai = viper::tone(viper::wave::SAW, 400.0, 90.0, 0.5, 0.35, 0.005);
	defer viper::sound_free(&s_ai);
	let s_learn = viper::melody(viper::wave::SQUARE, [1318.5, 0.0, 1318.5, 1760.0], 0.05, 0.25);
	defer viper::sound_free(&s_learn);
	// A little synthwave bass line that loops all the time.
	let s_bass = viper::melody(viper::wave::SAW,
		[55.0, 55.0, 110.0, 55.0, 82.4, 55.0, 98.0, 73.4], 0.18, 0.18);
	defer viper::sound_free(&s_bass);

	let p = pics { ... };
	load_pics(&p);
	defer free_pics(&p);

	let g = game { ... };
	g.rng = 0x7000c0de;
	new_match(&g);
	set_state(&g, state::TITLE);
	let next_bass = 0.0;

	for (viper::frame(win)) {
		if (viper::key_pressed(win, viper::key::ESCAPE)) break;
		update(win, &g);

		switch (g.st) {
		case state::TITLE => draw_title(win, &g, &p);
		case state::INTRO => draw_intro(win, &g, &p);
		case => draw_game(win, &g, &p);
		};

		if (g.t >= next_bass) {
			viper::play(snd, &s_bass, 0.5, 1.0);
			next_bass += BASS_LOOP;
		};
		switch (g.sfx) {
		case 1 => viper::play(snd, &s_hit, 0.6, 1.0);
		case 2 => viper::play(snd, &s_wall, 0.5, 1.0);
		case 3 => viper::play(snd, &s_me, 0.6, 1.0);
		case 4 => viper::play(snd, &s_ai, 0.6, 1.0);
		case 5 => viper::play(snd, &s_learn, 0.6, 1.0);
		case => void;
		};
		g.sfx = 0;
		viper::audio_pump(snd);
		viper::present(win);
	};
};
