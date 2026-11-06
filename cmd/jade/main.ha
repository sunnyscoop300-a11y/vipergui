// JADE — Den jadegrønne slange. A snake game in isometric 3D, an example
// for ViperGui: everything is drawn with ViperGui's 2D shapes, and the 3D
// comes from the isometric projection and back-to-front drawing in
// render.ha.
//
// Arrows or WASD steer (up = toward the upper right, see the compass),
// P pauses, M mutes, Esc goes back to the menu.
use fmt;
use fs;
use io;
use math;
use math::random;
use os;
use strconv;
use strings;
use time;
use viper;

def W: int = 860;
def H: int = 640;

type screen = enum { MENU, PLAY, PAUSE, OVER, CLEAR };

type petal = struct { x: f64, y: f64, vx: f64, vy: f64, spin: f64 };
type spark = struct { x: f64, y: f64, vx: f64, vy: f64, life: f64, col: u32 };

type game = struct {
	s: state,
	scr: screen,
	clock: f64,
	acc: f64,              // time since the last step
	scr_t: f64,            // time on this screen
	best: int,
	new_best: bool,
	shake: f64,
	turn_mode: bool,       // classic view: false = screen arrows, true = turn
	vw: view,              // which camera
	cam: cams,
	r: r3d,
	banner: str,
	banner_buf: [64]u8,
	banner_t: f64,
	petals: [36]petal,
	sparks: [64]spark,
	nspark: size,
	snd: *viper::audio,
	bank: *bank,
	rng: random::random,
};

fn play_sfx(g: *game, which: sfx, vol: f64) void =
	viper::play(g.snd, &g.bank[which], vol, 1.0);

fn seed() u64 = {
	const t = time::now(time::clock::MONOTONIC);
	return t.sec: u64 * 1000000007 + t.nsec: u64;
};

fn new_game(g: *game) void = {
	g.s = new_state(seed());
	g.scr = screen::PLAY;
	g.scr_t = 0.0;
	g.acc = 0.0;
	g.new_best = false;
	show_banner(g, garden_of(1).name);
	play_sfx(g, sfx::START, 1.0);
};

fn show_banner(g: *game, text: str) void = {
	const b = strings::toutf8(text);
	const n = if (len(b) > len(g.banner_buf)) len(g.banner_buf) else len(b);
	g.banner_buf[..n] = b[..n];
	g.banner = strings::fromutf8_unsafe(g.banner_buf[..n]);
	g.banner_t = 2.2;
};

// Where a point of the garden is on screen, in the current view.
fn on_screen(g: *game, x: f64, y: f64, z: f64) (f64, f64) = {
	if (g.vw == view::CLASSIC) return iso(x, y, z);
	match (project(&g.r, v(x, z, y))) {
	case let p: (f64, f64, f64) => return (p.0, p.1);
	case void => return (-999.0, -999.0);
	};
};

fn burst(g: *game, x: f64, y: f64, z: f64, a: u32, b: u32) void = {
	const (sx, sy) = on_screen(g, x, y, z);
	for (let i = 0; i < 16; i += 1) {
		if (g.nspark >= len(g.sparks)) break;
		const ang = random::f64rand(&g.rng) * 2.0 * math::PI;
		const sp = 60.0 + random::f64rand(&g.rng) * 120.0;
		g.sparks[g.nspark] = spark { x = sx, y = sy, vx = math::cosf64(ang) * sp,
			vy = math::sinf64(ang) * sp - 80.0, life = 0.7,
			col = if (i % 2 == 0) a else b };
		g.nspark += 1;
	};
};

