// Flamingo Putt — minigolf i Eventyrland. A ViperGui game.
// Træk med musen og slip for at slå (som en slangebøsse). Esc afslutter.
// Din bedste runde gemmes i ~/.flamingo-putt-best
use fmt;
use io;
use math;
use math::random;
use os;
use strconv;
use strings;
use viper;

def W: int = 800;
def H: int = 600;
def TOP: int = 44;            // height of the score bar
def NHOLES: int = 9;
def MAXPOWER: f64 = 160.0;    // drag length (px) for a full shot
def MAXV: f64 = 820.0;        // ball speed for a full shot (px/s)
def NORMAL_R: f64 = 7.0;
def SMALL_R: f64 = 4.0;
def BIG_R: f64 = 12.0;
def MAXSTROKES: int = 10;
def WALK_SPEED: f64 = 45.0;   // the hedgehog's stroll

// Wall kinds.
def SOLID: int = 0;
def DOOR: int = 1;    // a tiny door: only a small ball gets through
def GLASS: int = 2;   // breaks when a big ball hits it hard
def BLINK: int = 3;   // the Cheshire Cat's wall: there, and then not

// Bumper kinds.
def MUSHROOM: int = 0;
def ROSE: int = 1;
def TABLE: int = 2;

// Item kinds.
def DRINK: int = 0;
def EAT: int = 1;

def INK: viper::color = 0xff1b1428;
def FELT: viper::color = 0xff2f8f4e;
def FELT_DARK: viper::color = 0xff23703c;
def GOLD: viper::color = 0xffe8c26a;
def PINK: viper::color = 0xffff7eb6;
def CREAM: viper::color = 0xfffff4dc;
def RED: viper::color = 0xffe02040;

const NAMES: [9]str = [
	"Ned i kaninhullet",
	"Drik mig!",
	"Spis mig!",
	"Pindsvinet vågner",
	"Kortsoldaterne",
	"Det skøre te-selskab",
	"Grinekatten",
	"Kålormens røg",
	"Dronningens bane",
];

const PARS: [9]int = [2, 3, 3, 4, 3, 3, 3, 3, 4];

type seg = struct {
	x0: f64, y0: f64, x1: f64, y1: f64,
	kind: int,
	alive: bool,
};

type bump = struct { x: f64, y: f64, r: f64, kind: int };

// A card soldier marching back and forth around (x, y).
type mover = struct {
	x: f64, y: f64,
	ax: f64, ay: f64,
	w: f64, h: f64,
	speed: f64, phase: f64,
};

type item = struct { x: f64, y: f64, kind: int, taken: bool };

// Caterpillar smoke: pushes a rolling ball by (fx, fy) px/s^2.
type zone = struct { x: f64, y: f64, w: f64, h: f64, fx: f64, fy: f64 };

type course = struct {
	name: str,
	tip: str,
	par: int,
	floor: [16](f64, f64),
	nfloor: size,
	walls: [32]seg,
	nwalls: size,
	bumps: [8]bump,
	nbumps: size,
	movers: [4]mover,
	nmovers: size,
	items: [2]item,
	nitems: size,
	zones: [2]zone,
	nzones: size,
	portal: bool,
	pa: (f64, f64),
	pb: (f64, f64),
	spinner: bool,
	sx: f64, sy: f64, slen: f64, sw: f64,
	cups: [3](f64, f64),
	ncups: size,
	cup: size,
	tee: (f64, f64),
	hedgehog: bool,
	queen: bool,
	caterpillar: bool,
};

type state = enum { TITLE, AIM, ROLL, SUNK, CARD };

type game = struct {
	st: state,
	hole: int,
	c: course,
	x: f64, y: f64, vx: f64, vy: f64, r: f64,
	strokes: int,
	scores: [9]int,
	drag: bool,
	px: int, py: int,      // where the drag started
	idle: f64,
	walk_t: f64,
	shot: bool,            // the ball rolls because of a shot, not a walk
	t: f64,
	msg: str,
	msg_t: f64,
	banner_t: f64,
	sunk_t: f64,
	pcool: f64,
	lock: f64,             // ignore clicks for a moment after a change
	best: int,
	newbest: bool,
	sfx: int,
	rng: random::random,
};

// --- building the holes ---

fn add_wall(c: *course, x0: f64, y0: f64, x1: f64, y1: f64, kind: int) void = {
	if (c.nwalls >= len(c.walls)) return;
	c.walls[c.nwalls] = seg { x0 = x0, y0 = y0, x1 = x1, y1 = y1, kind = kind, alive = true };
	c.nwalls += 1;
};

// The green: a closed shape with a wall all the way round.
fn set_floor(c: *course, pts: [](f64, f64)) void = {
	c.nfloor = 0;
	for (let i = 0z; i < len(pts) && i < len(c.floor); i += 1) {
		c.floor[i] = pts[i];
		c.nfloor += 1;
	};
	for (let i = 0z; i < c.nfloor; i += 1) {
		const a = c.floor[i], b = c.floor[(i + 1) % c.nfloor];
		add_wall(c, a.0, a.1, b.0, b.1, SOLID);
	};
};

fn set_box(c: *course, x0: f64, y0: f64, x1: f64, y1: f64) void = {
	const pts: [4](f64, f64) = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)];
	set_floor(c, pts);
};

fn add_bump(c: *course, x: f64, y: f64, r: f64, kind: int) void = {
	if (c.nbumps >= len(c.bumps)) return;
	c.bumps[c.nbumps] = bump { x = x, y = y, r = r, kind = kind };
	c.nbumps += 1;
};

fn add_mover(c: *course, x: f64, y: f64, ax: f64, ay: f64,
		w: f64, h: f64, speed: f64, phase: f64) void = {
	if (c.nmovers >= len(c.movers)) return;
	c.movers[c.nmovers] = mover {
		x = x, y = y, ax = ax, ay = ay,
		w = w, h = h, speed = speed, phase = phase,
	};
	c.nmovers += 1;
};

fn add_item(c: *course, x: f64, y: f64, kind: int) void = {
	if (c.nitems >= len(c.items)) return;
	c.items[c.nitems] = item { x = x, y = y, kind = kind, taken = false };
	c.nitems += 1;
};

fn add_zone(c: *course, x: f64, y: f64, w: f64, h: f64, fx: f64, fy: f64) void = {
	if (c.nzones >= len(c.zones)) return;
	c.zones[c.nzones] = zone { x = x, y = y, w = w, h = h, fx = fx, fy = fy };
	c.nzones += 1;
};

fn add_cup(c: *course, x: f64, y: f64) void = {
	if (c.ncups >= len(c.cups)) return;
	c.cups[c.ncups] = (x, y);
	c.ncups += 1;
};

