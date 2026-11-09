// Flappy Unicorn 3D — a ViperGui game.
// Space / Up / click to flap. Fly the unicorn through the rainbow gates.
// Esc quits. Your best score is kept in ~/.flappy-unicorn-best
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
def CX: f64 = 400.0;
def CY: f64 = 300.0;
def F: f64 = 380.0;       // focal length: screen px per world unit at z = 0
def Z0: f64 = 1.0;        // camera distance
def HX: f64 = 1.6;        // half width of a gate
def HY: f64 = 1.6;        // the ground is at y = HY, the sky top at -HY
def UZ: f64 = 2.0;        // how far in front of the camera the unicorn flies
def UR: f64 = 0.17;       // unicorn size for collisions
def GAP: f64 = 0.5;       // half the height of the hole in a gate
def T: f64 = 0.4;         // gate thickness
def SPACING: f64 = 4.0;   // distance between gates
def ZSTART: f64 = 9.0;    // where the first gate starts
def ZNEAR: f64 = 1.1;     // gates closer than this are sent to the back
def SPEED: f64 = 3.5;     // world units per second
def GRAVITY: f64 = 7.0;
def FLAP: f64 = -2.8;

// Pastel rainbow for the gates, a darker one for their insides,
// and a bright one for the mane and tail.
const FRONT: [6]viper::color = [
	0xffff8fa3, 0xffffbf7a, 0xfffff08a, 0xff9ef0a0, 0xff8fd0ff, 0xffc9a0ff
];
const SIDE: [6]viper::color = [
	0xffc8586e, 0xffcc8a45, 0xffc8b850, 0xff5fb865, 0xff5598cc, 0xff9068cc
];
const MANE: [6]viper::color = [
	0xffff4d6d, 0xffff9f40, 0xffffe14d, 0xff4ddb6a, 0xff4db0ff, 0xffa66bff
];

type state = enum { READY, PLAYING, DEAD };

type gate = struct {
	z: f64,        // its near face
	y: f64,        // middle of the hole
	c: size,       // colour
	scored: bool,
};

type game = struct {
	st: state,
	y: f64,
	vy: f64,
	gates: [4]gate,
	next_c: size,
	scroll: f64,
	score: int,
	best: int,
	t: f64,
	wing: f64,
	dead_t: f64,
	sfx: int,      // 0 = quiet, 1 = flap, 2 = point, 3 = bonk
	rng: random::random,
};

// --- 3D -> 2D ---
fn sx(x: f64, z: f64) f64 = CX + x * F / (z + Z0);
fn sy(y: f64, z: f64) f64 = CY + y * F / (z + Z0);

fn minf(a: f64, b: f64) f64 = if (a < b) a else b;
fn maxf(a: f64, b: f64) f64 = if (a > b) a else b;
fn clampf(x: f64, lo: f64, hi: f64) f64 =
	if (x < lo) lo else if (x > hi) hi else x;

// A random height for a gate's hole, between -0.8 and 0.8.
fn hole(g: *game) f64 = (random::next(&g.rng) % 161): f64 / 100.0 - 0.8;

fn new_gate(g: *game, z: f64) gate = {
	const gt = gate {
		z = z,
		y = hole(g),
		c = g.next_c % len(FRONT),
		scored = false,
	};
	g.next_c += 1;
	return gt;
};

// Send a passed gate to the back of the line.
fn respawn(g: *game, i: size) void = {
	let far = 0.0;
	for (let k = 0z; k < len(g.gates); k += 1) far = maxf(far, g.gates[k].z);
	g.gates[i] = new_gate(g, far + SPACING);
};

fn reset(g: *game) void = {
	g.st = state::READY;
	g.y = -0.2;
	g.vy = 0.0;
	g.score = 0;
	g.dead_t = 0.0;
	g.sfx = 0;
	for (let i = 0z; i < len(g.gates); i += 1) {
		g.gates[i] = new_gate(g, ZSTART + i: f64 * SPACING);
	};
};

fn hits(g: *game) bool = {
	if (g.y + UR > HY) return true;     // the ground
	for (let i = 0z; i < len(g.gates); i += 1) {
		const gt = &g.gates[i];
		if (UZ + UR > gt.z && UZ - UR < gt.z + T) {
			if (g.y - UR < gt.y - GAP || g.y + UR > gt.y + GAP) return true;
		};
	};
	return false;
};