// Runs the snake's steps for this frame. The menu lets the autopilot play.
fn run(g: *game, dt: f64, auto: bool) void = {
	tick_gold(&g.s, dt);
	g.acc += dt;
	for (g.acc >= step_time(&g.s)) {
		g.acc -= step_time(&g.s);
		if (auto) autopilot(&g.s);
		const food = g.s.food, gold = g.s.gold;
		switch (step(&g.s)) {
		case event::EAT =>
			burst(g, food.0: f64 + 0.5, food.1: f64 + 0.5, 0.45, 0xffff9a6a, 0xff7fe4b4);
			if (!auto) play_sfx(g, sfx::EAT, 0.8);
		case event::GOLD =>
			burst(g, gold.0: f64 + 0.5, gold.1: f64 + 0.5, 0.5, 0xffffd23a, 0xfffff2d8);
			if (!auto) {
				play_sfx(g, sfx::GOLD, 0.9);
				show_banner(g, "Gyldent dumpling!");
			};
		case event::DIE =>
			g.acc = 0.0;
			if (auto) {
				g.s = new_state(seed());
				return;
			};
			g.shake = 0.5;
			play_sfx(g, sfx::CRASH, 1.0);
			if (g.s.score > g.best) {
				g.best = g.s.score;
				g.new_best = true;
				save_best(g.best);
			};
			g.scr = screen::OVER;
			g.scr_t = 0.0;
			return;
		case event::CLEAR =>
			const (hx, hy) = g.s.body[0];
			burst(g, hx: f64 + 0.5, hy: f64 + 0.5, 0.5, 0xffffd23a, 0xffff9ad0);
			if (auto) {
				next_garden(&g.s);
				return;
			};
			play_sfx(g, sfx::CLEAR, 1.0);
			g.scr = screen::CLEAR;
			g.scr_t = 0.0;
			g.acc = 0.0;
			return;
		case event::NONE => void;
		};
	};
};

fn handle_keys(win: *viper::window, g: *game) void = {
	for (let ev .. viper::key_events(win)) {
		if (!ev.down || ev.repeat) continue;
		const a: (arrow | void) = switch (ev.hid) {
		case 82, 26 => yield arrow::N;     // up arrow, W
		case 79, 7 => yield arrow::E;      // right arrow, D
		case 81, 22 => yield arrow::S;     // down arrow, S
		case 80, 4 => yield arrow::W;      // left arrow, A
		case => yield void;
		};
		const a = match (a) {
		case let a: arrow => yield a;
		case void => continue;
		};
		const turned = if (g.vw == view::CHASE) {
			// Behind her, left and right are her own left and right.
			yield if (a == arrow::E || a == arrow::W)
				side_turn(&g.s, a == arrow::E) else false;
		} else if (g.vw == view::BIRD) {
			// From above, the arrows point the way the camera sees it.
			const before = g.s.nq;
			turn(&g.s, ((g.cam.bird_q + a: int) % 4): dir);
			yield g.s.nq != before;
		} else if (g.turn_mode) {
			// Only left and right count: they turn her from where she's heading.
			yield if (a == arrow::E || a == arrow::W)
				side_turn(&g.s, a == arrow::E) else false;
		} else screen_turn(&g.s, a);
		if (turned) play_sfx(g, sfx::TURN, 0.5);
	};
};