fn make_course(n: int) course = {
	let c = course { ... };
	c.name = NAMES[n: size];
	c.par = PARS[n: size];
	switch (n) {
	case 0 =>
		c.tip = "Træk med musen og slip for at slå.";
		set_box(&c, 100.0, 200.0, 700.0, 440.0);
		add_bump(&c, 400.0, 320.0, 30.0, MUSHROOM);
		c.tee = (160.0, 320.0);
		add_cup(&c, 640.0, 320.0);
	case 1 =>
		c.tip = "Drik flasken, så du bliver lille nok til døren.";
		set_box(&c, 80.0, 120.0, 720.0, 520.0);
		add_wall(&c, 400.0, 120.0, 400.0, 300.0, SOLID);
		add_wall(&c, 400.0, 300.0, 400.0, 340.0, DOOR);
		add_wall(&c, 400.0, 340.0, 400.0, 520.0, SOLID);
		add_item(&c, 250.0, 200.0, DRINK);
		c.tee = (160.0, 430.0);
		add_cup(&c, 620.0, 320.0);
	case 2 =>
		c.tip = "Spis kagen, og knus glasset med et hårdt slag.";
		set_box(&c, 80.0, 120.0, 720.0, 520.0);
		add_wall(&c, 430.0, 120.0, 430.0, 520.0, GLASS);
		add_item(&c, 260.0, 410.0, EAT);
		c.tee = (160.0, 200.0);
		add_cup(&c, 620.0, 320.0);
	case 3 =>
		c.tip = "Vent ikke for længe - pindsvinet går sin egen vej.";
		set_box(&c, 80.0, 100.0, 720.0, 540.0);
		add_wall(&c, 260.0, 100.0, 260.0, 420.0, SOLID);
		add_wall(&c, 540.0, 220.0, 540.0, 540.0, SOLID);
		c.tee = (160.0, 160.0);
		add_cup(&c, 640.0, 480.0);
		c.hedgehog = true;
	case 4 =>
		c.tip = "Kortsoldaterne marcherer. Find et hul i rækken!";
		set_box(&c, 80.0, 140.0, 720.0, 500.0);
		add_mover(&c, 300.0, 320.0, 0.0, 120.0, 26.0, 74.0, 1.7, 0.0);
		add_mover(&c, 400.0, 320.0, 0.0, 120.0, 26.0, 74.0, 1.7, 2.1);
		add_mover(&c, 500.0, 320.0, 0.0, 120.0, 26.0, 74.0, 1.7, 4.2);
		c.tee = (140.0, 320.0);
		add_cup(&c, 660.0, 320.0);
	case 5 =>
		c.tip = "Hattemageren flytter koppen, hver gang du slår.";
		set_box(&c, 80.0, 100.0, 720.0, 540.0);
		add_bump(&c, 400.0, 320.0, 46.0, TABLE);
		c.spinner = true;
		c.sx = 400.0;
		c.sy = 320.0;
		c.slen = 165.0;
		c.sw = 1.1;
		c.tee = (150.0, 320.0);
		add_cup(&c, 650.0, 170.0);
		add_cup(&c, 650.0, 470.0);
		add_cup(&c, 400.0, 510.0);
	case 6 =>
		c.tip = "Væggen blinker, og kattens smil fører dig videre.";
		set_box(&c, 80.0, 100.0, 720.0, 540.0);
		add_wall(&c, 300.0, 100.0, 300.0, 540.0, BLINK);
		add_wall(&c, 500.0, 100.0, 500.0, 540.0, SOLID);
		c.portal = true;
		c.pa = (420.0, 200.0);
		c.pb = (620.0, 440.0);
		c.tee = (150.0, 320.0);
		add_cup(&c, 640.0, 200.0);
	case 7 =>
		c.tip = "Kålormens røg puster bolden op og ned.";
		set_box(&c, 80.0, 120.0, 720.0, 520.0);
		add_zone(&c, 260.0, 120.0, 110.0, 400.0, 0.0, -300.0);
		add_zone(&c, 430.0, 120.0, 110.0, 400.0, 0.0, 300.0);
		add_bump(&c, 400.0, 320.0, 24.0, MUSHROOM);
		c.tee = (150.0, 440.0);
		add_cup(&c, 650.0, 200.0);
		c.caterpillar = true;
	case =>
		c.tip = "Dronningens egen bane. Hun hader bogeys!";
		const pts: [6](f64, f64) = [
			(80.0, 100.0), (720.0, 100.0), (720.0, 540.0),
			(480.0, 540.0), (480.0, 300.0), (80.0, 300.0),
		];
		set_floor(&c, pts);
		add_bump(&c, 330.0, 150.0, 16.0, ROSE);
		add_bump(&c, 330.0, 250.0, 16.0, ROSE);
		add_bump(&c, 600.0, 190.0, 16.0, ROSE);
		add_mover(&c, 420.0, 200.0, 0.0, 60.0, 26.0, 60.0, 1.4, 0.0);
		add_mover(&c, 600.0, 420.0, 80.0, 0.0, 74.0, 26.0, 1.2, 1.0);
		c.tee = (150.0, 200.0);
		add_cup(&c, 600.0, 495.0);
		c.hedgehog = true;
		c.queen = true;
	};
	return c;
};

// --- game flow ---

fn say(g: *game, s: str, secs: f64) void = {
	g.msg = s;
	g.msg_t = secs;
};

fn speed(g: *game) f64 = math::sqrtf64(g.vx * g.vx + g.vy * g.vy);

fn start_hole(g: *game, n: int) void = {
	g.hole = n;
	g.c = make_course(n);
	g.x = g.c.tee.0;
	g.y = g.c.tee.1;
	g.vx = 0.0;
	g.vy = 0.0;
	g.r = NORMAL_R;
	g.strokes = 0;
	g.drag = false;
	g.idle = 0.0;
	g.walk_t = 0.0;
	g.shot = false;
	g.msg_t = 0.0;
	g.banner_t = 2.8;
	g.pcool = 0.0;
	g.lock = 0.3;
	g.st = state::AIM;
};

fn new_game(g: *game) void = {
	for (let i = 0z; i < len(g.scores); i += 1) g.scores[i] = 0;
	g.newbest = false;
	start_hole(g, 0);
};

fn total(g: *game) int = {
	let s = 0;
	for (let i = 0; i < NHOLES; i += 1) s += g.scores[i: size];
	return s;
};

fn par_total() int = {
	let s = 0;
	for (let i = 0; i < NHOLES; i += 1) s += PARS[i: size];
	return s;
};

