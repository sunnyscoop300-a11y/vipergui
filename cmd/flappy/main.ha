// Flappy Crane — a ViperGui game demo.
// Space / click / Up to flap. Fly Crane through the bamboo. Esc quits.
use fmt;
use math::random;
use viper;

def W: int = 400;
def H: int = 600;
def GROUND: int = 540;      // y where the ground starts
def BIRD_X: f64 = 110.0;
def BIRD_R: int = 11;
def GRAVITY: f64 = 1500.0;  // px/s^2
def FLAP: f64 = -430.0;     // px/s
def SPEED: f64 = 150.0;     // px/s, how fast the bamboo scrolls
def STALK_W: int = 56;
def GAP: int = 150;
def SPACING: f64 = 210.0;
def NSTALKS: size = 3;

type state = enum { READY, PLAYING, DEAD };

type stalk = struct {
	x: f64,
	gap_y: int,  // top of the gap
	scored: bool,
};

type game = struct {
	st: state,
	y: f64,
	vy: f64,
	stalks: [NSTALKS]stalk,
	score: int,
	best: int,
	scroll: f64,    // ground/background offset
	t: f64,         // time, for wing/bob animation
	dead_t: f64,
    sfx: int,       // 0 = stille, 1 = flap, 2 = point, 3 = ouch
	rng: random::random,
};

fn random_gap(g: *game) int =
	70 + random::u32n(&g.rng, (GROUND - GAP - 140): u32): int;

fn reset(g: *game) void = {
	g.st = state::READY;
	g.y = 260.0;
	g.vy = 0.0;
	g.score = 0;
	g.dead_t = 0.0;
    g.sfx = 0;
	for (let i = 0z; i < NSTALKS; i += 1) {
		g.stalks[i] = stalk {
			x = W: f64 + 120.0 + i: f64 * SPACING,
			gap_y = random_gap(g),
			scored = false,
		};
	};
};

fn hits(g: *game) bool = {
	const by = g.y: int, bx = BIRD_X: int;
	if (by + BIRD_R >= GROUND) return true;
	if (by - BIRD_R < 0) return true;
	for (let s .. g.stalks) {
		const sx = s.x: int;
		// Slightly forgiving hitbox.
		if (bx + BIRD_R - 3 < sx || bx - BIRD_R + 3 > sx + STALK_W) continue;
		if (by - BIRD_R + 3 < s.gap_y || by + BIRD_R - 3 > s.gap_y + GAP) {
			return true;
		};
	};
	return false;
};

fn update(win: *viper::window, g: *game) void = {
	const dt = viper::delta(win);
	g.t += dt;
	const flap = viper::key_pressed(win, viper::key::SPACE)
		|| viper::key_pressed(win, viper::key::UP)
		|| viper::mouse_pressed(win);

	switch (g.st) {
	case state::READY =>
		g.scroll += SPEED * dt;
		g.y = 260.0 + 8.0 * sinish(g.t * 3.0);
		if (flap) {
			g.st = state::PLAYING;
			     g.vy = FLAP;
            g.sfx = 1;
		};
	case state::PLAYING =>
		g.scroll += SPEED * dt;
		if (flap) { g.vy = FLAP; g.sfx = 1; };
		g.vy += GRAVITY * dt;
		g.y += g.vy * dt;

		for (let i = 0z; i < NSTALKS; i += 1) {
			let s = &g.stalks[i];
			s.x -= SPEED * dt;
			if (!s.scored && s.x + STALK_W: f64 < BIRD_X) {
				s.scored = true;
				g.score += 1;
                g.sfx = 2;
			};
			if (s.x < -STALK_W: f64) {
				// Recycle behind the right-most stalk.
				let maxx = s.x;
				for (let o .. g.stalks) if (o.x > maxx) maxx = o.x;
				s.x = maxx + SPACING;
				s.gap_y = random_gap(g);
				s.scored = false;
			};
		};

		if (hits(g)) {
			g.st = state::DEAD;
			g.vy = -200.0;
			if (g.score > g.best) g.best = g.score;
            g.sfx = 3;
		};
	case state::DEAD =>
		g.dead_t += dt;
		// Crane tumbles to the ground.
		if (g.y < (GROUND - BIRD_R): f64) {
			g.vy += GRAVITY * dt;
			g.y += g.vy * dt;
			if (g.y > (GROUND - BIRD_R): f64) g.y = (GROUND - BIRD_R): f64;
		};
		if (flap && g.dead_t > 0.5) reset(g);
	};
};