export fn main() void = {
	const win = match (viper::open("Jade", W, H)) {
	case let w: *viper::window => yield w;
	case let e: viper::error =>
		fmt::fatal("jade:", viper::strerror(e));
	case nomem =>
		fmt::fatal("jade: out of memory");
	};
	defer viper::close(win);
	match (viper::load_png("assets/jade/jade-icon-64.png")) {
	case let icon: viper::image =>
		viper::set_icon(win, &icon);
		viper::image_free(&icon);
	case viper::imgerror => void;
	};
	const snd = viper::audio_open();
	defer viper::audio_close(snd);
	let sounds = make_bank();
	let bg = make_background();
	defer viper::image_free(&bg);

	let g = game {
		s = new_state(seed()),
		scr = screen::MENU,
		best = load_best(),
		turn_mode = load_mode(),
		vw = load_view(),
		r = r3d_new(win),
		snd = snd,
		bank = &sounds,
		rng = random::init(seed()),
		...
	};
	for (let i = 0z; i < len(g.petals); i += 1) {
		g.petals[i] = petal {
			x = random::f64rand(&g.rng) * W: f64,
			y = random::f64rand(&g.rng) * H: f64,
			vx = 18.0 + random::f64rand(&g.rng) * 30.0,
			vy = 20.0 + random::f64rand(&g.rng) * 25.0,
			spin = random::f64rand(&g.rng) * 6.0,
		};
	};

	for (viper::frame(win)) {
		const dt = viper::delta(win);
		g.clock += dt;
		g.scr_t += dt;
		if (viper::key_pressed(win, viper::key::M)) {
			viper::set_muted(snd, !viper::is_muted(snd));
		};
		const enter = viper::key_pressed(win, viper::key::RETURN)
			|| viper::key_pressed(win, viper::key::KP_ENTER)
			|| viper::key_pressed(win, viper::key::SPACE);
		const esc = viper::key_pressed(win, viper::key::ESCAPE);
		const pkey = viper::key_pressed(win, viper::key::P);
		if (viper::key_pressed(win, viper::key::C)) {
			g.vw = ((g.vw: int + 1) % 3): view;
			g.cam.ready = false;
			save_view(g.vw);
			show_banner(&g, view_name(g.vw));
		};
		if (g.vw == view::BIRD && viper::key_pressed(win, viper::key::Q)) {
			g.cam.bird_q = (g.cam.bird_q + 3) % 4;
		};
		if (g.vw == view::BIRD && viper::key_pressed(win, viper::key::E)) {
			g.cam.bird_q = (g.cam.bird_q + 1) % 4;
		};
		if (g.vw == view::CLASSIC && viper::key_pressed(win, viper::key::TAB)) {
			g.turn_mode = !g.turn_mode;
			save_mode(g.turn_mode);
			show_banner(&g, if (g.turn_mode) "Styring: drej" else "Styring: skærm");
		};

		switch (g.scr) {
		case screen::MENU =>
			if (esc) break;
			if (enter || viper::mouse_pressed(win)) new_game(&g)
			else run(&g, dt, true);
		case screen::PLAY =>
			if (esc) {
				g.scr = screen::MENU;
				g.s = new_state(seed());
			} else if (pkey || viper::key_pressed(win, viper::key::SPACE)) {
				g.scr = screen::PAUSE;
			} else {
				handle_keys(win, &g);
				run(&g, dt, false);
			};
		case screen::PAUSE =>
			if (esc) {
				g.scr = screen::MENU;
				g.s = new_state(seed());
			} else if (pkey || enter) g.scr = screen::PLAY;
		case screen::CLEAR =>
			if (g.scr_t > 1.8) {
				next_garden(&g.s);
				g.scr = screen::PLAY;
				let buf: [48]u8 = [0...];
				show_banner(&g, fmt::bsprintf(buf, "Have {}: {}", g.s.level,
					garden_of(g.s.level).name)!);
			};
		case screen::OVER =>
			if (esc) {
				g.scr = screen::MENU;
				g.s = new_state(seed());
			} else if (enter && g.scr_t > 0.6) new_game(&g);
		};

		draw(win, &g, &bg, dt);
		viper::audio_pump(snd);
		viper::present(win);
	};
};

