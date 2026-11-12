// Golden Pong 3D 2 — DEMO, in Cyberpunk 7000 style.
// You look down a neon tunnel from behind your see-through paddle.
//
// Stage 1: ZEBRA 7000, a cyborg zebra that learns where you like to shoot.
// Stage 2 (boss): JARBI, the Laser Grip Queen, in her UFO-pod. Two heads,
// four arms, and every third return is a LASER GRIP shot.
//
// Move your paddle while you hit to put spin on the ball and make it curve.
// Mouse (or the arrow keys / WASD) moves your paddle. Click / Space
// serves. On the title screen, J jumps straight to JARBI. Esc quits.
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
def PW: f64 = 0.34;        // your paddle's half width
def PH: f64 = 0.25;        // your paddle's half height
def SEGS: int = 12;        // wall panels along the tunnel
def WIN_SCORE: int = 7;
def TRAIL: size = 12;
def TITLE_FRAMES: size = 6;
def MAXF: size = 9;        // most animation frames a portrait may have
def NSTAGES: size = 2;
def GIF_T: f64 = 0.15;     // seconds per frame of the title animation
def BASS_LOOP: f64 = 1.44; // length of the bass line (8 x 0.18 s)

def CYAN: viper::color = 0xff2ee6ff;
def PINK: viper::color = 0xffff2fd0;
def GOLD: viper::color = 0xffffc83a;
def DARK: viper::color = 0xff050816;

// Everything that makes one opponent and its arena different.
type stage = struct {
	name: str,             // full name
	short: str,            // in the score line
	file: str,             // assets/pong2/<file>-0.png ... (portrait)
	frames: size,
	frame_t: f64,
	bat_file: str,         // "" = draw zebra stripes
	window_file: str,      // picture on the far wall ("" = black)
	pod_file: str,         // background behind the intro ("" = none)
	intro: [6]str,
	taunts: [4]str,
	serve_msg: str,
	you_won: str,
	it_won: str,
	wall_a: viper::color,
	wall_b: viper::color,
	grid: viper::color,
	glow1: viper::color,   // main neon colour (strip, eye, frames)
	glow2: viper::color,   // second neon colour (flares, lasers)
	bat_glow: viper::color,
	bat_w: f64,            // the opponent's bat, half width / half height
	bat_h: f64,
	speed: f64,            // how fast the bat moves at the start
	err: f64,              // how badly it guesses at the start
	lasers: bool,          // red laser conduits + LASER GRIP shots
};

const STAGES: [NSTAGES]stage = [
	stage {
		name = "ZEBRA 7000",
		short = "ZEBRA",
		file = "zebra7000",
		frames = 6,
		frame_t = 0.15,
		bat_file = "",
		window_file = "",
		pod_file = "",
		intro = [
			"ZEBRA 7000",
			"ONLINE.",
			"Jeg har analyseret",
			"1.000.000 kampe.",
			"Jeg laerer dine skud.",
			"Du kan ikke vinde.",
		],
		taunts = [
			"BEREGNET.",
			"FORUDSIGELIGT, MENNESKE.",
			"99,7% SANDSYNLIGHED.",
			"OPDATERER DATABASE...",
		],
		serve_msg = "ZEBRA 7000 SERVERER...",
		you_won = "DU SLOG ZEBRA 7000!",
		it_won = "ZEBRA 7000 VANDT. SYSTEM UOVERVINDELIG.",
		wall_a = 0xff1f63d8,
		wall_b = 0xff1852be,
		grid = 0xff0b2c78,
		glow1 = 0xff2ee6ff,
		glow2 = 0xffff2fd0,
		bat_glow = 0xffff2fd0,
		bat_w = 0.34,
		bat_h = 0.25,
		speed = 1.2,
		err = 0.45,
		lasers = false,
	},
	stage {
		name = "JARBI",
		short = "JARBI",
		file = "jarbi",
		frames = 9,
		frame_t = 0.14,
		bat_file = "jarbi-bat",
		window_file = "jarbi-window",
		pod_file = "jarbi-pod",
		intro = [
			"JARBI",
			"LASER GRIP QUEEN",
			"Fra Laser Grip.",
			"To hoveder.",
			"Fire arme.",
			"Ingen lette sejre.",
		],
		taunts = [
			"HA! FIRE ARME, JORDBO.",
			"TO HOVEDER TAENKER BEDRE.",
			"LASER GRIP VINDER ALTID.",
			"FOR LANGSOMT, LILLE MENNESKE!",
		],
		serve_msg = "JARBI SERVERER...",
		you_won = "DU SLOG JARBI! LASER GRIP ER BESEJRET!",
		it_won = "JARBI VANDT. INGEN LETTE SEJRE.",
		wall_a = 0xff2c3236,
		wall_b = 0xff23282c,
		grid = 0xff1d7a3c,
		glow1 = 0xff3dff7a,
		glow2 = 0xffe8202c,
		bat_glow = 0xff3dff7a,
		bat_w = 0.26,
		bat_h = 0.42,
		speed = 1.7,
		err = 0.32,
		lasers = true,
	},
];