fn update(win: *viper::window, g: *game) void = {
	const dt = minf(viper::delta(win), 0.05);
	g.t += dt;
	g.wing += dt * (if (g.vy < 0.0) 22.0 else 8.0);
	const flap = viper::key_pressed(win, viper::key::SPACE)
		|| viper::key_pressed(win, viper::key::UP)
		|| viper::mouse_pressed(win);

	switch (g.st) {
	case state::READY =>
		g.scroll += SPEED * dt;
		g.y = -0.2 + 0.08 * math::sinf64(g.t * 3.0);
		if (flap) {
			g.st = state::PLAYING;
			g.vy = FLAP;
			g.sfx = 1;
		};
	case state::PLAYING =>
		g.scroll += SPEED * dt;
		if (flap) {
			g.vy = FLAP;
			g.sfx = 1;
		};
		g.vy += GRAVITY * dt;
		g.y += g.vy * dt;
		if (g.y < -HY + UR) {
			g.y = -HY + UR;
			g.vy = 0.0;
		};
		for (let i = 0z; i < len(g.gates); i += 1) {
			let gt = &g.gates[i];
			gt.z -= SPEED * dt;
			if (!gt.scored && gt.z + T < UZ - UR) {
				gt.scored = true;
				g.score += 1;
				g.sfx = 2;
			};
			if (gt.z < ZNEAR) respawn(g, i);
		};
		if (hits(g)) {
			g.st = state::DEAD;
			g.dead_t = 0.0;
			g.vy = -1.5;
			if (g.score > g.best) {
				g.best = g.score;
				save_best(g.best);
			};
			g.sfx = 3;
		};
	case state::DEAD =>
		g.dead_t += dt;
		g.vy += GRAVITY * dt;
		g.y += g.vy * dt;
		if (g.y > HY - UR) {
			g.y = HY - UR;
			g.vy = 0.0;
		};
		if (flap && g.dead_t > 0.6) reset(g);
	};
};

// --- drawing ---

// A filled rectangle between two screen corners, kept inside the window.
fn box(win: *viper::window, x0: f64, y0: f64, x1: f64, y1: f64, col: viper::color) void = {
	const l = clampf(minf(x0, x1), 0.0, W: f64), r = clampf(maxf(x0, x1), 0.0, W: f64);
	const t = clampf(minf(y0, y1), 0.0, H: f64), b = clampf(maxf(y0, y1), 0.0, H: f64);
	if (r - l < 1.0 || b - t < 1.0) return;
	viper::rect(win, l: int, t: int, (r - l): int, (b - t): int, col);
};

fn draw_sky(win: *viper::window, t: f64) void = {
	for (let i = 0; i < 20; i += 1) {
		const y0 = i: f64 * CY / 20.0;
		const col = viper::rgb((30 + i * 5): u8, (20 + i * 3): u8, (70 + i * 5): u8);
		box(win, 0.0, y0, W: f64, y0 + CY / 20.0 + 1.0, col);
	};
	// Twinkling stars.
	for (let i = 0; i < 40; i += 1) {
		const x = (i * 137 + 50) % W, y = (i * 71 + 13) % (CY: int - 30);
		if ((i + (t * 3.0): int) % 7 != 0) {
			viper::rect(win, x, y, 2, 2, viper::rgb(255, 250, 220));
		};
	};
	// A crescent moon.
	viper::circle(win, 650, 90, 38, viper::rgb(255, 240, 200));
	viper::circle(win, 666, 80, 34, viper::rgb(55, 35, 95));
};

// Candy-striped meadow that rushes towards you.
fn draw_ground(win: *viper::window, scroll: f64) void = {
	box(win, 0.0, CY, W: f64, H: f64, viper::rgb(120, 200, 140));
	const o = scroll - (scroll: int): f64;
	const p = (scroll: int) % 2;
	for (let k = 20; k >= 0; k -= 1) {
		const za = maxf(k: f64 - o, 0.05), zb = k: f64 + 1.0 - o;
		const col = if ((k + p) % 2 == 0) viper::rgb(150, 225, 160)
			else viper::rgb(255, 190, 220);
		box(win, 0.0, sy(HY, zb), W: f64, sy(HY, za), col);
	};
};

