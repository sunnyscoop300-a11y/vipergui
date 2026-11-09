// Golden Pong 3D — a ViperGui game.
// Move the mouse to steer your paddle, click / Space to serve. Esc quits.
// The golden ball flies through a zebra-striped tunnel; at the far end
// a zebra defends its goal, and a zebra referee calls every point.
// First to 7 wins.
use fmt;
use viper;

def W: int = 800;
def H: int = 600;
def CX: f64 = 400.0;
def CY: f64 = 300.0;
def F: f64 = 380.0;      // focal length: screen px per world unit at z = 0
def Z0: f64 = 1.0;       // camera distance to the near end of the tunnel
def DEPTH: f64 = 8.0;    // tunnel length
def HX: f64 = 1.0;       // tunnel half width
def HY: f64 = 0.75;      // tunnel half height
def R: f64 = 0.09;       // ball radius
def PW: f64 = 0.32;      // paddle half width
def PH: f64 = 0.24;      // paddle half height
def WIN_SCORE: int = 7;
def SEGS: int = 8;       // zebra stripes along the tunnel

type state = enum { READY, PLAYING, POINT, OVER };

type game = struct {
	st: state,
	bx: f64, by: f64, bz: f64,   // ball position
	vx: f64, vy: f64, vz: f64,   // ball speed
	px: f64, py: f64,            // your paddle (z = 0)
	zx: f64, zy: f64,            // zebra paddle (z = DEPTH)
	me: int,
	zebra: int,
	level: int,
	msg: str,
	pause: f64,
	t: f64,
    hit: int,    // 0 = intet, 1 = din pind, 2 = zebraens pind, 3 = point
};

// --- 3D -> 2D: the only maths a tunnel needs ---
fn sx(x: f64, z: f64) f64 = CX + x * F / (z + Z0);
fn sy(y: f64, z: f64) f64 = CY + y * F / (z + Z0);

fn absf(x: f64) f64 = if (x < 0.0) -x else x;

fn clampf(x: f64, lo: f64, hi: f64) f64 =
	if (x < lo) lo else if (x > hi) hi else x;

fn reset(g: *game) void = {
	g.me = 0;
	g.zebra = 0;
	g.level = 1;
	g.px = 0.0;
	g.py = 0.0;
	g.zx = 0.0;
	g.zy = 0.0;
	g.bx = 0.0;
	g.by = 0.0;
	g.bz = 0.3;
	g.vx = 0.0;
	g.vy = 0.0;
	g.vz = 0.0;
	g.msg = "";
	g.st = state::READY;
};

fn serve(g: *game) void = {
	g.bx = 0.0;
	g.by = 0.0;
	g.bz = 0.3;
	g.vx = 0.6;
	g.vy = 0.35;
	g.vz = 4.0 + g.level: f64 * 0.6;
	g.st = state::PLAYING;
};

fn point(g: *game, mine: bool) void = {
	if (mine) {
		g.me += 1;
		g.level += 1;
		g.msg = "FWEET! Zebra-dommeren: point til dig!";
	} else {
		g.zebra += 1;
		g.msg = "FWEET! Zebra-dommeren: point til zebraen!";
	};
	g.hit = 3;
	g.st = state::POINT;
	g.pause = 1.5;
};