const ZONE_MSG: [4]str = [
	"MOENSTER FUNDET: OPPE TIL VENSTRE!",
	"MOENSTER FUNDET: OPPE TIL HOEJRE!",
	"MOENSTER FUNDET: NEDE TIL VENSTRE!",
	"MOENSTER FUNDET: NEDE TIL HOEJRE!",
];

type state = enum { TITLE, INTRO, READY, PLAYING, POINT, OVER };

type game = struct {
	st: state,
	stage: size,       // which opponent (index in STAGES)
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
	zx: f64,           // the opponent's bat (z = DEPTH)
	zy: f64,
	tx: f64,           // where the AI is heading
	ty: f64,
	me: int,
	ai: int,
	returns: int,      // how many times the opponent has hit the ball
	you_serve: bool,
	msg: str,
	// The AI's memory: how often your shots went to each corner.
	seen: [4]int,
	last_zone: int,
	streak: int,
	learn_msg: str,
	learn_t: f64,
	flash: f64,        // your paddle lights up after a hit
	sfx: int,          // 0 quiet, 1 paddle, 2 wall, 3 your point, 4 AI point, 5 learned, 6 laser
	rng: u32,
};

type pics = struct {
	title: [TITLE_FRAMES]viper::image,
	title_ok: [TITLE_FRAMES]bool,
	face: [NSTAGES][MAXF]viper::image,
	face_ok: [NSTAGES][MAXF]bool,
	bat: [NSTAGES]viper::image,
	bat_ok: [NSTAGES]bool,
	window: [NSTAGES]viper::image,
	window_ok: [NSTAGES]bool,
	pod: [NSTAGES]viper::image,
	pod_ok: [NSTAGES]bool,
	bat_glow: [NSTAGES]viper::image,
	glow_gold: viper::image,
	paddle: viper::image,
	paddle_hit: viper::image,
};

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
	g.returns = 0;
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