// A cheap smooth wave in -1..1 (avoids pulling in math for one sine).
fn sinish(x: f64) f64 = {
	let p = x / 6.283185307;
	p -= (p: i64): f64;
	if (p < 0.0) p += 1.0;
	// Triangle wave, then smoothed: good enough for a bobbing bird.
	const tri = if (p < 0.5) 4.0 * p - 1.0 else 3.0 - 4.0 * p;
	return tri * (1.5 - 0.5 * tri * tri);
};

fn draw_background(win: *viper::window, g: *game) void = {
	// Dusk sky gradient.
	for (let y = 0; y < GROUND; y += 1) {
		const c = viper::mix(0xff7fb6e0, 0xfff6d6a8, y: f64 / GROUND: f64);
		viper::rect(win, 0, y, W, 1, c);
	};
	// Sun.
	viper::circle(win, 300, 150, 34, 0xfffbe7b8);

	// Distant mountains, scrolling slowly (parallax).
	const off = (g.scroll * 0.2): int;
	for (let x = 0; x < W; x += 1) {
		const p = (x + off) % 240;
		const h = if (p < 120) p else 240 - p;
		const top = GROUND - 90 - h;
		viper::rect(win, x, top, 1, GROUND - top, 0xff9fb4a6);
	};
	// Closer hills.
	const off2 = (g.scroll * 0.5): int;
	for (let x = 0; x < W; x += 1) {
		const p = (x + off2) % 160;
		const h = if (p < 80) p / 2 else (160 - p) / 2;
		const top = GROUND - 30 - h;
		viper::rect(win, x, top, 1, GROUND - top, 0xff6f9a72);
	};
};

fn draw_stalk(win: *viper::window, s: *stalk) void = {
	const x = s.x: int;
	const green: viper::color = 0xff4f9a3c;
	const light: viper::color = 0xff7cc45a;
	const dark: viper::color = 0xff2f6b25;
	// Top and bottom bamboo.
	const parts: [2](int, int) = [(0, s.gap_y), (s.gap_y + GAP, GROUND)];
	for (let (y0, y1) .. parts) {
		viper::rect(win, x, y0, STALK_W, y1 - y0, green);
		viper::rect(win, x + 8, y0, 8, y1 - y0, light);
		viper::rect(win, x + STALK_W - 8, y0, 6, y1 - y0, dark);
		// Bamboo joints every 46 px.
		for (let y = y0 + 40; y < y1 - 6; y += 46) {
			viper::rect(win, x - 2, y, STALK_W + 4, 5, dark);
		};
	};
	// Caps at the gap edges.
	viper::rect(win, x - 5, s.gap_y - 14, STALK_W + 10, 14, dark);
	viper::rect(win, x - 3, s.gap_y - 12, STALK_W + 6, 10, green);
	viper::rect(win, x - 5, s.gap_y + GAP, STALK_W + 10, 14, dark);
	viper::rect(win, x - 3, s.gap_y + GAP + 2, STALK_W + 6, 10, green);
};

fn draw_ground(win: *viper::window, g: *game) void = {
	viper::rect(win, 0, GROUND, W, H - GROUND, 0xffc79a5b);
	viper::rect(win, 0, GROUND, W, 8, 0xff7a9a3c);
	viper::rect(win, 0, GROUND + 8, W, 3, 0xff8a6a3a);
	const off = (g.scroll: int) % 24;
	for (let x = -off; x < W; x += 24) {
		viper::rect(win, x, GROUND + 20, 12, 4, 0xffb4864a);
		viper::rect(win, x + 12, GROUND + 38, 12, 4, 0xffb4864a);
	};
};

// Sprite frames cut from assets/crane/crane.png (if it exists).
def SPRITE_W: int = 60;
def MAX_FRAMES: size = 8;

type sheet = struct {
	frames: [MAX_FRAMES]viper::image,
	n: size,
};