fn update(win: *viper::window, g: *game) void = {
	const dt = viper::delta(win);
	g.t += dt;

	// Your paddle follows the mouse (mouse_x is -1 when it leaves the window).
	if (win.mouse_x >= 0 && win.mouse_y >= 0) {
		g.px = clampf((win.mouse_x: f64 - CX) / F * Z0, -HX + PW, HX - PW);
		g.py = clampf((win.mouse_y: f64 - CY) / F * Z0, -HY + PH, HY - PH);
	};

	const click = viper::mouse_pressed(win)
		|| viper::key_pressed(win, viper::key::SPACE);

	switch (g.st) {
	case state::READY =>
		if (click) serve(g);
		return;
	case state::OVER =>
		if (click) reset(g);
		return;
	case state::POINT =>
		g.pause -= dt;
		if (g.pause <= 0.0) {
			if (g.me >= WIN_SCORE || g.zebra >= WIN_SCORE) {
				g.st = state::OVER;
			} else {
				g.st = state::READY;
			};
		};
		return;
	case state::PLAYING => void;
	};

	// Zebra AI: chases the ball, a little faster every level.
	const ai = 0.6 + g.level: f64 * 0.32;
	if (g.vz > 0.0) {
		g.zx = clampf(g.zx + clampf(g.bx - g.zx, -ai * dt, ai * dt), -HX + PW, HX - PW);
		g.zy = clampf(g.zy + clampf(g.by - g.zy, -ai * dt, ai * dt), -HY + PH, HY - PH);
	};

	// Move the ball and bounce off the tunnel walls.
	g.bx += g.vx * dt;
	g.by += g.vy * dt;
	g.bz += g.vz * dt;
	if (g.bx < -HX + R) {
		g.bx = -HX + R;
		g.vx = -g.vx;
	};
	if (g.bx > HX - R) {
		g.bx = HX - R;
		g.vx = -g.vx;
	};
	if (g.by < -HY + R) {
		g.by = -HY + R;
		g.vy = -g.vy;
	};
	if (g.by > HY - R) {
		g.by = HY - R;
		g.vy = -g.vy;
	};

	// Your end: hit it with the edge of the paddle to curve it.
	if (g.bz <= 0.0 && g.vz < 0.0) {
		if (absf(g.bx - g.px) <= PW + R && absf(g.by - g.py) <= PH + R) {
			g.bz = 0.0;
			g.vz = -g.vz * 1.04;
            g.hit = 1;
			g.vx = clampf(g.vx + (g.bx - g.px) * 3.0, -3.0, 3.0);
			g.vy = clampf(g.vy + (g.by - g.py) * 3.0, -3.0, 3.0);
		} else {
			point(g, false);
		};
	};
	// The zebra's end.
	if (g.bz >= DEPTH && g.vz > 0.0) {
		if (absf(g.bx - g.zx) <= PW + R && absf(g.by - g.zy) <= PH + R) {
			g.bz = DEPTH;
			g.vz = -g.vz;
            g.hit = 2;
			g.vx = clampf(g.vx + (g.bx - g.zx) * 2.0, -3.0, 3.0);
			g.vy = clampf(g.vy + (g.by - g.zy) * 2.0, -3.0, 3.0);
		} else {
		  point(g, true);
		};
	};
};

// --- drawing ---

fn quad(win: *viper::window, a: (f64, f64), b: (f64, f64),
		c: (f64, f64), d: (f64, f64), col: viper::color) void =
	viper::polygon(win, [a, b, c, d], col);

// A rectangle frame at depth z (used for the gold depth marker).
fn ring(win: *viper::window, z: f64, col: viper::color) void = {
	const x0 = sx(-HX, z): int, x1 = sx(HX, z): int;
	const y0 = sy(-HY, z): int, y1 = sy(HY, z): int;
	viper::line(win, x0, y0, x1, y0, col);
	viper::line(win, x1, y0, x1, y1, col);
	viper::line(win, x1, y1, x0, y1, col);
	viper::line(win, x0, y1, x0, y0, col);
};

fn draw_tunnel(win: *viper::window, g: *game) void = {
	const white = viper::rgb(235, 235, 235);
	const black = viper::rgb(25, 25, 25);
	const seg = DEPTH / SEGS: f64;
	// Far to near, so the near walls end up on top.
	for (let k = SEGS - 1; k >= 0; k -= 1) {
		const z0 = k: f64 * seg, z1 = (k + 1): f64 * seg;
		const a = if (k % 2 == 0) white else black;
		const b = if (k % 2 == 0) black else white;
		// top + bottom
		quad(win, (sx(-HX, z0), sy(-HY, z0)), (sx(HX, z0), sy(-HY, z0)),
			(sx(HX, z1), sy(-HY, z1)), (sx(-HX, z1), sy(-HY, z1)), a);
		quad(win, (sx(-HX, z0), sy(HY, z0)), (sx(HX, z0), sy(HY, z0)),
			(sx(HX, z1), sy(HY, z1)), (sx(-HX, z1), sy(HY, z1)), a);
		// left + right, opposite colour = zebra pattern
		quad(win, (sx(-HX, z0), sy(-HY, z0)), (sx(-HX, z1), sy(-HY, z1)),
			(sx(-HX, z1), sy(HY, z1)), (sx(-HX, z0), sy(HY, z0)), b);
		quad(win, (sx(HX, z0), sy(-HY, z0)), (sx(HX, z1), sy(-HY, z1)),
			(sx(HX, z1), sy(HY, z1)), (sx(HX, z0), sy(HY, z0)), b);
	};
	// The back wall: the zebra's goal.
        const x0 = sx(-HX, DEPTH), x1 = sx(HX, DEPTH);
	const y0 = sy(-HY, DEPTH), y1 = sy(HY, DEPTH);
        const goals: [_]viper::color = [
		viper::rgb(40, 90, 60),    // grøn
		viper::rgb(40, 60, 120),   // blå
		viper::rgb(110, 40, 110),  // lilla
		viper::rgb(130, 50, 40),   // rød
		viper::rgb(150, 110, 20),  // guld
	];
	const goal = goals[(g.level - 1): size % len(goals)];
	viper::rect(win, x0: int, y0: int, (x1 - x0): int, (y1 - y0): int,
		viper::rgb(40, 90, 60));
};