fn start_stage(g: *game, s: size) void = {
	g.stage = s;
	new_match(g);
	set_state(g, state::INTRO);
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

// The opponent decides where to go. It guesses better as the match goes
// on, and much better in a corner where you have shot before.
fn aim_ai(g: *game) void = {
	const s = STAGES[g.stage];
	const (lx, ly) = predict(g);
	let err = s.err - 0.04 * (g.me + g.ai): f64;
	if (err < 0.08) err = 0.08;
	if (g.seen[zone_of(lx, ly)] >= 2) err *= 0.35;
	g.tx = clampf(lx + (rnd(g) - 0.5) * 2.0 * err, -HX + s.bat_w, HX - s.bat_w);
	g.ty = clampf(ly + (rnd(g) - 0.5) * 2.0 * err * 0.75, -HY + s.bat_h, HY - s.bat_h);
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
	const s = STAGES[g.stage];
	if (mine) {
		g.me += 1;
		g.msg = "POINT TIL DIG!";
		g.sfx = 3;
	} else {
		g.msg = s.taunts[g.ai: size % len(s.taunts)];
		g.ai += 1;
		g.sfx = 4;
	};
	g.you_serve = !mine;
	set_state(g, state::POINT);
};

fn step_ball(g: *game, dt: f64) void = {
	const s = STAGES[g.stage];
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
	// The opponent's end. Later in the match it puts spin on too.
	if (g.bz >= DEPTH && g.vz > 0.0) {
		if (absf(g.bx - g.zx) <= s.bat_w + R && absf(g.by - g.zy) <= s.bat_h + R) {
			g.bz = DEPTH;
			g.vz = -g.vz;
			g.vx = clampf(g.vx * 0.5 + (g.bx - g.zx) * 3.0, -3.0, 3.0);
			g.vy = clampf(g.vy * 0.5 + (g.by - g.zy) * 3.0, -3.0, 3.0);
			const curve = 0.4 * (g.me + g.ai): f64;
			g.spx = (rnd(g) - 0.5) * curve;
			g.spy = (rnd(g) - 0.5) * curve;
			g.sfx = 1;
			g.returns += 1;
			// JARBI: every third return is a LASER GRIP shot - fast and
			// with a lot of spin.
			if (s.lasers && g.returns % 3 == 0) {
				g.vz = clampf(g.vz * 1.3, -9.5, -3.0);
				g.spx = (rnd(g) - 0.5) * 5.0;
				g.spy = (rnd(g) - 0.5) * 3.5;
				g.learn_msg = "LASER GRIP!";
				g.learn_t = 1.2;
				g.sfx = 6;
			};
		} else {
			point(g, true);
		};
	};
};

fn move_ai(g: *game, dt: f64) void = {
	const s = STAGES[g.stage];
	let speed = s.speed + 0.1 * (g.me + g.ai): f64;
	if (speed > s.speed + 1.2) speed = s.speed + 1.2;
	let (gx, gy) = favourite(g);
	if (g.st == state::PLAYING && g.vz > 0.0) {
		gx = g.tx;
		gy = g.ty;
	};
	g.zx = clampf(g.zx + clampf(gx - g.zx, -speed * dt, speed * dt),
		-HX + s.bat_w, HX - s.bat_w);
	g.zy = clampf(g.zy + clampf(gy - g.zy, -speed * dt, speed * dt),
		-HY + s.bat_h, HY - s.bat_h);
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
		if (viper::key_pressed(win, viper::key::J)) {
			start_stage(g, 1);
		} else if (go) {
			start_stage(g, 0);
		};
	case state::INTRO =>
		if (go && g.st_t > 0.3) set_state(g, state::READY);
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
				const s = STAGES[g.stage];
				g.msg = if (g.me >= WIN_SCORE) s.you_won else s.it_won;
				set_state(g, state::OVER);
			} else {
				set_state(g, state::READY);
			};
		};
	case state::OVER =>
		if (go && g.st_t > 0.8) {
			if (g.me < WIN_SCORE) {
				// Lost: try the same opponent again.
				new_match(g);
				set_state(g, state::READY);
			} else if (g.stage + 1 < NSTAGES) {
				start_stage(g, g.stage + 1);   // the next opponent
			} else {
				set_state(g, state::TITLE);    // you beat them all
			};
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
	for (let i = 0z; i < TITLE_FRAMES; i += 1) {
		const a = fmt::bsprintf(buf, "assets/pong2/arena-{}.png", i)!;
		match (load_scaled(a, 520, 520)) {
		case let img: viper::image =>
			p.title[i] = img;
			p.title_ok[i] = true;
		case void => void;
		};
	};
	// Size of things at the far end of the tunnel, in pixels.
	const far = scale(DEPTH);
	for (let s = 0z; s < NSTAGES; s += 1) {
		const st = STAGES[s];
		for (let i = 0z; i < st.frames && i < MAXF; i += 1) {
			const f = fmt::bsprintf(buf, "assets/pong2/{}-{}.png", st.file, i)!;
			match (load_scaled(f, 420, 420)) {
			case let img: viper::image =>
				p.face[s][i] = img;
				p.face_ok[s][i] = true;
			case void => void;
			};
		};
		if (st.bat_file != "") {
			const f = fmt::bsprintf(buf, "assets/pong2/{}.png", st.bat_file)!;
			match (load_scaled(f, (2.0 * st.bat_w * far): int, (2.0 * st.bat_h * far): int)) {
			case let img: viper::image =>
				p.bat[s] = img;
				p.bat_ok[s] = true;
			case void => void;
			};
		};
		if (st.window_file != "") {
			const f = fmt::bsprintf(buf, "assets/pong2/{}.png", st.window_file)!;
			match (load_scaled(f, (2.0 * HX * far): int, (2.0 * HY * far): int)) {
			case let img: viper::image =>
				p.window[s] = img;
				p.window_ok[s] = true;
			case void => void;
			};
		};
		if (st.pod_file != "") {
			const f = fmt::bsprintf(buf, "assets/pong2/{}.png", st.pod_file)!;
			match (load_scaled(f, 800, 450)) {
			case let img: viper::image =>
				p.pod[s] = img;
				p.pod_ok[s] = true;
			case void => void;
			};
		};
		p.bat_glow[s] = make_glow(48, st.bat_glow);
	};
	p.glow_gold = make_glow(30, GOLD);
	p.paddle = make_paddle(false);
	p.paddle_hit = make_paddle(true);
};