// Loads a sprite sheet whose frames sit side by side, separated by fully
// transparent columns. Every frame gets the same box (so the bird doesn't
// jump between frames) and is scaled to SPRITE_W pixels wide.
fn load_sheet(path: str) (sheet | void) = {
	let img = match (viper::load_png(path)) {
	case let i: viper::image => yield i;
	case viper::imgerror => return;
	};
	defer viper::image_free(&img);

	// Find runs of columns that contain visible pixels, and the overall
	// top/bottom of the artwork.
	let starts: [MAX_FRAMES]int = [0...], ends: [MAX_FRAMES]int = [0...];
	let n = 0z, top = img.h, bottom = 0, inrun = false;
	for (let x = 0; x < img.w; x += 1) {
		let used = false;
		for (let y = 0; y < img.h; y += 1) {
			if (img.pixels[(y * img.w + x): size] >> 24 > 20) {
				used = true;
				if (y < top) top = y;
				if (y > bottom) bottom = y;
			};
		};
		if (used && !inrun && n < MAX_FRAMES) {
			starts[n] = x;
			inrun = true;
		} else if (!used && inrun) {
			ends[n] = x;
			n += 1;
			inrun = false;
		};
	};
	if (inrun) { ends[n] = img.w; n += 1; };
	if (n == 0) return;

	let bw = 0;
	for (let i = 0z; i < n; i += 1) {
		if (ends[i] - starts[i] > bw) bw = ends[i] - starts[i];
	};
	const bh = bottom - top + 1;
	const h = SPRITE_W * bh / bw;

	let sh = sheet { n = n, ... };
	for (let i = 0z; i < n; i += 1) {
		const cx = (starts[i] + ends[i]) / 2;
		let fr = viper::crop(&img, cx - bw / 2, top, bw, bh)!;
		defer viper::image_free(&fr);
		sh.frames[i] = viper::resize(&fr, SPRITE_W, h)!;
	};
	return sh;
};

fn draw_sprite_crane(win: *viper::window, g: *game, sh: *sheet) void = {
	// Wing cycle: down, middle, up, middle, ... (ping-pong over the frames).
	let f = 0z;
	if (sh.n > 1) {
		const cycle = (sh.n - 1) * 2;
		const speed = if (g.st == state::PLAYING && g.vy < 0.0) 16.0 else 9.0;
		let k = (g.t * speed): size % cycle;
		f = if (k < sh.n) k else cycle - k;
	};
	if (g.st == state::DEAD) f = sh.n / 2;
	const fr = &sh.frames[f];
	const x = BIRD_X: int - fr.w / 2;
	let y = g.y: int - fr.h / 2;
	if (y + fr.h > GROUND + 4) y = GROUND + 4 - fr.h; // land on the ground
	viper::draw_image(win, fr, x, y);
	if (g.st == state::DEAD) {
		// Little dizzy stars.
		for (let i = 0; i < 3; i += 1) {
			const a = g.t * 4.0 + i: f64 * 2.1;
			const sx = BIRD_X: int + (sinish(a) * 18.0): int;
			const sy = y - 6 + (sinish(a + 1.57) * 5.0): int;
			viper::rect(win, sx - 1, sy - 3, 3, 7, 0xfffff2a0);
			viper::rect(win, sx - 3, sy - 1, 7, 3, 0xfffff2a0);
		};
	};
};

fn draw_crane(win: *viper::window, g: *game) void = {
	const x = BIRD_X: int, y = g.y: int;
	// Lean with vertical speed.
	let tilt = (g.vy / 120.0): int;
	if (tilt < -3) tilt = -3;
	if (tilt > 5) tilt = 5;

	// Long legs trailing behind.
	viper::line(win, x - 8, y + 6, x - 22, y + 10 + tilt, 0xff3a3a3a);
	viper::line(win, x - 7, y + 8, x - 21, y + 13 + tilt, 0xff3a3a3a);

	// Body.
	viper::circle(win, x, y, BIRD_R, 0xff2a2a2a);
	viper::circle(win, x, y, BIRD_R - 2, 0xfff5f2ea);

	// Wing flaps: up, mid, down.
	const phase = if (g.st == state::DEAD) 1
		else ((g.t * 12.0): int % 3);
	const wy = switch (phase) {
	case 0 => yield -12;
	case 1 => yield -2;
	case => yield 8;
	};
	viper::line(win, x - 6, y - 1, x - 2 - 14, y + wy, 0xff2a2a2a);
	viper::line(win, x - 5, y, x - 2 - 12, y + wy + 2, 0xff2a2a2a);
	viper::line(win, x - 4, y + 1, x - 2 - 10, y + wy + 4, 0xff2a2a2a);

	// Neck and head.
	const hx = x + 12, hy = y - 7 + tilt;
	viper::line(win, x + 6, y - 3, hx, hy, 0xfff5f2ea);
	viper::line(win, x + 7, y - 3, hx + 1, hy, 0xfff5f2ea);
	viper::circle(win, hx, hy, 6, 0xff2a2a2a);
	viper::circle(win, hx, hy, 5, 0xfff5f2ea);
	viper::rect(win, hx - 3, hy - 6, 6, 3, 0xffd03a2f);    // red cap
	viper::line(win, hx + 5, hy, hx + 14, hy + 2 + tilt / 2, 0xff3a3a3a); // beak
	viper::line(win, hx + 5, hy + 1, hx + 13, hy + 3 + tilt / 2, 0xff3a3a3a);
	if (g.st == state::DEAD) {
		// X eye.
		viper::line(win, hx, hy - 2, hx + 3, hy + 1, 0xff101010);
		viper::line(win, hx + 3, hy - 2, hx, hy + 1, 0xff101010);
	} else {
		viper::rect(win, hx + 1, hy - 1, 2, 2, 0xff101010);
	};
	// Straw hat brim (Crane's trademark).
	viper::rect(win, hx - 9, hy - 9, 18, 2, 0xffc9a35a);
	viper::rect(win, hx - 4, hy - 13, 8, 4, 0xffd9b56a);
};