fn sunk(g: *game, gave_up: bool) void = {
	g.vx = 0.0;
	g.vy = 0.0;
	g.walk_t = 0.0;
	g.drag = false;
	if (gave_up) {
		g.strokes = MAXSTROKES;
		say(g, "Dronningen mister tålmodigheden! Videre!", 2.6);
		g.sfx = 7;
	} else if (g.strokes == 0) {
		g.strokes = 1;
		say(g, "Pindsvinet gik selv i hul! Det tæller som et slag.", 2.6);
		g.sfx = 2;
	} else if (g.strokes == 1) {
		say(g, "HOLE IN ONE! Vidunderligt!", 2.6);
		g.sfx = 5;
	} else if (g.strokes < g.c.par) {
		say(g, "Birdie! Nysgerrigere og nysgerrigere!", 2.6);
		g.sfx = 5;
	} else if (g.strokes == g.c.par) {
		say(g, "Par. Ganske fornuftigt, for Eventyrland.", 2.6);
		g.sfx = 2;
	} else if (g.c.queen) {
		say(g, "\"OFF WITH YOUR PAR!\" råber Dronningen.", 2.6);
		g.sfx = 7;
	} else {
		say(g, "Bogey... Dronningen må ikke høre om det.", 2.6);
		g.sfx = 2;
	};
	g.scores[g.hole: size] = g.strokes;
	g.sunk_t = 2.6;
	g.st = state::SUNK;
};

fn finish(g: *game) void = {
	const t = total(g);
	if (g.best == 0 || t < g.best) {
		g.best = t;
		g.newbest = true;
		save_best(t);
	};
	g.lock = 1.0;
	g.st = state::CARD;
};

// --- physics ---

fn clampf(x: f64, lo: f64, hi: f64) f64 = if (x < lo) lo else if (x > hi) hi else x;

// The point on the line from (ax, ay) to (bx, by) closest to (px, py).
fn closest(px: f64, py: f64, ax: f64, ay: f64, bx: f64, by: f64) (f64, f64) = {
	const dx = bx - ax, dy = by - ay;
	const l2 = dx * dx + dy * dy;
	if (l2 < 0.0001) return (ax, ay);
	const t = clampf(((px - ax) * dx + (py - ay) * dy) / l2, 0.0, 1.0);
	return (ax + t * dx, ay + t * dy);
};

fn touching(g: *game, cx: f64, cy: f64, rad: f64) bool = {
	const dx = g.x - cx, dy = g.y - cy;
	const lim = g.r + rad;
	return dx * dx + dy * dy < lim * lim;
};

// Pushes the ball out of the point (cx, cy) (or a circle of radius rad
// around it) and bounces it. (pvx, pvy) is how fast the obstacle moves.
// e is the bounciness: 1.0 keeps all the speed.
fn bounce(g: *game, cx: f64, cy: f64, rad: f64, e: f64, pvx: f64, pvy: f64) bool = {
	let nx = g.x - cx, ny = g.y - cy;
	let d = math::sqrtf64(nx * nx + ny * ny);
	const lim = g.r + rad;
	if (d >= lim) return false;
	if (d < 0.0001) {
		nx = pvx - g.vx;
		ny = pvy - g.vy;
		d = math::sqrtf64(nx * nx + ny * ny);
		if (d < 0.0001) {
			nx = 0.0;
			ny = -1.0;
			d = 1.0;
		};
	};
	nx /= d;
	ny /= d;
	g.x = cx + nx * lim;
	g.y = cy + ny * lim;
	let rvx = g.vx - pvx, rvy = g.vy - pvy;
	const vn = rvx * nx + rvy * ny;
	if (vn < 0.0) {
		rvx -= (1.0 + e) * vn * nx;
		rvy -= (1.0 + e) * vn * ny;
	};
	g.vx = rvx + pvx;
	g.vy = rvy + pvy;
	return true;
};

fn blink_on(g: *game) bool = (g.t / 1.4): int % 2 == 0;

// Where a card soldier is right now, and how fast it moves.
fn mover_at(g: *game, m: *mover) (f64, f64, f64, f64) = {
	const a = g.t * m.speed + m.phase;
	const s = math::sinf64(a), c = math::cosf64(a);
	return (m.x + m.ax * s, m.y + m.ay * s,
		m.ax * m.speed * c, m.ay * m.speed * c);
};

fn spinner_ends(g: *game) (f64, f64, f64, f64) = {
	const a = g.t * g.c.sw;
	const ex = math::cosf64(a) * g.c.slen, ey = math::sinf64(a) * g.c.slen;
	return (g.c.sx - ex, g.c.sy - ey, g.c.sx + ex, g.c.sy + ey);
};