fn draw_zebra(win: *viper::window, g: *game) void = {
	const x0 = sx(g.zx - PW, DEPTH), x1 = sx(g.zx + PW, DEPTH);
	const y0 = sy(g.zy - PH, DEPTH), y1 = sy(g.zy + PH, DEPTH);
	const w = (x1 - x0): int, h = (y1 - y0): int;
	viper::rect(win, x0: int, y0: int, w, h, viper::rgb(245, 245, 245));
	// black zebra stripes on the paddle
	for (let i = 0; i < 6; i += 2) {
		const s0 = x0 + (x1 - x0) * i: f64 / 6.0;
		viper::rect(win, s0: int, y0: int, w / 6, h, viper::rgb(20, 20, 20));
	};
	viper::outline(win, x0: int, y0: int, w, h, viper::rgb(255, 120, 40));
};

fn draw_ball(win: *viper::window, g: *game) void = {
	ring(win, g.bz, viper::rgb(255, 200, 40));   // shows how deep the ball is
	const r = (R * F / (g.bz + Z0)): int;
	const x = sx(g.bx, g.bz): int, y = sy(g.by, g.bz): int;
	viper::circle(win, x, y, r + 1, viper::rgb(120, 80, 0));
	viper::circle(win, x, y, r, viper::rgb(255, 196, 40));
	viper::circle(win, x - r / 3, y - r / 3, r / 3, viper::rgb(255, 245, 190));
};

// Your paddle is see-through (just a frame), so you can watch the ball.
fn draw_player(win: *viper::window, g: *game) void = {
	const gold = viper::rgb(255, 200, 40);
	const x0 = sx(g.px - PW, 0.0): int, y0 = sy(g.py - PH, 0.0): int;
	const w = (2.0 * PW * F / Z0): int, h = (2.0 * PH * F / Z0): int;
	viper::outline(win, x0, y0, w, h, gold);
	viper::outline(win, x0 + 1, y0 + 1, w - 2, h - 2, gold);
	viper::line(win, x0 + w / 2, y0, x0 + w / 2, y0 + h, gold);
	viper::line(win, x0, y0 + h / 2, x0 + w, y0 + h / 2, gold);
};

fn centered(win: *viper::window, y: int, s: str, scale: int, col: viper::color) void =
	viper::text_scaled(win, (W - viper::text_width(s, scale)) / 2, y, s, col, scale);

export fn main() void = {
	const win = match (viper::open("Golden Pong 3D - ViperGui", W, H)) {
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
	let plink = viper::tone(viper::wave::SQUARE, 880.0, 660.0, 0.06, 0.4, 0.002);
	defer viper::sound_free(&plink);
	let plonk = viper::tone(viper::wave::TRIANGLE, 330.0, 220.0, 0.08, 0.5, 0.002);
	defer viper::sound_free(&plonk);
	let fweet = viper::tone(viper::wave::SINE, 1800.0, 2400.0, 0.35, 0.4, 0.01);
	defer viper::sound_free(&fweet);

	let g = game { ... };
	reset(&g);
	let buf: [64]u8 = [0...];
	const gold = viper::rgb(255, 205, 60);
	const white = viper::rgb(240, 240, 240);

	for (viper::frame(win)) {
		if (viper::key_pressed(win, viper::key::ESCAPE)) break;
		update(win, &g);
        switch (g.hit) {
		case 1 => viper::play(snd, &plink, 1.0, 1.0);
		case 2 => viper::play(snd, &plonk, 1.0, 1.0);
		case 3 => viper::play(snd, &fweet, 1.0, 1.0);
		case => void;
		};
		g.hit = 0;
		viper::audio_pump(snd);
		viper::clear(win, viper::rgb(10, 10, 14));
		draw_tunnel(win, &g);
		draw_zebra(win, &g);
		draw_ball(win, &g);
		draw_player(win, &g);

		const score = fmt::bsprintf(buf, "DIG {}   ZEBRA {}", g.me, g.zebra)!;
		centered(win, 14, score, 2, gold);

		switch (g.st) {
		case state::READY =>
			centered(win, 250, "GOLDEN PONG 3D", 4, gold);
			centered(win, 320, "Klik for at serve", 2, white);
		case state::POINT =>
			centered(win, 290, g.msg, 2, white);
		case state::OVER =>
			centered(win, 250, if (g.me >= WIN_SCORE) "DU VANDT!" else "ZEBRAEN VANDT!", 4, gold);
			centered(win, 320, "Klik for en ny kamp", 2, white);
		case state::PLAYING => void;
		};

		viper::present(win);
	};
};