fn draw(win: *viper::window, g: *game, bg: *viper::image, dt: f64) void = {
	// A shake when she crashes.
	if (g.shake > 0.0) g.shake -= dt;
	const sh = if (g.shake > 0.0) g.shake * 14.0 else 0.0;
	const live = g.scr == screen::PLAY || g.scr == screen::MENU;
	let f = if (live) g.acc / step_time(&g.s) else 1.0;
	if (f > 1.0) f = 1.0;

	if (g.vw == view::CLASSIC) {
		viper::draw_image(win, bg, 0, 0);
		draw_lanterns(win, g);
		OX = 430.0 + math::sinf64(g.clock * 70.0) * sh;
		OY = 196.0 + math::cosf64(g.clock * 53.0) * sh * 0.5;
		draw_garden(win, &g.s, f, g.clock, !g.s.alive);
	} else {
		// Real 3D: place the camera, then sky, garden and markers.
		update_camera(&g.cam, g.vw, &g.s, f, dt);
		const shake = v(math::sinf64(g.clock * 70.0) * sh * 0.02,
			math::cosf64(g.clock * 53.0) * sh * 0.015, 0.0);
		const cam = look_at(vadd(g.cam.pos, shake), g.cam.target, W, H,
			if (g.vw == view::CHASE) 66.0 else 50.0);
		r3d_begin(&g.r, cam);
		draw_sky3d(win, &g.r, g.clock);
		draw_garden3d(&g.r, &g.s, f, g.clock, !g.s.alive, g.scr == screen::PLAY);
		food_markers3d(win, &g.r, &g.s, g.clock);
		draw_lanterns(win, g);
	};
	draw_sparks(win, g, dt);
	draw_petals(win, g, dt);

	if (g.scr == screen::MENU) {
		draw_menu(win, g);
		return;
	};
	draw_hud(win, g);
	if (g.banner_t > 0.0) {
		g.banner_t -= dt;
		const a = if (g.banner_t > 0.4) 1.0 else g.banner_t / 0.4;
		const w = viper::text_width(g.banner, 3) + 40;
		viper::round_rect(win, (W - w) / 2, 96, w, 50, 14, 0xff123a2a);
		viper::round_rect(win, (W - w) / 2 + 3, 99, w - 6, 44, 12,
			viper::mix(0xff123a2a, 0xff1e5a40, a));
		viper::text_scaled(win, (W - w) / 2 + 20, 106, g.banner,
			viper::mix(0xff123a2a, C_GOLD, a), 3);
	};
	switch (g.scr) {
	case screen::PAUSE =>
		overlay(win, "Pause", "P eller Enter: videre   Esc: menu", "");
	case screen::CLEAR =>
		overlay(win, "Haven er fuld!", "Videre til næste have...", "");
	case screen::OVER =>
		let buf: [64]u8 = [0...], buf2: [64]u8 = [0...];
		const l2 = fmt::bsprintf(buf, "{} point i have {}", g.s.score, g.s.level)!;
		const l3 = if (g.new_best) "Ny rekord!"
			else fmt::bsprintf(buf2, "Rekord: {}", g.best)!;
		overlay(win, "Slangen slog knude!", l2, l3);
		if (g.scr_t > 0.6) {
			const t = "Enter: prøv igen   Esc: menu";
			viper::text(win, (W - viper::text_width(t, 1)) / 2, 400, t, 0xfff2e6cc);
		};
	case => void;
	};
};

fn overlay(win: *viper::window, title: str, l2: str, l3: str) void = {
	viper::round_rect(win, 170, 220, 520, 210, 22, C_GOLD);
	viper::round_rect(win, 174, 224, 512, 202, 20, 0xff123a2a);
	viper::text_scaled(win, (W - viper::text_width(title, 3)) / 2, 252, title, C_GOLD, 3);
	viper::text_scaled(win, (W - viper::text_width(l2, 2)) / 2, 318, l2, 0xfff2e6cc, 2);
	if (len(l3) > 0) {
		viper::text_scaled(win, (W - viper::text_width(l3, 2)) / 2, 356, l3, 0xffff9ad0, 2);
	};
};

fn draw_menu(win: *viper::window, g: *game) void = {
	const bob = math::sinf64(g.clock * 1.6) * 5.0;
	viper::round_rect(win, 230, 22, 400, 150, 24, C_GOLD);
	viper::round_rect(win, 234, 26, 392, 142, 22, 0xff123a2a);
	viper::text_scaled(win, (W - viper::text_width("JADE", 6)) / 2 + 4,
		(32.0 + bob): int + 4, "JADE", 0xff0a2018, 6);
	viper::text_scaled(win, (W - viper::text_width("JADE", 6)) / 2,
		(32.0 + bob): int, "JADE", 0xff6ae0a8, 6);
	const sub = "Den jadegrønne slange";
	viper::text_scaled(win, (W - viper::text_width(sub, 2)) / 2, 132, sub, C_GOLD, 2);

	if (math::sinf64(g.clock * 4.0) > -0.3) {
		const s = "Enter: start spillet";
		viper::text_scaled(win, (W - viper::text_width(s, 2)) / 2, 540, s, 0xfffff2d8, 2);
	};
	let buf: [48]u8 = [0...];
	const b = fmt::bsprintf(buf, "Rekord: {}", g.best)!;
	viper::text(win, (W - viper::text_width(b, 1)) / 2, 576, b, 0xffffd0a8);
	const k = "Pile/WASD: styr   C: kamera   P: pause   M: lyd   Esc: afslut";
	viper::text(win, (W - viper::text_width(k, 1)) / 2, 600, k, 0xffc8b8d0);
	draw_steering(win, g);
};