fn physics(g: *game, h: f64) void = {
	g.x += g.vx * h;
	g.y += g.vy * h;

	// Walls.
	for (let i = 0z; i < g.c.nwalls; i += 1) {
		let w = &g.c.walls[i];
		if (!w.alive) continue;
		if (w.kind == DOOR && g.r <= SMALL_R + 0.5) continue;
		if (w.kind == BLINK && !blink_on(g)) continue;
		const p = closest(g.x, g.y, w.x0, w.y0, w.x1, w.y1);
		if (!touching(g, p.0, p.1, 0.0)) continue;
		if (w.kind == GLASS && g.r >= BIG_R - 0.5 && speed(g) > 120.0) {
			w.alive = false;
			say(g, "KLIRR! Glasvæggen knuser!", 2.0);
			g.sfx = 4;
			continue;
		};
		const sp = speed(g);
		bounce(g, p.0, p.1, 0.0, 0.75, 0.0, 0.0);
		if (sp > 90.0 && g.sfx == 0) g.sfx = 9;
	};

	// Mushrooms, roses and the tea table.
	for (let i = 0z; i < g.c.nbumps; i += 1) {
		const b = g.c.bumps[i];
		const e = if (b.kind == ROSE) 1.15 else if (b.kind == TABLE) 0.6 else 0.9;
		if (bounce(g, b.x, b.y, b.r, e, 0.0, 0.0) && b.kind != TABLE && g.sfx == 0) {
			g.sfx = 3;
		};
	};

	// Card soldiers.
	for (let i = 0z; i < g.c.nmovers; i += 1) {
		const m = mover_at(g, &g.c.movers[i]);
		const hw = g.c.movers[i].w / 2.0, hh = g.c.movers[i].h / 2.0;
		let cx = clampf(g.x, m.0 - hw, m.0 + hw);
		let cy = clampf(g.y, m.1 - hh, m.1 + hh);
		if (cx == g.x && cy == g.y) {
			// The ball is inside the card: out by the nearest side.
			const dl = g.x - (m.0 - hw), dr = (m.0 + hw) - g.x;
			const du = g.y - (m.1 - hh), dd = (m.1 + hh) - g.y;
			if (dl <= dr && dl <= du && dl <= dd) {
				cx = m.0 - hw;
				g.x = cx - 0.01;
			} else if (dr <= du && dr <= dd) {
				cx = m.0 + hw;
				g.x = cx + 0.01;
			} else if (du <= dd) {
				cy = m.1 - hh;
				g.y = cy - 0.01;
			} else {
				cy = m.1 + hh;
				g.y = cy + 0.01;
			};
		};
		if (bounce(g, cx, cy, 0.0, 0.8, m.2, m.3) && g.sfx == 0) g.sfx = 9;
	};

	// The Mad Hatter's spinning table arm.
	if (g.c.spinner) {
		const s = spinner_ends(g);
		const p = closest(g.x, g.y, s.0, s.1, s.2, s.3);
		const rx = p.0 - g.c.sx, ry = p.1 - g.c.sy;
		if (bounce(g, p.0, p.1, 4.0, 0.8, -g.c.sw * ry, g.c.sw * rx) && g.sfx == 0) {
			g.sfx = 9;
		};
	};

	// Caterpillar smoke only carries a ball that is already rolling.
	if (speed(g) > 25.0) {
		for (let i = 0z; i < g.c.nzones; i += 1) {
			const z = g.c.zones[i];
			if (g.x >= z.x && g.x < z.x + z.w && g.y >= z.y && g.y < z.y + z.h) {
				g.vx += z.fx * h;
				g.vy += z.fy * h;
			};
		};
	};

	// Drink me / eat me.
	for (let i = 0z; i < g.c.nitems; i += 1) {
		let it = &g.c.items[i];
		if (it.taken || !touching(g, it.x, it.y, 10.0)) continue;
		it.taken = true;
		if (it.kind == DRINK) {
			g.r = SMALL_R;
			say(g, "Du skrumper! Nu passer du gennem den lille dør.", 2.4);
		} else {
			g.r = BIG_R;
			say(g, "Du vokser! Nu kan du knuse glas.", 2.4);
		};
		g.sfx = 6;
	};

	// The Cheshire Cat's grin takes you to the other grin.
	if (g.c.portal && g.pcool <= 0.0) {
		const sp = speed(g);
		const dx = if (sp > 0.0) g.vx / sp else 1.0;
		const dy = if (sp > 0.0) g.vy / sp else 0.0;
		if (touching(g, g.c.pa.0, g.c.pa.1, 7.0)) {
			g.x = g.c.pb.0 + dx * 18.0;
			g.y = g.c.pb.1 + dy * 18.0;
			g.pcool = 0.8;
			g.sfx = 8;
		} else if (touching(g, g.c.pb.0, g.c.pb.1, 7.0)) {
			g.x = g.c.pa.0 + dx * 18.0;
			g.y = g.c.pa.1 + dy * 18.0;
			g.pcool = 0.8;
			g.sfx = 8;
		};
	};

	// Rolling slows down; a walking hedgehog keeps its pace.
	const sp = speed(g);
	if (sp > 0.0) {
		let ns = 0.0;
		if (g.walk_t > 0.0) {
			ns = WALK_SPEED;
		} else {
			ns = sp - (70.0 * h + sp * (1.0 - math::expf64(-0.9 * h)));
			if (ns < 0.0) ns = 0.0;
		};
		g.vx *= ns / sp;
		g.vy *= ns / sp;
	};

	// Never leave the window, whatever happens.
	g.x = clampf(g.x, 0.0, W: f64);
	g.y = clampf(g.y, TOP: f64, H: f64);
};

fn in_cup(g: *game) bool = {
	const cup = g.c.cups[g.c.cup];
	const dx = g.x - cup.0, dy = g.y - cup.1;
	return dx * dx + dy * dy < 81.0 && speed(g) < 460.0;
};

fn roll(g: *game, dt: f64) void = {
	const steps = 6;
	for (let i = 0; i < steps; i += 1) {
		physics(g, dt / steps: f64);
		if (in_cup(g)) {
			sunk(g, false);
			return;
		};
	};
	if (g.walk_t > 0.0) {
		g.walk_t -= dt;
		if (g.walk_t <= 0.0) {
			g.vx = 0.0;
			g.vy = 0.0;
		};
		return;
	};
	if (speed(g) >= 6.0) return;
	// The ball has stopped.
	g.vx = 0.0;
	g.vy = 0.0;
	g.idle = 0.0;
	g.st = state::AIM;
	if (g.shot && g.c.ncups > 1) {
		g.c.cup = (g.c.cup + 1) % g.c.ncups;
		say(g, "Hattemageren flytter koppen! Byt plads, byt plads!", 2.2);
	};
	g.shot = false;
	if (g.strokes >= MAXSTROKES) sunk(g, true);
};

fn aim(win: *viper::window, g: *game, dt: f64) void = {
	// The hedgehog gets bored and walks off.
	if (g.c.hedgehog && !g.drag) {
		g.idle += dt;
		if (g.idle > 3.0) {
			const a = random::u32n(&g.rng, 628): f64 / 100.0;
			g.vx = math::cosf64(a) * WALK_SPEED;
			g.vy = math::sinf64(a) * WALK_SPEED;
			g.walk_t = 1.3;
			g.shot = false;
			g.idle = 0.0;
			g.st = state::ROLL;
			say(g, "Pindsvinet går en lille tur...", 1.8);
			return;
		};
	};
	if (g.lock > 0.0) return;
	if (!g.drag && viper::mouse_clicks(win) & viper::LEFT_BUTTON != 0) {
		g.drag = true;
		g.px = win.mouse_x;
		g.py = win.mouse_y;
		g.idle = 0.0;
	};
	if (!g.drag) return;
	g.idle = 0.0;
	// Right click cancels the shot.
	if (viper::mouse_clicks(win) & viper::RIGHT_BUTTON != 0) {
		g.drag = false;
		return;
	};
	if (win.mouse_down) return;
	// Released: shoot like a slingshot.
	g.drag = false;
	const dx = (g.px - win.mouse_x): f64, dy = (g.py - win.mouse_y): f64;
	const l = math::sqrtf64(dx * dx + dy * dy);
	if (l < 8.0) return;
	const p = (if (l > MAXPOWER) MAXPOWER else l) / MAXPOWER;
	g.vx = dx / l * p * MAXV;
	g.vy = dy / l * p * MAXV;
	g.strokes += 1;
	g.shot = true;
	g.st = state::ROLL;
	g.sfx = 1;
};

fn update(win: *viper::window, g: *game) void = {
	let dt = viper::delta(win);
	if (dt > 0.05) dt = 0.05;
	g.t += dt;
	g.msg_t -= dt;
	g.banner_t -= dt;
	g.pcool -= dt;
	g.lock -= dt;
	switch (g.st) {
	case state::TITLE =>
		if (g.lock <= 0.0 && (viper::mouse_pressed(win)
				|| viper::key_pressed(win, viper::key::SPACE)
				|| viper::key_pressed(win, viper::key::RETURN))) {
			new_game(g);
		};
	case state::AIM =>
		aim(win, g, dt);
	case state::ROLL =>
		roll(g, dt);
	case state::SUNK =>
		g.sunk_t -= dt;
		if (g.sunk_t <= 0.0) {
			if (g.hole + 1 < NHOLES) start_hole(g, g.hole + 1) else finish(g);
		};
	case state::CARD =>
		if (g.lock <= 0.0 && (viper::mouse_pressed(win)
				|| viper::key_pressed(win, viper::key::SPACE)
				|| viper::key_pressed(win, viper::key::RETURN))) {
			g.lock = 0.4;
			g.st = state::TITLE;
		};
	};
};