fn draw_gate(win: *viper::window, gt: *gate) void = {
	const z0 = gt.z, z1 = gt.z + T;
	const top = gt.y - GAP, bot = gt.y + GAP;
	const front = FRONT[gt.c], side = SIDE[gt.c];
	// The inside of the hole, so the gate has depth.
	viper::polygon(win, [
		(sx(-HX, z0), sy(top, z0)), (sx(HX, z0), sy(top, z0)),
		(sx(HX, z1), sy(top, z1)), (sx(-HX, z1), sy(top, z1))
	], side);
	viper::polygon(win, [
		(sx(-HX, z0), sy(bot, z0)), (sx(HX, z0), sy(bot, z0)),
		(sx(HX, z1), sy(bot, z1)), (sx(-HX, z1), sy(bot, z1))
	], side);
	// The front: a top part and a bottom part with the hole between.
	const x0 = sx(-HX, z0), x1 = sx(HX, z0);
	box(win, x0, sy(-4.0, z0), x1, sy(top, z0), front);
	box(win, x0, sy(bot, z0), x1, sy(HY, z0), front);
	// Gold trim around the hole.
	const gold = viper::rgb(255, 210, 70);
	box(win, x0, sy(top, z0) - 3.0, x1, sy(top, z0), gold);
	box(win, x0, sy(bot, z0), x1, sy(bot, z0) + 3.0, gold);
};

// The unicorn, seen from behind as it flies into the screen.
fn draw_unicorn(win: *viper::window, g: *game) void = {
	const s = F / (UZ + Z0);
	const r = UR * s;                  // body radius in pixels
	const x = CX, y = sy(g.y, UZ);
	// Shadow on the ground.
	const gy = sy(HY, UZ);
	box(win, x - r * 1.2, gy - 3.0, x + r * 1.2, gy + 3.0, viper::rgb(80, 140, 95));
	// Rainbow tail, swaying behind.
	for (let i = 0z; i < 6; i += 1) {
		const sway = math::sinf64(g.t * 6.0 + i: f64 * 0.7) * r * 0.25;
		viper::circle(win, (x + sway): int, (y + r * 0.6 + i: f64 * r * 0.28): int,
			(r * 0.32): int, MANE[i]);
	};
	// Wings: they beat fast right after a flap.
	const beat = math::sinf64(g.wing) * r * 0.9;
	const wing = viper::rgb(255, 235, 248);
	viper::polygon(win, [(x - r * 0.5, y - r * 0.3), (x - r * 2.8, y - r * 0.8 + beat),
		(x - r * 0.5, y + r * 0.5)], wing);
	viper::polygon(win, [(x + r * 0.5, y - r * 0.3), (x + r * 2.8, y - r * 0.8 + beat),
		(x + r * 0.5, y + r * 0.5)], wing);
	// Body and head.
	const white = viper::rgb(250, 250, 255);
	viper::circle(win, x: int, y: int, r: int, white);
	viper::circle(win, x: int, (y - r * 1.05): int, (r * 0.62): int, white);
	// Ears.
	viper::polygon(win, [(x - r * 0.5, y - r * 1.4), (x - r * 0.25, y - r * 1.5),
		(x - r * 0.45, y - r * 1.85)], white);
	viper::polygon(win, [(x + r * 0.5, y - r * 1.4), (x + r * 0.25, y - r * 1.5),
		(x + r * 0.45, y - r * 1.85)], white);
	// The golden horn.
	viper::polygon(win, [(x - r * 0.16, y - r * 1.55), (x + r * 0.16, y - r * 1.55),
		(x, y - r * 2.5)], viper::rgb(255, 205, 60));
	// Rainbow mane down the back of the neck.
	for (let i = 0z; i < 6; i += 1) {
		viper::circle(win, x: int, (y - r * 1.45 + i: f64 * r * 0.3): int,
			(r * 0.16): int + 1, MANE[i]);
	};
	// Dizzy stars after a crash.
	if (g.st == state::DEAD) {
		for (let k = 0; k < 3; k += 1) {
			const a = g.t * 5.0 + k: f64 * 2.09;
			viper::circle(win, (x + math::cosf64(a) * r * 1.3): int,
				(y - r * 2.0 + math::sinf64(a) * r * 0.4): int, 4,
				viper::rgb(255, 230, 80));
		};
	};
};