fn draw_hud(win: *viper::window, g: *game) void = {
	let buf: [48]u8 = [0...];
	// Score, top left.
	viper::round_rect(win, 16, 14, 220, 70, 14, 0xc0123a2a);
	viper::text_scaled(win, 30, 22, "JADE", 0xff6ae0a8, 2);
	viper::text(win, 112, 26, "point", 0xffc8b8a0);
	viper::text_scaled(win, 30, 48, fmt::bsprintf(buf, "{}", g.s.score)!, 0xfffff2d8, 2);
	viper::text(win, 150, 56, fmt::bsprintf(buf, "rekord {}", g.best)!, 0xffc8b8a0);

	// The garden and its peaches, top right.
	viper::round_rect(win, W - 300, 14, 284, 70, 14, 0xc0123a2a);
	const name = garden_of(g.s.level).name;
	viper::text(win, W - 286, 24, fmt::bsprintf(buf, "Have {}: {}", g.s.level, name)!, C_GOLD);
	for (let i = 0; i < GOAL; i += 1) {
		const x = W - 278 + i * 26, y = 60;
		if (i < g.s.eaten) {
			ball(win, x: f64, y: f64, 9.0, 0xffc04a3a, 0xffff9a6a, 0xffffd0a8);
		} else {
			viper::circle(win, x, y, 9, 0xff2a4a3a);
			viper::circle(win, x, y, 7, 0xff1a3428);
		};
	};
	if (g.s.gold_t > 0.0) {
		viper::text(win, W - 300, 92,
			fmt::bsprintf(buf, "Gyldent dumpling: {} s", (g.s.gold_t + 0.99): int)!, 0xffffd23a);
	};
	draw_steering(win, g);
	viper::text(win, W - 250, H - 28, "P: pause   M: lyd   Esc: menu", 0xffc8b8d0);
};

// How to steer, bottom left: the screen-arrow compass, or the turn keys.
fn draw_steering(win: *viper::window, g: *game) void = {
	if (g.vw == view::CHASE) {
		viper::round_rect(win, 16, 500, 200, 100, 16, 0xff123a2a);
		viper::text_scaled(win, 30, 512, "<  A", C_GOLD, 2);
		viper::text(win, 110, 520, "drej venstre", 0xfff2e6cc);
		viper::text_scaled(win, 30, 552, "D  >", C_GOLD, 2);
		viper::text(win, 110, 560, "drej højre", 0xfff2e6cc);
		viper::text(win, 24, 612, "C: skift kamera", 0xffc8b8d0);
		return;
	};
	if (g.vw == view::BIRD) {
		draw_compass(win, 92.0, 540.0);
		viper::text(win, 24, 612, "Q/E: drej kamera   C: kamera", 0xffc8b8d0);
		return;
	};
	if (!g.turn_mode) {
		draw_compass(win, 92.0, 540.0);
		viper::text(win, 24, 612, "Styring: skærm (Tab)  C: kamera", 0xffc8b8d0);
		return;
	};
	viper::round_rect(win, 16, 500, 200, 100, 16, 0xff123a2a);
	viper::text_scaled(win, 30, 512, "<  A", C_GOLD, 2);
	viper::text(win, 110, 520, "drej venstre", 0xfff2e6cc);
	viper::text_scaled(win, 30, 552, "D  >", C_GOLD, 2);
	viper::text(win, 110, 560, "drej højre", 0xfff2e6cc);
	viper::text(win, 24, 612, "Styring: drej (Tab)  C: kamera", 0xffc8b8d0);
};