// --- drawing ---

fn centered(win: *viper::window, y: int, s: str, col: viper::color, scale: int) void = {
	viper::text_scaled(win, (W - viper::text_width(s, scale)) / 2, y, s, col, scale);
};

// A line with thickness w and round ends.
fn thick(win: *viper::window, x0: f64, y0: f64, x1: f64, y1: f64, w: f64, col: viper::color) void = {
	const dx = x1 - x0, dy = y1 - y0;
	const l = math::sqrtf64(dx * dx + dy * dy);
	const r = (w / 2.0): int;
	if (l >= 0.5) {
		const nx = -dy / l * w / 2.0, ny = dx / l * w / 2.0;
		const pts: [4](f64, f64) = [
			(x0 + nx, y0 + ny), (x1 + nx, y1 + ny),
			(x1 - nx, y1 - ny), (x0 - nx, y0 - ny),
		];
		viper::polygon(win, pts, col);
	};
	viper::circle(win, x0: int, y0: int, r, col);
	viper::circle(win, x1: int, y1: int, r, col);
};

fn ring(win: *viper::window, cx: f64, cy: f64, r: f64, col: viper::color) void = {
	for (let k = 0; k < 32; k += 1) {
		const a0 = k: f64 * math::PI / 16.0, a1 = (k + 1): f64 * math::PI / 16.0;
		viper::line(win, (cx + math::cosf64(a0) * r): int, (cy + math::sinf64(a0) * r): int,
			(cx + math::cosf64(a1) * r): int, (cy + math::sinf64(a1) * r): int, col);
	};
};

fn heart(win: *viper::window, cx: int, cy: int, s: int, col: viper::color) void = {
	viper::circle(win, cx - s / 2, cy - s / 4, s / 2, col);
	viper::circle(win, cx + s / 2, cy - s / 4, s / 2, col);
	const pts: [3](f64, f64) = [
		((cx - s): f64, (cy - s / 6): f64),
		((cx + s): f64, (cy - s / 6): f64),
		(cx: f64, (cy + s): f64),
	];
	viper::polygon(win, pts, col);
};

// A chessboard, like the one Alice walks across.
fn draw_board(win: *viper::window) void = {
	for (let y = 0; y < H; y += 40) {
		for (let x = 0; x < W; x += 40) {
			const col: viper::color = if ((x / 40 + y / 40) % 2 == 0) 0xff2a1f3d else 0xff33264a;
			viper::rect(win, x, y, 40, 40, col);
		};
	};
};

fn draw_cup(win: *viper::window, g: *game, i: size) void = {
	const cup = g.c.cups[i];
	const x = cup.0: int, y = cup.1: int;
	const tea = g.c.ncups > 1;
	if (tea) {
		// A teacup on a saucer.
		viper::circle(win, x, y, 16, CREAM);
		ring(win, cup.0, cup.1, 16.0, 0xffd8c8a8);
		ring(win, cup.0 + 19.0, cup.1, 5.0, CREAM);
		ring(win, cup.0 + 19.0, cup.1, 4.0, CREAM);
	};
	if (i != g.c.cup) {
		if (tea) viper::circle(win, x, y, 10, 0xffb08a5a);
		return;
	};
	viper::circle(win, x, y, 10, 0xff0d0a12);
	ring(win, cup.0, cup.1, 10.0, 0xff5a4a3a);
	// The flag.
	viper::line(win, x, y, x, y - 38, 0xfff0f0f0);
	viper::line(win, x + 1, y, x + 1, y - 38, 0xffc0c0c0);
	const flag: [3](f64, f64) = [
		((x + 2): f64, (y - 38): f64),
		((x + 24): f64, (y - 31): f64),
		((x + 2): f64, (y - 24): f64),
	];
	viper::polygon(win, flag, RED);
	heart(win, x + 9, y - 32, 3, CREAM);
};

fn draw_bump(win: *viper::window, b: bump) void = {
	const x = b.x: int, y = b.y: int, r = b.r: int;
	switch (b.kind) {
	case MUSHROOM =>
		viper::circle(win, x, y, r, 0xffd23a3a);
		viper::circle(win, x - r / 3, y - r / 3, r / 5, CREAM);
		viper::circle(win, x + r / 3, y - r / 5, r / 6, CREAM);
		viper::circle(win, x, y + r / 3, r / 6, CREAM);
	case ROSE =>
		viper::circle(win, x, y, r + 3, 0xff1f5f2a);
		viper::circle(win, x, y, r - 2, RED);
		viper::circle(win, x, y, r / 3, 0xff8a1028);
	case =>
		viper::circle(win, x, y, r, 0xff8a5a32);
		viper::circle(win, x, y, r - 6, 0xffa8744a);
		for (let k = 0; k < 5; k += 1) {
			const a = k: f64 * 2.0 * math::PI / 5.0;
			viper::circle(win, x + (math::cosf64(a) * (r - 16): f64): int,
				y + (math::sinf64(a) * (r - 16): f64): int, 5, CREAM);
		};
	};
};

fn draw_wall(win: *viper::window, g: *game, w: *seg) void = {
	switch (w.kind) {
	case DOOR =>
		const open = g.r <= SMALL_R + 0.5;
		const col: viper::color = if (open) 0xff4a3670 else 0xff8a5ad0;
		thick(win, w.x0, w.y0, w.x1, w.y1, 8.0, col);
		if (!open) viper::circle(win, w.x0: int + 2, ((w.y0 + w.y1) / 2.0): int, 2, GOLD);
	case GLASS =>
		thick(win, w.x0, w.y0, w.x1, w.y1, 6.0, 0xffbfefff);
		for (let k = 1; k < 8; k += 1) {
			const t = k: f64 / 8.0;
			viper::circle(win, (w.x0 + (w.x1 - w.x0) * t): int,
				(w.y0 + (w.y1 - w.y0) * t): int, 1, 0xffffffff);
		};
	case BLINK =>
		if (blink_on(g)) {
			thick(win, w.x0, w.y0, w.x1, w.y1, 6.0, 0xffc060ff);
		} else {
			// Only a faint dotted outline while it's gone.
			for (let k = 0; k < 40; k += 2) {
				const t = k: f64 / 40.0;
				viper::circle(win, (w.x0 + (w.x1 - w.x0) * t): int,
					(w.y0 + (w.y1 - w.y0) * t): int, 1, 0xff6a4a8a);
			};
		};
	case =>
		thick(win, w.x0, w.y0, w.x1, w.y1, 6.0, GOLD);
	};
};