fn free_pics(p: *pics) void = {
	for (let i = 0z; i < TITLE_FRAMES; i += 1) {
		if (p.title_ok[i]) viper::image_free(&p.title[i]);
	};
	for (let s = 0z; s < NSTAGES; s += 1) {
		for (let i = 0z; i < MAXF; i += 1) {
			if (p.face_ok[s][i]) viper::image_free(&p.face[s][i]);
		};
		if (p.bat_ok[s]) viper::image_free(&p.bat[s]);
		if (p.window_ok[s]) viper::image_free(&p.window[s]);
		if (p.pod_ok[s]) viper::image_free(&p.pod[s]);
		viper::image_free(&p.bat_glow[s]);
	};
	viper::image_free(&p.glow_gold);
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
// ceiling (y = -HY): a flare, a strip, chevrons and a glowing eye.
fn neon_strip(win: *viper::window, s: *stage, y: f64, t: f64) void = {
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
	viper::polygon(win, outer, s.glow2);
	viper::polygon(win, inner, viper::mix(s.wall_a, DARK, 0.35));
	quad(win, (-0.035, y, 0.0), (0.035, y, 0.0), (0.035, y, DEPTH), (-0.035, y, DEPTH),
		viper::mix(s.glow1, DARK, 0.25));
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
	viper::polygon(win, eye, s.glow1);
	viper::polygon(win, pupil, DARK);
	// Chevrons pointing into the tunnel; they light up one after another.
	const lit = (t * 4.0): int % 3;
	for (let k = 0; k < 3; k += 1) {
		const z = 2.0 + k: f64 * 0.35;
		const col = if (k == lit) viper::rgb(255, 255, 255) else s.glow1;
		line3(win, (-0.12, y, z), (0.0, y, z + 0.18), col);
		line3(win, (0.0, y, z + 0.18), (0.12, y, z), col);
	};
};

// JARBI's UFO-pod: red laser conduits pulsing along the walls.
fn lasers(win: *viper::window, s: *stage, t: f64) void = {
	for (let k = 0; k < 6; k += 1) {
		const z0 = k: f64 * DEPTH / 6.0, z1 = (k + 1): f64 * DEPTH / 6.0;
		const pulse = 0.5 + 0.5 * math::sinf64(t * 6.0 - k: f64 * 0.9);
		const col = fog(viper::mix(viper::mix(s.glow2, DARK, 0.5), s.glow2, pulse), z0);
		for (let side = -1; side <= 1; side += 2) {
			const x = side: f64 * HX;
			line3(win, (x, -HY * 0.45, z0), (x, -HY * 0.45, z1), col);
			line3(win, (x, HY * 0.45, z0), (x, HY * 0.45, z1), col);
			line3(win, (side: f64 * 0.62, -HY, z0), (side: f64 * 0.62, -HY, z1), col);
		};
	};
};

fn draw_tunnel(win: *viper::window, g: *game, p: *pics) void = {
	let s = STAGES[g.stage];
	viper::clear(win, DARK);
	// The light gets hotter the more points the opponent has.
	const heat = minf(0.35, g.ai: f64 * 0.05);
	// Wall panels, far to near, fading into the distance.
	for (let k = SEGS - 1; k >= 0; k -= 1) {
		const z0 = k: f64 * DEPTH / SEGS: f64, z1 = (k + 1): f64 * DEPTH / SEGS: f64;
		const base = viper::mix(if (k % 2 == 0) s.wall_a else s.wall_b, s.glow2, heat);
		const tb = fog(base, z0);
		const side = fog(viper::mix(base, DARK, 0.18), z0);
		quad(win, (-HX, -HY, z0), (HX, -HY, z0), (HX, -HY, z1), (-HX, -HY, z1), tb);
		quad(win, (-HX, HY, z0), (HX, HY, z0), (HX, HY, z1), (-HX, HY, z1), tb);
		quad(win, (-HX, -HY, z0), (-HX, HY, z0), (-HX, HY, z1), (-HX, -HY, z1), side);
		quad(win, (HX, -HY, z0), (HX, HY, z0), (HX, HY, z1), (HX, -HY, z1), side);
	};
	// The grid lines running down the tunnel.
	for (let k = 0; k < 6; k += 1) {
		const z0 = k: f64 * DEPTH / 6.0, z1 = (k + 1): f64 * DEPTH / 6.0;
		const col = fog(s.grid, z0);
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
		const z = k: f64 * DEPTH / SEGS: f64;
		ring(win, z, fog(s.grid, z));
	};
	if (s.lasers) lasers(win, &s, g.t);
	neon_strip(win, &s, -HY, g.t);
	neon_strip(win, &s, HY, g.t);
	// The far wall: black, or a window out into space.
	const x0 = sx(-HX, DEPTH): int, x1 = sx(HX, DEPTH): int;
	const y0 = sy(-HY, DEPTH): int, y1 = sy(HY, DEPTH): int;
	if (p.window_ok[g.stage]) {
		viper::draw_image(win, &p.window[g.stage], x0, y0);
	} else {
		viper::rect(win, x0, y0, x1 - x0, y1 - y0, viper::rgb(0, 0, 0));
	};
	viper::outline(win, x0, y0, x1 - x0, y1 - y0, s.glow1);
	viper::outline(win, x0 - 1, y0 - 1, x1 - x0 + 2, y1 - y0 + 2, s.glow1);
};

// The opponent's bat: a picture (JARBI's energy shield), or neon zebra
// stripes with a pink glowing frame.
fn draw_bat(win: *viper::window, g: *game, p: *pics) void = {
	const s = STAGES[g.stage];
	const x0 = sx(g.zx - s.bat_w, DEPTH), x1 = sx(g.zx + s.bat_w, DEPTH);
	const y0 = sy(g.zy - s.bat_h, DEPTH), y1 = sy(g.zy + s.bat_h, DEPTH);
	const w = (x1 - x0): int, h = (y1 - y0): int;
	glow_at(win, &p.bat_glow[g.stage], (x0 + x1) / 2.0, (y0 + y1) / 2.0);
	if (p.bat_ok[g.stage]) {
		viper::draw_image(win, &p.bat[g.stage], x0: int, y0: int);
		return;
	};
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
	viper::outline(win, x0: int, y0: int, w, h, s.glow2);
	viper::outline(win, x0: int - 1, y0: int - 1, w + 2, h + 2, s.glow2);
	viper::outline(win, x0: int - 2, y0: int - 2, w + 4, h + 4, viper::mix(s.glow2, DARK, 0.5));
};

fn draw_ball(win: *viper::window, g: *game, p: *pics) void = {
	const s = STAGES[g.stage];
	// The frame shows how deep in the tunnel the ball is.
	ring(win, g.bz, s.glow1);
	// Its shadow on the floor.
	let pts: [10](f64, f64) = [(0.0, 0.0)...];
	for (let k = 0z; k < 10; k += 1) {
		const a = k: f64 * 2.0 * math::PI / 10.0;
		const z = g.bz + math::sinf64(a) * R * 1.2;
		pts[k] = (sx(g.bx + math::cosf64(a) * R * 1.4, z), sy(HY, z));
	};
	viper::polygon(win, pts, viper::mix(s.wall_a, DARK, 0.75));
	// The light trail: it bends when the ball has spin.
	if (g.st == state::PLAYING) {
		for (let i = TRAIL; i > 1; i -= 1) {
			const k = i - 1;
			const f = k: f64 / TRAIL: f64;
			const tz = g.trail_z[k];
			const r = (R * scale(tz) * (1.0 - f * 0.8)): int;
			viper::circle(win, sx(g.trail_x[k], tz): int, sy(g.trail_y[k], tz): int, r,
				fog(viper::mix(GOLD, s.glow2, f), tz));
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
	const s = STAGES[g.stage];
	let b1: [32]u8 = [0...], b2: [32]u8 = [0...];
	const me = fmt::bsprintf(b1, "DIG {}", g.me)!;
	const ai = fmt::bsprintf(b2, "{} {}", g.ai, s.short)!;
	viper::text_scaled(win, 22, 14, me, viper::rgb(0, 0, 0), 3);
	viper::text_scaled(win, 20, 12, me, CYAN, 3);
	const x = W - 20 - viper::text_width(ai, 3);
	viper::text_scaled(win, x + 2, 14, ai, viper::rgb(0, 0, 0), 3);
	viper::text_scaled(win, x, 12, ai, s.glow2, 3);
};

fn draw_title(win: *viper::window, g: *game, p: *pics) void = {
	viper::clear(win, DARK);
	const f = (g.t / GIF_T): size % TITLE_FRAMES;
	if (p.title_ok[f]) {
		viper::draw_image(win, &p.title[f], 140, 4);
	} else {
		centered(win, 200, "GOLDEN PONG 3D 2", 4, GOLD);
	};
	viper::rect(win, 0, 528, W, 72, DARK);
	if ((g.t * 2.0): int % 2 == 0) {
		centered(win, 540, "KLIK ELLER ENTER FOR AT STARTE", 2, CYAN);
	};
	centered(win, 574, "J: hop direkte til bossen JARBI", 1, viper::rgb(61, 255, 122));
	viper::text_scaled(win, W - 70, 10, "DEMO", PINK, 2);
};

fn draw_intro(win: *viper::window, g: *game, p: *pics) void = {
	const s = STAGES[g.stage];
	viper::clear(win, DARK);
	// The opponent's arena behind everything, if there is a picture of it.
	if (p.pod_ok[g.stage]) viper::draw_image(win, &p.pod[g.stage], 0, 75);
	const f = (g.t / s.frame_t): size % s.frames;
	if (p.face_ok[g.stage][f]) viper::draw_image(win, &p.face[g.stage][f], 16, 90);
	viper::outline(win, 15, 89, 422, 422, s.glow2);
	// A dark panel for the typewriter text.
	viper::rect(win, 444, 120, 340, 260, DARK);
	viper::outline(win, 444, 120, 340, 260, s.glow1);
	let left = (g.st_t * 26.0): size;
	for (let i = 0z; i < len(s.intro) && left > 0; i += 1) {
		const line = s.intro[i];
		const n = if (left < len(line)) left else len(line);
		left -= n;
		const col = if (i == 0) s.glow2 else if (i == len(s.intro) - 1) GOLD else s.glow1;
		viper::text_scaled(win, 456, 136 + i: int * 40, strings::sub(line, 0, n), col, 2);
	};
	if (g.st_t > 3.5 && (g.t * 2.0): int % 2 == 0) {
		centered(win, 540, "KLIK FOR AT SPILLE", 2, GOLD);
	};
};

fn draw_game(win: *viper::window, g: *game, p: *pics) void = {
	const s = STAGES[g.stage];
	draw_tunnel(win, g, p);
	draw_bat(win, g, p);
	draw_ball(win, g, p);
	draw_player(win, g, p);
	draw_score(win, g);

	if (g.learn_t > 0.0 && (g.t * 6.0): int % 2 == 0) {
		centered(win, 520, g.learn_msg, 2, s.glow2);
	};
	switch (g.st) {
	case state::TITLE, state::INTRO, state::PLAYING => void;
	case state::READY =>
		centered(win, 470, if (g.you_serve) "KLIK FOR AT SERVE" else s.serve_msg,
			2, viper::rgb(240, 240, 240));
	case state::POINT =>
		centered(win, 470, g.msg, 2, if (g.msg == "POINT TIL DIG!") CYAN else s.glow2);
	case state::OVER =>
		viper::rect(win, 0, 240, W, 100, DARK);
		centered(win, 262, g.msg, 2, GOLD);
		if (g.st_t > 0.8) {
			const next = if (g.me < WIN_SCORE) "KLIK FOR AT PROEVE IGEN"
				else if (g.stage + 1 < NSTAGES) "KLIK: EN NY UDFORDRER NAERMER SIG..."
				else "DU HAR BESEJRET ALLE! KLIK FOR TITEL";
			centered(win, 302, next, 2, CYAN);
		};
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
	// JARBI's LASER GRIP shot: a falling zap.
	let s_zap = viper::tone(viper::wave::SAW, 1800.0, 180.0, 0.3, 0.4, 0.002);
	defer viper::sound_free(&s_zap);
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
		case 6 => viper::play(snd, &s_zap, 0.7, 1.0);
		case => void;
		};
		g.sfx = 0;
		viper::audio_pump(snd);
		viper::present(win);
	};
};