// Which key goes which way. The arrows turn her toward that side of the
// screen; W/up is up-right or up-left, whichever is a turn from where she
// is going.
fn draw_compass(win: *viper::window, cx: f64, cy: f64) void = {
	viper::circle(win, cx: int, cy: int, 58, 0xff123a2a);
	const labels = ["W", "D", "S", "A"];
	const vec: [4](f64, f64) = [(0.0, -1.0), (1.0, 0.0), (0.0, 1.0), (-1.0, 0.0)];
	for (let i = 0z; i < 4; i += 1) {
		const (fx, fy) = vec[i];
		const tx = cx + fx * 32.0, ty = cy + fy * 32.0;
		for (let k = -1; k <= 1; k += 1) {
			const ox = -fy * k: f64, oy = fx * k: f64;
			viper::line(win, (cx + ox): int, (cy + oy): int, (tx + ox): int, (ty + oy): int, 0xff6ae0a8);
		};
		const head: [3](f64, f64) = [(tx + fx * 9.0, ty + fy * 9.0),
			(tx - fy * 7.0, ty + fx * 7.0), (tx + fy * 7.0, ty - fx * 7.0)];
		viper::polygon(win, head, 0xff6ae0a8);
		viper::text(win, (cx + fx * 48.0 - 4.0): int, (cy + fy * 46.0 - 8.0): int,
			labels[i], C_GOLD);
	};
	viper::circle(win, cx: int, cy: int, 5, C_GOLD);
};

// Two paper lanterns hanging from the top corners.
fn draw_lanterns(win: *viper::window, g: *game) void = {
	for (let i = 0; i < 2; i += 1) {
		const x = if (i == 0) 40.0 else W: f64 - 40.0;
		const sway = math::sinf64(g.clock * 1.3 + i: f64) * 4.0;
		const y = 150.0;
		viper::line(win, x: int, 0, (x + sway): int, (y - 20.0): int, 0xff2a1a1a);
		blend_ellipse(win, x + sway, y, 46.0, 46.0, 0xff6a3a, 40);
		viper::round_rect(win, (x + sway - 16.0): int, (y - 22.0): int, 32, 44, 14, 0xffd83a2a);
		viper::rect(win, (x + sway - 10.0): int, (y - 24.0): int, 20, 4, C_GOLD);
		viper::rect(win, (x + sway - 10.0): int, (y + 20.0): int, 20, 4, C_GOLD);
		viper::rect(win, (x + sway - 1.0): int, (y + 24.0): int, 2, 10, C_GOLD);
	};
};

fn draw_petals(win: *viper::window, g: *game, dt: f64) void = {
	for (let p &.. g.petals) {
		p.x += p.vx * dt;
		p.y += p.vy * dt;
		p.spin += dt * 3.0;
		if (p.x > W: f64 + 10.0) p.x = -10.0;
		if (p.y > H: f64 + 10.0) {
			p.y = -10.0;
			p.x = random::f64rand(&g.rng) * W: f64;
		};
		const w = math::absf64(math::cosf64(p.spin)) * 4.0 + 1.0;
		blend_ellipse(win, p.x, p.y, w, 2.5, 0xffb8d8, 200);
	};
};

fn draw_sparks(win: *viper::window, g: *game, dt: f64) void = {
	let i = 0z;
	for (i < g.nspark) {
		let s = &g.sparks[i];
		s.life -= dt;
		if (s.life <= 0.0) {
			g.nspark -= 1;
			g.sparks[i] = g.sparks[g.nspark];
			continue;
		};
		s.x += s.vx * dt;
		s.y += s.vy * dt;
		s.vy += 300.0 * dt;
		const r = (s.life * 6.0): int + 1;
		viper::circle(win, s.x: int, s.y: int, r, s.col);
		i += 1;
	};
};

// ---- The record, in ~/.local/share/jade/best ----