fn draw_card(win: *viper::window, g: *game, m: *mover) void = {
	const p = mover_at(g, m);
	const x = (p.0 - m.w / 2.0): int, y = (p.1 - m.h / 2.0): int;
	const w = m.w: int, h = m.h: int;
	viper::rect(win, x, y, w, h, 0xfff8f8f8);
	viper::outline(win, x, y, w, h, RED);
	viper::outline(win, x + 2, y + 2, w - 4, h - 4, 0xffe0b0b0);
	heart(win, p.0: int, p.1: int, 5, RED);
};

fn draw_item(win: *viper::window, it: *item) void = {
	const x = it.x: int, y = it.y: int;
	if (it.kind == DRINK) {
		viper::round_rect(win, x - 7, y - 6, 14, 18, 4, 0xff5aa0ff);
		viper::rect(win, x - 3, y - 13, 6, 8, 0xff5aa0ff);
		viper::rect(win, x - 4, y - 16, 8, 4, 0xff8a5a32);
		viper::rect(win, x - 6, y, 12, 6, CREAM);
		viper::text(win, x - 16, y + 14, "DRIK", CREAM);
	} else {
		viper::round_rect(win, x - 10, y - 4, 20, 14, 4, 0xffffb0c8);
		viper::rect(win, x - 10, y - 4, 20, 4, 0xfffff0f4);
		viper::circle(win, x, y - 7, 3, RED);
		viper::text(win, x - 16, y + 14, "SPIS", CREAM);
	};
};

// The Cheshire Cat's grin (and eyes).
fn draw_grin(win: *viper::window, g: *game, cx: f64, cy: f64) void = {
	ring(win, cx, cy, 15.0, 0xff8a3ac0);
	ring(win, cx, cy, 14.0, 0xffc060ff);
	for (let k = 0; k < 9; k += 1) {
		const a = 0.15 * math::PI + k: f64 * 0.7 * math::PI / 8.0;
		viper::circle(win, (cx + math::cosf64(a) * 9.0): int,
			(cy + math::sinf64(a) * 5.0 + 1.0): int, 1, 0xffffffff);
	};
	if ((g.t * 2.0): int % 4 != 0) {
		viper::circle(win, cx: int - 5, cy: int - 5, 2, 0xffffe040);
		viper::circle(win, cx: int + 5, cy: int - 5, 2, 0xffffe040);
	};
};

fn draw_zone(win: *viper::window, g: *game, z: zone) void = {
	viper::rect(win, z.x: int, z.y: int, z.w: int, z.h: int, 0xff3a9a6a);
	const hh = z.h: int;
	for (let k = 0; k < 4; k += 1) {
		const off = ((g.t * 70.0): int + k * hh / 4) % hh;
		const y = if (z.fy < 0.0) z.y + z.h - off: f64 else z.y + off: f64;
		const r = 8.0 + (off: f64 / z.h) * 14.0;
		ring(win, z.x + z.w / 2.0, y, r, 0xffd9d0ea);
		ring(win, z.x + z.w / 2.0, y, r - 1.0, 0xffbfb0d8);
	};
};

fn draw_caterpillar(win: *viper::window, g: *game) void = {
	// On top of the mushroom in the middle, puffing away.
	for (let k = 0; k < 4; k += 1) {
		const bob = (math::sinf64(g.t * 3.0 + k: f64) * 2.0): int;
		viper::circle(win, 388 + k * 8, 312 + bob - k * 2, 6 - k / 2, 0xff3a7ae0);
	};
	viper::circle(win, 388, 312, 3, 0xffffe040);
	viper::circle(win, 389, 311, 1, INK);
};

fn draw_queen(win: *viper::window, g: *game) void = {
	// She watches from the corner of the chessboard.
	const x = 250, y = 420;
	const dress: [3](f64, f64) = [
		(x: f64, (y - 20): f64), ((x - 45): f64, (y + 80): f64), ((x + 45): f64, (y + 80): f64),
	];
	viper::polygon(win, dress, RED);
	heart(win, x, y + 40, 8, CREAM);
	viper::circle(win, x, y - 32, 16, 0xffffd0b0);
	const crown: [5](f64, f64) = [
		((x - 14): f64, (y - 46): f64), ((x - 10): f64, (y - 62): f64),
		(x: f64, (y - 52): f64), ((x + 10): f64, (y - 62): f64),
		((x + 14): f64, (y - 46): f64),
	];
	viper::polygon(win, crown, GOLD);
	viper::circle(win, x - 5, y - 34, 2, INK);
	viper::circle(win, x + 5, y - 34, 2, INK);
	viper::rect(win, x - 6, y - 25, 12, 2, 0xff8a1028);
	const quote = if ((g.t / 4.0): int % 2 == 0) "Off with their heads!" else "Off with your par!";
	const tw = viper::text_width(quote, 1);
	viper::round_rect(win, x - tw / 2 - 10, y - 104, tw + 20, 28, 8, CREAM);
	viper::text(win, x - tw / 2, y - 98, quote, 0xff8a1028);
};

fn draw_ball(win: *viper::window, g: *game) void = {
	const x = g.x: int, y = g.y: int, r = g.r: int;
	if (g.c.hedgehog) {
		for (let k = 0; k < 12; k += 1) {
			const a = k: f64 * math::PI / 6.0 + g.t * 0.5;
			viper::line(win, x, y, x + (math::cosf64(a) * (g.r + 4.0)): int,
				y + (math::sinf64(a) * (g.r + 4.0)): int, 0xff5a3a22);
		};
		viper::circle(win, x, y, r, 0xff9a6a42);
		viper::circle(win, x + r - 1, y, 2, INK);
		viper::circle(win, x + r / 3, y - r / 3, 1, INK);
	} else {
		viper::circle(win, x + 1, y + 2, r, 0xff1e5a30);
		viper::circle(win, x, y, r, 0xfff8f8f8);
		viper::circle(win, x - r / 3, y - r / 3, if (r > 5) 2 else 1, 0xffffffff);
		viper::circle(win, x + r / 3, y + r / 3, if (r > 5) 2 else 1, 0xffd8d8d8);
	};
};