// Text with a soft purple shadow.
fn centered(win: *viper::window, y: int, s: str, scale: int, col: viper::color) void = {
	const x = (W - viper::text_width(s, scale)) / 2;
	viper::text_scaled(win, x + 2, y + 2, s, viper::rgb(40, 20, 60), scale);
	viper::text_scaled(win, x, y, s, col, scale);
};

// --- high score: ~/.flappy-unicorn-best ---
fn best_path(buf: []u8) str = {
	const home = match (os::getenv("HOME")) {
	case let h: str => yield h;
	case void => yield ".";
	};
	return fmt::bsprintf(buf, "{}/.flappy-unicorn-best", home)!;
};

fn load_best() int = {
	let buf: [256]u8 = [0...];
	const f = match (os::open(best_path(buf))) {
	case let f: io::file => yield f;
	case => return 0; // no file yet = no record yet
	};
	defer io::close(f)!;
	let data: [32]u8 = [0...];
	const n = match (io::read(f, data)) {
	case let n: size => yield n;
	case => return 0;
	};
	const s = strings::trim(strings::fromutf8(data[..n])!);
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
	const win = match (viper::open("Flappy Unicorn 3D - ViperGui", W, H)) {
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
	let fwip = viper::tone(viper::wave::TRIANGLE, 500.0, 1000.0, 0.08, 0.5, 0.005);
	let pling = viper::tone(viper::wave::SINE, 1500.0, 2200.0, 0.15, 0.4, 0.005);
	let bonk = viper::tone(viper::wave::SQUARE, 300.0, 60.0, 0.4, 0.5, 0.005);
	defer viper::sound_free(&fwip);
	defer viper::sound_free(&pling);
	defer viper::sound_free(&bonk);

	let g = game { ... };
	g.rng = random::init(2026);
	reset(&g);
	g.best = load_best();
	let buf: [64]u8 = [0...];
	const gold = viper::rgb(255, 210, 70);
	const white = viper::rgb(255, 255, 255);

	for (viper::frame(win)) {
		if (viper::key_pressed(win, viper::key::ESCAPE)) break;
		update(win, &g);

		draw_sky(win, g.t);
		draw_ground(win, g.scroll);

		// Gates far to near. The unicorn is drawn between the gates
		// behind it and the one it is flying through.
		let order: [4]size = [0, 1, 2, 3];
		for (let a = 0z; a < 4; a += 1) for (let b = a + 1; b < 4; b += 1) {
			if (g.gates[order[b]].z > g.gates[order[a]].z) {
				const tmp = order[a];
				order[a] = order[b];
				order[b] = tmp;
			};
		};
		let drawn = false;
		for (let k = 0z; k < 4; k += 1) {
			const gt = &g.gates[order[k]];
			if (!drawn && gt.z < UZ) {
				draw_unicorn(win, &g);
				drawn = true;
			};
			draw_gate(win, gt);
		};
		if (!drawn) draw_unicorn(win, &g);

		switch (g.st) {
		case state::READY =>
			centered(win, 90, "FLAPPY UNICORN 3D", 4, gold);
			centered(win, 150, "Space / klik for at flyve", 2, white);
			if (g.best > 0) {
				centered(win, 185, fmt::bsprintf(buf, "Best: {}", g.best)!, 2, white);
			};
		case state::PLAYING =>
			centered(win, 30, fmt::bsprintf(buf, "{}", g.score)!, 4, white);
		case state::DEAD =>
			centered(win, 120, "AV! REGNBUEN SLAP OP!", 3, viper::rgb(255, 110, 150));
			centered(win, 180, fmt::bsprintf(buf, "Score: {}   Best: {}",
				g.score, g.best)!, 2, white);
			if (g.dead_t > 0.6) {
				centered(win, 220, "Klik for at flyve igen", 2, gold);
			};
		};

		switch (g.sfx) {
		case 1 => viper::play(snd, &fwip, 0.6, 1.0);
		case 2 => viper::play(snd, &pling, 0.6, 1.0);
		case 3 => viper::play(snd, &bonk, 0.8, 1.0);
		case => void;
		};
		g.sfx = 0;
		viper::audio_pump(snd);
		viper::present(win);
	};
};