fn data_dir() (str | void) = {
	match (os::getenv("XDG_DATA_HOME")) {
	case let d: str =>
		if (len(d) > 0) return strings::concat(d, "/jade")!;
	case void => void;
	};
	match (os::getenv("HOME")) {
	case let h: str => return strings::concat(h, "/.local/share/jade")!;
	case void => return;
	};
};

// The camera, in ~/.local/share/jade/kamera (0, 1 or 2).
fn load_view() view = {
	const dir = match (data_dir()) {
	case let d: str => yield d;
	case void => return view::CHASE;
	};
	defer free(dir);
	const path = strings::concat(dir, "/kamera")!;
	defer free(path);
	const f = match (os::open(path)) {
	case let f: io::file => yield f;
	case => return view::CHASE;
	};
	defer io::close(f)!;
	let buf: [4]u8 = [0...];
	match (io::read(f, buf)) {
	case let n: size =>
		if (n > 0 && buf[0] >= '0' && buf[0] <= '2') return (buf[0] - '0'): view;
	case => void;
	};
	return view::CHASE;
};

fn save_view(vw: view) void = {
	const dir = match (data_dir()) {
	case let d: str => yield d;
	case void => return;
	};
	defer free(dir);
	match (os::mkdirs(dir, fs::mode::USER_RWX)) {
	case => void;
	};
	const path = strings::concat(dir, "/kamera")!;
	defer free(path);
	const f = match (os::create(path, 0o644)) {
	case let f: io::file => yield f;
	case => return;
	};
	defer io::close(f)!;
	match (fmt::fprintln(f, vw: int)) {
	case => void;
	};
};

// The steering mode, in ~/.local/share/jade/styring ("drej" or "skærm").
fn load_mode() bool = {
	const dir = match (data_dir()) {
	case let d: str => yield d;
	case void => return false;
	};
	defer free(dir);
	const path = strings::concat(dir, "/styring")!;
	defer free(path);
	const f = match (os::open(path)) {
	case let f: io::file => yield f;
	case => return false;
	};
	defer io::close(f)!;
	let buf: [16]u8 = [0...];
	const n = match (io::read(f, buf)) {
	case let n: size => yield n;
	case => return false;
	};
	return n >= 4 && strings::fromutf8_unsafe(buf[..4]) == "drej";
};

fn save_mode(turn: bool) void = {
	const dir = match (data_dir()) {
	case let d: str => yield d;
	case void => return;
	};
	defer free(dir);
	match (os::mkdirs(dir, fs::mode::USER_RWX)) {
	case => void;
	};
	const path = strings::concat(dir, "/styring")!;
	defer free(path);
	const f = match (os::create(path, 0o644)) {
	case let f: io::file => yield f;
	case => return;
	};
	defer io::close(f)!;
	match (fmt::fprintln(f, if (turn) "drej" else "skærm")) {
	case => void;
	};
};

fn load_best() int = {
	const dir = match (data_dir()) {
	case let d: str => yield d;
	case void => return 0;
	};
	defer free(dir);
	const path = strings::concat(dir, "/best")!;
	defer free(path);
	const f = match (os::open(path)) {
	case let f: io::file => yield f;
	case => return 0;
	};
	defer io::close(f)!;
	const data = match (io::drain(f)) {
	case let d: []u8 => yield d;
	case => return 0;
	};
	defer free(data);
	const s = match (strings::fromutf8(data)) {
	case let s: str => yield strings::trim(s);
	case => return 0;
	};
	return match (strconv::stoi(s)) {
	case let n: int => yield n;
	case => yield 0;
	};
};

fn save_best(n: int) void = {
	const dir = match (data_dir()) {
	case let d: str => yield d;
	case void => return;
	};
	defer free(dir);
	match (os::mkdirs(dir, fs::mode::USER_RWX)) {
	case => void;
	};
	const path = strings::concat(dir, "/best")!;
	defer free(path);
	const f = match (os::create(path, 0o644)) {
	case let f: io::file => yield f;
	case => return;
	};
	defer io::close(f)!;
	match (fmt::fprintln(f, n)) {
	case => void;
	};
};