// While aiming: the flamingo putter behind the ball and dots showing
// where the shot goes.
fn draw_aim(win: *viper::window, g: *game) void = {
	const dx = (g.px - win.mouse_x): f64, dy = (g.py - win.mouse_y): f64;
	const l = math::sqrtf64(dx * dx + dy * dy);
	if (l < 2.0) return;
	const p = (if (l > MAXPOWER) MAXPOWER else l) / MAXPOWER;
	const ux = dx / l, uy = dy / l;
	// Dots ahead of the ball.
	for (let k = 1; k <= 7; k += 1) {
		const d = g.r + 6.0 + k: f64 * (6.0 + p * 18.0);
		const col = viper::mix(0xffffffff, RED, p);
		viper::circle(win, (g.x + ux * d): int, (g.y + uy * d): int, 2, col);
	};
	// The flamingo: neck pulled back, head ready to hit.
	const back = g.r + 4.0 + p * 40.0;
	const hx = g.x - ux * back, hy = g.y - uy * back;
	const nx = hx - ux * 34.0 - uy * 10.0, ny = hy - uy * 34.0 + ux * 10.0;
	thick(win, nx, ny, hx, hy, 5.0, PINK);
	viper::circle(win, hx: int, hy: int, 6, PINK);
	thick(win, hx, hy, hx + ux * 7.0, hy + uy * 7.0, 3.0, INK);
	viper::circle(win, (hx - uy * 2.0): int, (hy + ux * 2.0): int, 1, INK);
	// Power bar.
	viper::rect(win, W - 150, H - 30, 130, 12, 0xff2a1f3d);
	viper::rect(win, W - 150, H - 30, (130.0 * p): int, 12, viper::mix(0xff60e080, RED, p));
	viper::outline(win, W - 150, H - 30, 130, 12, CREAM);
};

fn draw_course(win: *viper::window, g: *game) void = {
	const c = &g.c;
	viper::polygon(win, c.floor[..c.nfloor], FELT);
	for (let i = 0z; i < c.nzones; i += 1) draw_zone(win, g, c.zones[i]);
	viper::circle(win, c.tee.0: int, c.tee.1: int, 9, FELT_DARK);
	for (let i = 0z; i < c.ncups; i += 1) draw_cup(win, g, i);
	if (c.portal) {
		draw_grin(win, g, c.pa.0, c.pa.1);
		draw_grin(win, g, c.pb.0, c.pb.1);
	};
	for (let i = 0z; i < c.nbumps; i += 1) draw_bump(win, c.bumps[i]);
	if (c.caterpillar) draw_caterpillar(win, g);
	if (c.spinner) {
		const s = spinner_ends(g);
		thick(win, s.0, s.1, s.2, s.3, 8.0, 0xff6a4428);
		viper::circle(win, s.0: int, s.1: int, 9, CREAM);
		viper::circle(win, s.2: int, s.3: int, 7, 0xffffb0c8);
		viper::circle(win, c.sx: int, c.sy: int, 10, 0xff3a2a1a);
		viper::circle(win, c.sx: int, (c.sy - 4.0): int, 6, INK);
	};
	for (let i = 0z; i < c.nitems; i += 1) {
		if (!c.items[i].taken) draw_item(win, &c.items[i]);
	};
	for (let i = 0z; i < c.nwalls; i += 1) {
		if (c.walls[i].alive) draw_wall(win, g, &c.walls[i]);
	};
	for (let i = 0z; i < c.nmovers; i += 1) draw_card(win, g, &c.movers[i]);
	if (c.queen) draw_queen(win, g);
};

fn draw_hud(win: *viper::window, g: *game) void = {
	viper::rect(win, 0, 0, W, TOP, INK);
	viper::rect(win, 0, TOP - 2, W, 2, PINK);
	let b: [96]u8 = [0...];
	viper::text_scaled(win, 14, 6, "FLAMINGO PUTT", PINK, 2);
	viper::text(win, 250, 14, fmt::bsprintf(b, "Hul {}/9: {}", g.hole + 1, g.c.name)!, CREAM);
	let b2: [64]u8 = [0...];
	const right = fmt::bsprintf(b2, "Par {}  Slag {}  Total {}", g.c.par, g.strokes,
		total(g) + (if (g.st == state::SUNK) 0 else g.strokes))!;
	viper::text(win, W - 14 - viper::text_width(right, 1), 14, right, GOLD);
};

fn draw_message(win: *viper::window, g: *game) void = {
	if (g.msg_t <= 0.0) return;
	const tw = viper::text_width(g.msg, 1);
	const x = (W - tw) / 2;
	viper::round_rect(win, x - 14, H - 40, tw + 28, 30, 10, PINK);
	viper::round_rect(win, x - 12, H - 38, tw + 24, 26, 9, INK);
	viper::text(win, x, H - 33, g.msg, CREAM);
};

fn draw_banner(win: *viper::window, g: *game) void = {
	if (g.banner_t <= 0.0) return;
	viper::round_rect(win, 150, 236, 500, 116, 14, PINK);
	viper::round_rect(win, 153, 239, 494, 110, 12, INK);
	let b: [32]u8 = [0...];
	centered(win, 250, fmt::bsprintf(b, "HUL {}   PAR {}", g.hole + 1, g.c.par)!, GOLD, 1);
	centered(win, 274, g.c.name, PINK, 2);
	centered(win, 318, g.c.tip, CREAM, 1);
};

// A small flamingo for the title screen.
fn draw_flamingo(win: *viper::window, x: int, y: int, t: f64) void = {
	const fx = x: f64, fy = y: f64;
	thick(win, fx, fy + 40.0, fx, fy + 110.0, 4.0, PINK);
	thick(win, fx + 10.0, fy + 40.0, fx + 18.0, fy + 110.0, 4.0, PINK);
	viper::circle(win, x + 6, y + 30, 26, PINK);
	const nod = math::sinf64(t * 2.0) * 6.0;
	thick(win, fx + 22.0, fy + 20.0, fx + 30.0, fy - 40.0 + nod, 6.0, PINK);
	viper::circle(win, x + 30, y - 44 + nod: int, 9, PINK);
	thick(win, fx + 36.0, fy - 44.0 + nod, fx + 50.0, fy - 34.0 + nod, 4.0, INK);
	viper::circle(win, x + 32, y - 47 + nod: int, 2, INK);
};

fn draw_title(win: *viper::window, g: *game) void = {
	draw_board(win);
	centered(win, 90, "FLAMINGO", PINK, 6);
	centered(win, 190, "PUTT", GOLD, 6);
	centered(win, 300, "Minigolf i Eventyrland", CREAM, 2);
	centered(win, 340, "9 huller med flamingo-kølle og pindsvine-bold", 0xffbfb0d8, 1);
	draw_flamingo(win, 110, 380, g.t);
	// A hedgehog rolling about on the right.
	const hx = 680 + (math::sinf64(g.t) * 30.0): int;
	for (let k = 0; k < 12; k += 1) {
		const a = k: f64 * math::PI / 6.0 + g.t;
		viper::line(win, hx, 470, hx + (math::cosf64(a) * 20.0): int,
			470 + (math::sinf64(a) * 20.0): int, 0xff5a3a22);
	};
	viper::circle(win, hx, 470, 15, 0xff9a6a42);
	viper::circle(win, hx + 13, 470, 2, INK);
	if ((g.t * 2.0): int % 2 == 0) centered(win, 430, "Klik for at starte", CREAM, 2);
	if (g.best > 0) {
		let b: [48]u8 = [0...];
		centered(win, 480, fmt::bsprintf(b, "Bedste runde: {} slag (par {})", g.best, par_total())!, GOLD, 1);
	};
	centered(win, H - 30, "Træk og slip for at slå  -  højreklik fortryder  -  Esc afslutter", 0xff8a7aa8, 1);
};