fn shadow_text(win: *viper::window, x: int, y: int, s: str, scale: int) void = {
	viper::text_scaled(win, x + scale, y + scale, s, 0xff3a2a18, scale);
	viper::text_scaled(win, x, y, s, 0xfffff8e8, scale);
};

fn centered(win: *viper::window, y: int, s: str, scale: int) void =
	shadow_text(win, (W - viper::text_width(s, scale)) / 2, y, s, scale);

// Dark text for use on the light score panel.
fn centered_dark(win: *viper::window, y: int, s: str, scale: int, col: viper::color) void =
	viper::text_scaled(win, (W - viper::text_width(s, scale)) / 2, y, s, col, scale);

export fn main() void = {
	const win = match (viper::open("Flappy Crane - ViperGui", W, H)) {
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
	let fwip = viper::tone(viper::wave::TRIANGLE, 400.0, 900.0, 0.08, 0.5, 0.005);
	let pling = viper::tone(viper::wave::SINE, 1200.0, 1800.0, 0.12, 0.4, 0.005);
	let bonk = viper::tone(viper::wave::SQUARE, 300.0, 60.0, 0.4, 0.5, 0.005);
	defer viper::sound_free(&fwip);
	defer viper::sound_free(&pling);
	defer viper::sound_free(&bonk);

	let g = game { rng = random::init(viper::ticks(): u64 + 7), ... };
	let sprites = load_sheet("assets/crane/crane.png");
	// Crane as the window icon (X11; on Wayland it comes from the
	// .desktop file installed by `make desktop`).
	match (viper::load_png("assets/crane/flappy-crane-64.png")) {
	case let icon: viper::image =>
		viper::set_icon(win, &icon);
		viper::image_free(&icon);
	case viper::imgerror => void;
	};
	reset(&g);
	let buf: [32]u8 = [0...];

	for (viper::frame(win)) {
		if (viper::key_pressed(win, viper::key::ESCAPE)) break;
		update(win, &g);

		draw_background(win, &g);
		for (let i = 0z; i < NSTALKS; i += 1) draw_stalk(win, &g.stalks[i]);
		draw_ground(win, &g);
		match (sprites) {
		case let sh: sheet => draw_sprite_crane(win, &g, &sh);
		case void => draw_crane(win, &g);
		};

		switch (g.st) {
		case state::READY =>
			centered(win, 70, "FLAPPY", 4);
			centered(win, 140, "CRANE", 4);
			centered(win, 380, "Space / click to fly", 1);
			if (g.best > 0) {
				centered(win, 404, fmt::bsprintf(buf, "Best: {}", g.best)!, 1);
			};
		case state::PLAYING =>
			centered(win, 40, fmt::bsprintf(buf, "{}", g.score)!, 4);
		case state::DEAD =>
			viper::rect(win, 70, 180, 260, 170, 0xfff6ead0);
			viper::outline(win, 70, 180, 260, 170, 0xff8c6a43);
			viper::outline(win, 72, 182, 256, 166, 0xffc9a35a);
			centered_dark(win, 196, "OUCH!", 3, 0xffd03a2f);
			centered_dark(win, 252, fmt::bsprintf(buf, "Score: {}", g.score)!, 2, 0xff2d2418);
			centered_dark(win, 284, fmt::bsprintf(buf, "Best:  {}", g.best)!, 2, 0xff2d2418);
			if (g.dead_t > 0.5) {
				centered_dark(win, 322, "Flap to try again", 1, 0xff7d6b52);
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