fn draw_card_screen(win: *viper::window, g: *game) void = {
	draw_board(win);
	viper::round_rect(win, 120, 50, 560, 500, 16, PINK);
	viper::round_rect(win, 123, 53, 554, 494, 14, INK);
	centered(win, 70, "SCOREKORT", GOLD, 3);
	let b: [80]u8 = [0...];
	for (let i = 0; i < NHOLES; i += 1) {
		const y = 136 + i * 28;
		const s = g.scores[i: size];
		const col: viper::color = if (s < PARS[i: size]) 0xff60e080
			else if (s == PARS[i: size]) CREAM else 0xffff8080;
		viper::text(win, 160, y, fmt::bsprintf(b, "{}", i + 1)!, GOLD);
		viper::text(win, 190, y, NAMES[i: size], CREAM);
		viper::text(win, 470, y, fmt::bsprintf(b, "par {}", PARS[i: size])!, 0xffbfb0d8);
		viper::text(win, 580, y, fmt::bsprintf(b, "{}", s)!, col);
	};
	const t = total(g), p = par_total();
	viper::rect(win, 150, 392, 500, 2, PINK);
	viper::text_scaled(win, 160, 404, "TOTAL", GOLD, 2);
	viper::text_scaled(win, 560, 404, fmt::bsprintf(b, "{}", t)!, CREAM, 2);
	const verdict = if (t < p) "Under par! Du er en ægte Eventyrlands-mester!"
		else if (t == p) "Præcis par. Hattemageren løfter hatten."
		else "Over par... men Dronningen har travlt med roserne.";
	centered(win, 448, verdict, PINK, 1);
	if (g.newbest) {
		centered(win, 474, "NY REKORD!", GOLD, 2);
	} else if (g.best > 0) {
		centered(win, 478, fmt::bsprintf(b, "Bedste runde: {}", g.best)!, GOLD, 1);
	};
	if (g.lock <= 0.0) centered(win, 516, "Klik for at fortsætte", 0xffbfb0d8, 1);
};

fn draw(win: *viper::window, g: *game) void = {
	switch (g.st) {
	case state::TITLE =>
		draw_title(win, g);
	case state::CARD =>
		draw_card_screen(win, g);
	case =>
		draw_board(win);
		draw_course(win, g);
		if (g.st != state::SUNK) draw_ball(win, g);
		if (g.st == state::AIM && g.drag) draw_aim(win, g);
		draw_hud(win, g);
		draw_banner(win, g);
		draw_message(win, g);
	};
};

// --- best round: ~/.flamingo-putt-best ---

fn best_path(buf: []u8) str = {
	const home = match (os::getenv("HOME")) {
	case let h: str => yield h;
	case void => yield ".";
	};
	return fmt::bsprintf(buf, "{}/.flamingo-putt-best", home)!;
};

fn load_best() int = {
	let buf: [256]u8 = [0...];
	const f = match (os::open(best_path(buf))) {
	case let f: io::file => yield f;
	case => return 0;
	};
	defer io::close(f)!;
	let data: [32]u8 = [0...];
	const n = match (io::read(f, data)) {
	case let n: size => yield n;
	case => return 0;
	};
	const s = match (strings::fromutf8(data[..n])) {
	case let s: str => yield strings::trim(s);
	case => return 0;
	};
	match (strconv::stoi(s)) {
	case let v: int => return v;
	case => return 0;
	};
};

fn save_best(best: int) void = {
	let buf: [256]u8 = [0...];
	const f = match (os::create(best_path(buf), 0o644)) {
	case let f: io::file => yield f;
	case => return;
	};
	defer io::close(f)!;
	fmt::fprintln(f, best)!;
};

export fn main() void = {
	const win = match (viper::open("Flamingo Putt - ViperGui", W, H)) {
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
	let hit = viper::tone(viper::wave::TRIANGLE, 320.0, 180.0, 0.06, 0.5, 0.002);
	let plop = viper::tone(viper::wave::SINE, 520.0, 110.0, 0.2, 0.6, 0.002);
	let boing = viper::tone(viper::wave::SINE, 220.0, 720.0, 0.16, 0.45, 0.002);
	let crash = viper::tone(viper::wave::NOISE, 3000.0, 500.0, 0.45, 0.5, 0.002);
	const fan: [5]f64 = [523.3, 659.3, 784.0, 1046.5, 1318.5];
	let fanfare = viper::melody(viper::wave::TRIANGLE, fan, 0.09, 0.4);
	const mag: [4]f64 = [784.0, 987.8, 1174.7, 1568.0];
	let magic = viper::melody(viper::wave::SINE, mag, 0.05, 0.3);
	let queen = viper::tone(viper::wave::SQUARE, 170.0, 85.0, 0.55, 0.35, 0.005);
	let whoosh = viper::tone(viper::wave::NOISE, 400.0, 2400.0, 0.28, 0.3, 0.01);
	let tock = viper::tone(viper::wave::TRIANGLE, 900.0, 700.0, 0.03, 0.25, 0.001);
	defer viper::sound_free(&hit);
	defer viper::sound_free(&plop);
	defer viper::sound_free(&boing);
	defer viper::sound_free(&crash);
	defer viper::sound_free(&fanfare);
	defer viper::sound_free(&magic);
	defer viper::sound_free(&queen);
	defer viper::sound_free(&whoosh);
	defer viper::sound_free(&tock);

	let g = game { rng = random::init(viper::ticks(): u64 + 11), ... };
	g.st = state::TITLE;
	g.c = make_course(0);
	g.best = load_best();

	for (viper::frame(win)) {
		if (viper::key_pressed(win, viper::key::ESCAPE)) break;
		update(win, &g);
		draw(win, &g);
		switch (g.sfx) {
		case 1 => viper::play(snd, &hit, 0.7, 1.0);
		case 2 => viper::play(snd, &plop, 0.8, 1.0);
		case 3 => viper::play(snd, &boing, 0.6, 1.0);
		case 4 => viper::play(snd, &crash, 0.7, 1.0);
		case 5 => viper::play(snd, &fanfare, 0.6, 1.0);
		case 6 => viper::play(snd, &magic, 0.6, 1.0);
		case 7 => viper::play(snd, &queen, 0.6, 1.0);
		case 8 => viper::play(snd, &whoosh, 0.6, 1.0);
		case 9 => viper::play(snd, &tock, 0.5, 1.0);
		case => void;
		};
		g.sfx = 0;
		viper::audio_pump(snd);
		viper::present(win);
	};
};
