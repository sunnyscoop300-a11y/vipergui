// BINES — Match Three, Make Magic!
// A honeycomb match-3 game made with ViperGui. Click a piece and then a
// neighbour (or drag it onto one) to swap. Lines of 3+ in any of the three
// hex directions are cleared; new pieces fall in and can chain into combos.
use fmt;
use math;
use math::random;
use strings;
use viper;

def W: int = 820;
def H: int = 660;

type state = enum { IDLE, SWAP, SWAPBACK, POP, FALL };

def SWAP_TIME: f64 = 0.16;
def POP_TIME: f64 = 0.24;
def HINT_AFTER: f64 = 7.0;

type floater = struct {
	x: f64,
	y: f64,
	text: [24]u8,
	n: size,
	life: f64,
	col: viper::color,
	scale: int,
};

type particle = struct {
	x: f64,
	y: f64,
	vx: f64,
	vy: f64,
	life: f64,
	col: viper::color,
};

type game = struct {
	b: board,
	st: state,
	t: f64,
	sel: (int, int),
	drag: (int, int),
	swap_a: (int, int),
	swap_b: (int, int),
	swap_dx: f64,   // where piece A starts, relative to its new cell
	swap_dy: f64,
	score: int,
	best: int,
	combo: int,
	level: int,
	moves: int,
	idle: f64,
	floats: [24]floater,
	parts: [256]particle,
	np: size,
	clock: f64,
	autoplay: bool,
	from_swap: bool,      // the current clear came straight from a swap
	meter: f64,           // honey collected this level
	goal: f64,            // honey needed to finish the level
	moves_left: int,
	scr: screen,
	bonus: int,
	new_best: bool,
	saved_best: int,      // best score on disk
	overlay_t: f64,       // when the level-done / game-over box appeared
	thief: thief,
	banners: [4]([32]u8, size, viper::color),
	nban: size,
	ban_t: f64,
	snd: nullable *viper::audio,
	bank: nullable *bank,
	beams: [8]beam,
	nbeam: size,
	rings: [8]ring,
	nring: size,
	queen: queen,
	inv: [NBOOST]int,     // boosters owned
	coins: int,           // guldhonning
	earned: int,          // guldhonning earned by the last level
	bk: size,             // the booster in use...
	bt: f64,              // ...and its animation clock, -1 when none
	bfired: bool,
	shop_back: screen,    // where the shop's Tilbage button goes
	shop_t: f64,
	shop_msg: (str, str),
	shop_msg_t: f64,
	hs: [NHS]hsentry,     // the highscore board
	nhs: size,
	rank: int,            // where this game lands on the board, 0 = not
	hs_new: int,          // the row to light up on the board
	hs_back: screen,
	cel_t: f64,           // ceremony / board clock
	cel_cup: bool,
	name_tb: viper::textinput,
	last_name: str,
	last_name_buf: [40]u8,
};

const NONE: (int, int) = (-1, -1);


fn float_text(g: *game, x: f64, y: f64, text: str, col: viper::color, scale: int) void = {
	// Reuse the oldest slot.
	let slot = 0z;
	for (let i = 0z; i < len(g.floats); i += 1) {
		if (g.floats[i].life < g.floats[slot].life) slot = i;
	};
	let f = &g.floats[slot];
	const b = strings::toutf8(text);
	const n = if (len(b) > len(f.text)) len(f.text) else len(b);
	f.text[..n] = b[..n];
	f.n = n;
	f.x = x;
	f.y = y;
	f.life = 1.3;
	f.col = col;
	f.scale = scale;
};

// Big messages (level up, thief...) are shown one at a time in a banner
// above the board, so they never pile up on top of each other.
fn announce(g: *game, text: str, col: viper::color) void = {
	if (g.nban >= len(g.banners)) return;
	let b = &g.banners[g.nban];
	const t = strings::toutf8(text);
	const n = if (len(t) > len(b.0)) len(b.0) else len(t);
	b.0[..n] = t[..n];
	b.1 = n;
	b.2 = col;
	if (g.nban == 0) g.ban_t = 0.0;
	g.nban += 1;
};

fn draw_banner(win: *viper::window, g: *game, dt: f64) void = {
	if (g.nban == 0) return;
	g.ban_t += dt;
	const dur = 1.4;
	if (g.ban_t > dur) {
		for (let i = 1z; i < g.nban; i += 1) g.banners[i - 1] = g.banners[i];
		g.nban -= 1;
		g.ban_t = 0.0;
		if (g.nban == 0) return;
	};
	const b = &g.banners[0];
	const text = strings::fromutf8_unsafe(b.0[..b.1]);
	const scale = if (b.1 > 20) 2 else 3;
	const w = viper::text_width(text, scale);
	// Slide in from above, then stay.
	const t = if (g.ban_t < 0.15) g.ban_t / 0.15 else 1.0;
	const y = (12.0 + t * 26.0): int;
	const x = 250 - w / 2;
	viper::round_rect(win, x - 14, y - 6, w + 28, 16 * scale + 12, 10, 0xe02a1604);
	viper::text_scaled(win, x + scale, y + scale, text, 0xff1a0d02, scale);
	viper::text_scaled(win, x, y, text, b.2, scale);
};

fn burst(g: *game, x: f64, y: f64, col: viper::color) void = {
	for (let i = 0; i < 6; i += 1) {
		const a = random::f64rand(&g.b.rng) * 2.0 * math::PI;
		const sp = 60.0 + random::f64rand(&g.b.rng) * 140.0;
		g.parts[g.np % len(g.parts)] = particle {
			x = x, y = y,
			vx = math::cosf64(a) * sp,
			vy = math::sinf64(a) * sp - 80.0,
			life = 0.5 + random::f64rand(&g.b.rng) * 0.4,
			col = col,
		};
		g.np += 1;
	};
};

fn start_swap(g: *game, a: (int, int), b: (int, int), back: bool) void = {
	swap_kinds(&g.b, a.0, a.1, b.0, b.1);
	const (ax, ay) = center(a.0, a.1);
	const (bx, by) = center(b.0, b.1);
	// Each piece now sits in the other's cell; ease it over from there.
	g.b.c[a.0][a.1].sx = bx - ax;
	g.b.c[a.0][a.1].sy = by - ay;
	g.b.c[b.0][b.1].sx = ax - bx;
	g.b.c[b.0][b.1].sy = ay - by;
	g.swap_a = a;
	g.swap_b = b;
	g.swap_dx = bx - ax;
	g.swap_dy = by - ay;
	g.st = if (back) state::SWAPBACK else state::SWAP;
	play_sfx(g, if (back) sfx::BONK else sfx::SWAP, 1.0, 1.0);
	g.t = 0.0;
	g.idle = 0.0;
};

// Resolves the marked pieces: turns big matches into power-ups, sets off
// power-ups, scores, fills the honey meter and starts the pop animation.
fn resolve(g: *game, longest: int) void = {
	if (g.b.nruns > 0) create_specials(g);
	const fired = fire_specials(g);
	let count = 0, honey = 0;
	for (let c = 0; c < COLS; c += 1) for (let r = 0; r < ROWS; r += 1) {
		if (!g.b.c[c][r].marked) continue;
		count += 1;
		if (g.b.c[c][r].kind == piece::HONEY) honey += 1;
	};
	if (count == 0) {
		g.st = state::FALL;
		return;
	};
	start_pop(g, count, longest, fired);

	// Honey: every cleared piece helps, honey drops and blasts more.
	const before = g.meter;
	g.meter += count: f64 * 1.5 + honey: f64 * 1.5 + fired: f64 * 5.0;
	if (g.meter > g.goal) g.meter = g.goal;
	if (before < g.goal && g.meter >= g.goal) {
		announce(g, "Krukken er fuld!", 0xffffd23a);
		play_sfx(g, sfx::CHIME, 1.0, 1.0);
	};
	thief_on_honey(g);
};

// Scores the marked pieces and starts the pop animation.
fn start_pop(g: *game, count: int, longest: int, fired: int) void = {
	g.combo += 1;
	// Each step of a cascade pops a little higher.
	const pitch = 1.0 + (if (g.combo > 8) 8 else g.combo - 1): f64 * 0.12;
	play_sfx(g, sfx::POP, 0.8, pitch);
	let pts = count * 10 * g.combo + fired * 50;
	if (longest > 3) pts += (longest - 3) * 40;
	g.score += pts;
	if (g.score > g.best) g.best = g.score;

	let sx = 0.0, sy = 0.0;
	for (let c = 0; c < COLS; c += 1) for (let r = 0; r < ROWS; r += 1) {
		if (!g.b.c[c][r].marked) continue;
		const (x, y) = center(c, r);
		sx += x;
		sy += y;
		const k = g.b.c[c][r].kind;
		burst(g, x, y, if (k < len(piece_color): u8) piece_color[k] else 0xffffffff);
	};
	sx /= count: f64;
	sy /= count: f64;
	let buf: [24]u8 = [0...];
	float_text(g, sx, sy, fmt::bsprintf(buf, "+{}", pts)!, 0xfffff4d0, 2);
	if (g.combo >= 3) {
		float_text(g, sx, sy - 30.0, fmt::bsprintf(buf, "Combo x{}!", g.combo)!,
			0xffff7a2a, 2);
	};
	if (longest >= 5) {
		float_text(g, sx, sy + 30.0, "Honningregn!", 0xffffd23a, 2);
	} else if (longest == 4) {
		float_text(g, sx, sy + 30.0, "Sødt!", 0xffffd23a, 2);
	};

	g.st = state::POP;
	g.t = 0.0;
};

fn try_swap(g: *game, a: (int, int), b: (int, int)) void = {
	if (!neighbours(a.0, a.1, b.0, b.1)) return;
	start_swap(g, a, b, false);
	g.sel = NONE;
	g.drag = NONE;
};

fn handle_input(win: *viper::window, g: *game) void = {
	const (mx, my) = viper::mouse(win);
	const hit = cell_at(mx, my);
	if (viper::mouse_pressed(win)) {
		g.idle = 0.0;
		match (hit) {
		case let h: (int, int) =>
			if (g.sel.0 >= 0 && neighbours(g.sel.0, g.sel.1, h.0, h.1)) {
				try_swap(g, g.sel, h);
				return;
			};
			g.sel = if (g.sel.0 == h.0 && g.sel.1 == h.1) NONE else h;
			g.drag = h;
		case void =>
			g.sel = NONE;
		};
	};
	// Dragging a piece onto a neighbour swaps them too.
	if (win.mouse_down && g.drag.0 >= 0) {
		match (hit) {
		case let h: (int, int) =>
			if (h.0 != g.drag.0 || h.1 != g.drag.1) {
				try_swap(g, g.drag, h);
			};
		case void => void;
		};
	};
	if (!win.mouse_down) g.drag = NONE;
};

fn update(win: *viper::window, g: *game) void = {
	const dt = viper::delta(win);
	g.clock += dt;

	switch (g.st) {
	case state::IDLE =>
		g.idle += dt;
		// No moves while a booster works its magic.
		if (g.bt >= 0.0) return;
		if (booster_try(win, g)) return;
		handle_input(win, g);
		// Demo mode (D): the game plays itself.
		if (g.autoplay && g.st == state::IDLE && g.idle > 0.6) {
			match (find_move(&g.b)) {
			case let m: (int, int, int, int) =>
				try_swap(g, (m.0, m.1), (m.2, m.3));
			case void => void;
			};
		};
	case state::SWAP, state::SWAPBACK =>
		g.t += dt / SWAP_TIME;
		// Ease-out: fast start, gentle landing.
		const e = if (g.t >= 1.0) 1.0 else 1.0 - (1.0 - g.t) * (1.0 - g.t);
		let a = &g.b.c[g.swap_a.0][g.swap_a.1];
		let b = &g.b.c[g.swap_b.0][g.swap_b.1];
		a.sx = g.swap_dx * (1.0 - e);
		a.sy = g.swap_dy * (1.0 - e);
		b.sx = -a.sx;
		b.sy = -a.sy;
		if (g.t < 1.0) return;
		if (g.st == state::SWAPBACK) {
			g.st = state::IDLE;
			return;
		};
		g.from_swap = true;
		const ka = g.b.c[g.swap_a.0][g.swap_a.1].kind;
		const kb = g.b.c[g.swap_b.0][g.swap_b.1].kind;
		if (ka == RAINBOW || kb == RAINBOW) {
			g.moves += 1;
			g.moves_left -= 1;
			g.combo = 0;
			rainbow_swap(g);
			resolve(g, 0);
			thief_on_move(g);
			return;
		};
		const (count, longest) = find_matches(&g.b);
		if (count > 0) {
			g.moves += 1;
			g.moves_left -= 1;
			g.combo = 0;
			resolve(g, longest);
			thief_on_move(g);
		} else {
			start_swap(g, g.swap_a, g.swap_b, true);
		};
	case state::POP =>
		g.t += dt / POP_TIME;
		if (g.t < 1.0) return;
		collapse(&g.b);
		g.st = state::FALL;
	case state::FALL =>
		if (!settle(&g.b, dt)) return;
		g.from_swap = false;
		const (count, longest) = find_matches(&g.b);
		if (count > 0) {
			resolve(g, longest);
			return;
		};
		g.combo = 0;
		g.st = state::IDLE;
		g.idle = 0.0;
		// Let the thief finish walking off before the level ends.
		if (g.thief.phase != tphase::ENTER && check_level_end(g)) return;
		if (find_move(&g.b) is void) {
			announce(g, "Ingen træk - blander!", 0xffffffff);
			play_sfx(g, sfx::WHOOSH, 0.8, 0.6);
			fill(&g.b);
			g.st = state::FALL;
		};
	};
};

fn draw_board(win: *viper::window, g: *game, sp: *sprites) void = {
	// Honeycomb frame behind the board.
	for (let c = 0; c < COLS; c += 1) for (let r = 0; r < ROWS; r += 1) {
		const (x, y) = center(c, r);
		viper::hexagon(win, x, y + 3.0, R + 2.5, 0xff6b3d0c);
	};
	let hint: ((int, int, int, int) | void) = void;
	if (g.st == state::IDLE && g.idle > HINT_AFTER) hint = find_move(&g.b);
	const pulse = 0.5 + 0.5 * math::sinf64(g.clock * 6.0);

	for (let c = 0; c < COLS; c += 1) for (let r = 0; r < ROWS; r += 1) {
		const (x, y) = center(c, r);
		let rim: viper::color = 0xffb87a1e;
		if (g.sel.0 == c && g.sel.1 == r) {
			rim = 0xfffff4d0;
		} else match (hint) {
		case let h: (int, int, int, int) =>
			if ((h.0 == c && h.1 == r) || (h.2 == c && h.3 == r)) {
				rim = viper::mix(0xffb87a1e, 0xfffff4d0, pulse);
			};
		case void => void;
		};
		viper::hexagon(win, x, y, R, rim);
		viper::hexagon(win, x, y, R - 3.0, 0xffe9a93a);
		viper::hexagon(win, x - 1.5, y - 1.5, R - 7.0, 0xfff2bd55);
	};

	// Pieces, clipped to the board so new ones appear from "inside".
	viper::clip(win, 0, (BY - 2.0): int, W, H);
	for (let c = 0; c < COLS; c += 1) for (let r = 0; r < ROWS; r += 1) {
		const p = &g.b.c[c][r];
		if (p.kind == EMPTY) continue;
		const (x, y) = center(c, r);
		let s = 1.0;
		if (g.st == state::POP && p.marked) {
			// Swell a little, then shrink away.
			s = if (g.t < 0.3) 1.0 + g.t else (1.0 - g.t) * 1.85;
		};
		if (g.sel.0 == c && g.sel.1 == r && g.st == state::IDLE) {
			s = 1.0 + 0.06 * math::sinf64(g.clock * 10.0);
			if (s < 1.0) s = 1.0;
		};
		draw_piece(win, sp, p.kind, x + p.sx, y + p.sy + p.oy, s);
		draw_special(win, p.special, x + p.sx, y + p.sy + p.oy, s, g.clock);
	};
	viper::noclip(win);
};

fn draw_effects(win: *viper::window, g: *game, dt: f64) void = {
	// Stripe beams: a bright line along the cleared row that fades out.
	for (let i = 0z; i < len(g.beams); i += 1) {
		let b = &g.beams[i];
		if (b.life <= 0.0) continue;
		b.life -= dt;
		const a = b.life / 0.35;
		const w = (a * 7.0): int;
		for (let k = -w; k <= w; k += 1) {
			// Offset perpendicular-ish by shifting both ends the same way.
			const dx = b.x1 - b.x0, dy = b.y1 - b.y0;
			const l = math::sqrtf64(dx * dx + dy * dy) + 0.001;
			const nx = -dy / l * k: f64, ny = dx / l * k: f64;
			const col = viper::mix(0xffffb320, 0xffffffff, 1.0 - math::absf64(k: f64) / (w: f64 + 1.0));
			viper::line(win, (b.x0 + nx): int, (b.y0 + ny): int,
				(b.x1 + nx): int, (b.y1 + ny): int, col);
		};
	};
	// Bomb rings: an expanding hexagon outline.
	for (let i = 0z; i < len(g.rings); i += 1) {
		let rg = &g.rings[i];
		if (rg.life <= 0.0) continue;
		rg.life -= dt;
		const t = 1.0 - rg.life / 0.4;
		const rad = R * (0.8 + t * 2.2);
		for (let k = 0; k < 36; k += 1) {
			const a = k: f64 * math::PI / 18.0;
			viper::circle(win, (rg.x + math::cosf64(a) * rad): int,
				(rg.y + math::sinf64(a) * rad): int, (4.0 * (1.0 - t)): int + 1,
				viper::mix(0xfffff4b0, 0xffff6a1a, t));
		};
	};
	for (let i = 0z; i < len(g.parts); i += 1) {
		let p = &g.parts[i];
		if (p.life <= 0.0) continue;
		p.life -= dt;
		p.vy += 500.0 * dt;
		p.x += p.vx * dt;
		p.y += p.vy * dt;
		const s = if (p.life > 0.3) 4 else 3;
		viper::rect(win, p.x: int, p.y: int, s, s, p.col);
	};
	for (let i = 0z; i < len(g.floats); i += 1) {
		let f = &g.floats[i];
		if (f.life <= 0.0) continue;
		f.life -= dt;
		f.y -= 40.0 * dt;
		const text = strings::fromutf8_unsafe(f.text[..f.n]);
		const w = viper::text_width(text, f.scale);
		const x = f.x: int - w / 2, y = f.y: int;
		viper::text_scaled(win, x + f.scale, y + f.scale, text, 0xff3a1e05, f.scale);
		viper::text_scaled(win, x, y, text, f.col, f.scale);
	};
};

fn draw_background(win: *viper::window, g: *game) void = {
	for (let y = 0; y < H; y += 1) {
		viper::rect(win, 0, y, W, 1,
			viper::mix(0xff4a2a08, 0xff8a5212, y: f64 / H: f64));
	};
	// Faint honeycomb wallpaper.
	const h = math::sqrtf64(3.0) * 22.0;
	for (let c = 0; c < 26; c += 1) for (let r = 0; r < 14; r += 1) {
		const x = c: f64 * 33.0 + 10.0;
		const y = r: f64 * h + (if (c & 1 == 1) h / 2.0 else 0.0);
		viper::hexagon(win, x, y, 20.0, viper::mix(0xff5a3410, 0xff9a6018, y / H: f64));
	};
};

fn draw_panel(win: *viper::window, g: *game) bool = {
	const px = 500, py = 24;
	viper::round_rect(win, px, py, 296, 612, 14, 0xff2e1906);
	viper::round_rect(win, px + 4, py + 4, 288, 604, 11, 0xff3d230a);

	// Title with a little bee bobbing beside it.
	viper::text_scaled(win, px + 22, py + 22, "BINES", 0xff1a0d02, 5);
	viper::text_scaled(win, px + 18, py + 18, "BINES", 0xffffc23a, 5);
	const bob = math::sinf64(g.clock * 3.0) * 4.0;
	draw_bee(win, (px + 248): f64, (py + 56): f64 + bob, R * 0.62);
	viper::text(win, px + 20, py + 104, "Match the Honey. Save the Hive!", 0xfff2d8a8);

	let buf: [48]u8 = [0...];
	viper::text(win, px + 20, py + 150, "POINT", 0xffc79a5a);
	viper::text_scaled(win, px + 20, py + 168, fmt::bsprintf(buf, "{}", g.score)!,
		0xfffff4d0, 3);
	viper::text(win, px + 20, py + 226, fmt::bsprintf(buf, "Rekord: {}", g.best)!,
		0xffc79a5a);

	viper::text(win, px + 20, py + 256, fmt::bsprintf(buf, "Niveau {}", g.level)!,
		0xfffff4d0);
	viper::text(win, px + 20, py + 274, world_name(g.level), 0xffc79a5a);
	// Moves left, turning red when few remain.
	viper::text(win, px + 170, py + 256, "TRÆK", 0xffc79a5a);
	viper::text_scaled(win, px + 170, py + 272, fmt::bsprintf(buf, "{}", g.moves_left)!,
		if (g.moves_left <= 5) 0xffff6a5a else 0xfffff4d0, 3);

	// Honey meter = the level goal; with the thief around, his mark shows
	// how full it must be to chase him off.
	viper::text(win, px + 20, py + 344, fmt::bsprintf(buf, "Honning: {} / {}",
		g.meter: int, g.goal: int)!, 0xffc79a5a);
	const jx = px + 20, jy = py + 364;
	viper::round_rect(win, jx, jy, 26, 28, 6, 0xffe0951e);
	viper::rect(win, jx - 2, jy - 4, 30, 7, 0xff8a5212);
	viper::rect(win, jx + 5, jy + 9, 4, 12, 0xffffd88a);
	viper::round_rect(win, jx + 34, jy + 4, 222, 22, 11, 0xff1e1004);
	const mw = (g.meter / g.goal * 218.0): int;
	if (mw > 0) viper::round_rect(win, jx + 36, jy + 6, mw, 18, 9, 0xffffb320);
	const th = &g.thief;
	if (thief_active(th)) {
		const gx = jx + 36 + (th.goal / g.goal * 218.0): int;
		viper::rect(win, gx - 1, jy, 3, 30, 0xffff4a4a);
		const flash = (g.clock * 3.0): int % 2 == 0;
		viper::text(win, px + 20, py + 404, "HONNINGTYVEN ER HER!",
			if (flash) 0xffff5a5a else 0xffff9a6a);
		viper::text(win, px + 20, py + 422,
			fmt::bsprintf(buf, "Fyld til mærket! {} træk", th.moves_left)!, 0xfffff4d0);
	} else {
		const left = th.next - g.moves;
		if (th.phase == tphase::OFF && left > 0 && left <= 4) {
			viper::text(win, px + 20, py + 404, "Noget surrer i nærheden...", 0xffc79a5a);
		};
	};

	if (g.combo >= 2) {
		viper::text_scaled(win, px + 20, py + 298,
			fmt::bsprintf(buf, "Combo x{}", g.combo)!, 0xffff7a2a, 2);
	};


	const again = viper::button(win, " Menu ", px + 20, py + 560);
	viper::text(win, px + 150, py + 552, "D: demo", 0xffa07a48);
	viper::text(win, px + 150, py + 568, "M: lyd til/fra", 0xffa07a48);
	viper::text(win, px + 150, py + 584, "Esc: menu", 0xffa07a48);
	if (g.autoplay) {
		viper::text(win, px + 20, py + 542, "DEMO - spiller selv", 0xff7ee07e);
	};
	return again;
};

export fn main() void = {
	const win = match (viper::open("Bines", W, H)) {
	case let w: *viper::window => yield w;
	case let e: viper::error => fmt::fatal("viper:", viper::strerror(e));
	case nomem => fmt::fatal("viper: out of memory");
	};
	defer viper::close(win);

	win.theme = honey_theme;
	// Queen Evalin as the window icon (X11; on Wayland it comes from the
	// .desktop file installed by `make desktop`).
	match (viper::load_png("assets/bines/bines-icon-64.png")) {
	case let icon: viper::image =>
		viper::set_icon(win, &icon);
		viper::image_free(&icon);
	case viper::imgerror => void;
	};
	let g = game { ... };
	g.b.rng = random::init(viper::ticks(): u64 + 99);
	g.sel = NONE;
	g.drag = NONE;
	g.saved_best = load_best();
	g.best = g.saved_best;
	g.scr = screen::MENU;
	let sp = load_sprites();
	const snd = viper::audio_open();
	defer viper::audio_close(snd);
	let sounds = make_bank();
	g.snd = snd;
	g.bank = &sounds;
	let tsp = load_thief_sprites();
	let qsp = load_strip("queen_talk", QUEEN_CELL, false);
	let bst = load_boosters();
	g.bt = -1.0;
	load_shop(&g);
	load_hs(&g);
	let hsa = load_hsart();

	for (viper::frame(win)) {
		const dt = viper::delta(win);
		// M mutes, except while typing a name.
		if (g.scr != screen::CUP && viper::key_pressed(win, viper::key::M)) {
			viper::set_muted(snd, !viper::is_muted(snd));
		};
		if (g.scr == screen::CUP || g.scr == screen::HIGHSCORE) {
			g.clock += dt;
			if (g.scr == screen::CUP) draw_ceremony(win, &g, &hsa)
			else draw_highscore(win, &g, &hsa);
			viper::audio_pump(snd);
			viper::present(win);
			continue;
		};
		if (g.scr == screen::SHOP) {
			g.clock += dt;
			draw_shop(win, &g, &bst);
			viper::audio_pump(snd);
			viper::present(win);
			continue;
		};
		if (g.scr == screen::MENU || g.scr == screen::HOWTO) {
			g.clock += dt;
			if (viper::key_pressed(win, viper::key::ESCAPE)) {
				if (g.scr == screen::MENU) break;
				g.scr = screen::MENU;
			};
			if (g.scr == screen::MENU && viper::key_pressed(win, viper::key::D)) {
				new_game(&g);
				g.autoplay = true;
			};
			const quit = if (g.scr == screen::MENU) draw_menu(win, &g, &tsp)
				else { draw_howto(win, &g); yield false; };
			viper::audio_pump(snd);
			viper::present(win);
			if (quit) break;
			continue;
		};
		if (viper::key_pressed(win, viper::key::ESCAPE)) {
			g.scr = screen::MENU;
			g.autoplay = false;
			continue;
		};
		if (viper::key_pressed(win, viper::key::D)) g.autoplay = !g.autoplay;
		if (g.scr == screen::PLAY) {
			update(win, &g);
		} else {
			g.clock += dt;
		};
		thief_update(&g, dt);
		queen_update(win, &g, dt);
		booster_update(&g, &bst, dt);

		draw_background(win, &g);
		draw_board(win, &g, &sp);
		draw_shelf(win);
		// The thief lives on the shelf: hide him behind the panel's edge.
		viper::clip(win, 0, 0, 494, H);
		draw_thief(win, &g, &tsp);
		draw_queen(win, &g, &qsp);
		viper::noclip(win);
		draw_booster_magic(win, &g, &bst);
		if (draw_panel(win, &g)) {
			g.scr = screen::MENU;
			g.autoplay = false;
		};
		draw_booster_slots(win, &g, &bst);
		draw_effects(win, &g, dt);
		draw_banner(win, &g, dt);
		if (g.scr == screen::LEVEL_DONE) draw_level_done(win, &g);
		if (g.scr == screen::GAME_OVER) draw_game_over(win, &g);
		// In demo mode, keep going by itself.
		const shown = g.clock - g.overlay_t > 2.5;
		if (g.autoplay && shown && g.scr == screen::LEVEL_DONE) {
			g.level += 1;
			start_level(&g);
		} else if (!g.autoplay && g.rank > 0 && g.scr == screen::GAME_OVER
				&& g.clock - g.overlay_t > 3.0) {
			// Made the highscore board: on to the ceremony.
			start_ceremony(&g);
		} else if (g.autoplay && shown && g.scr == screen::GAME_OVER) {
			new_game(&g);
			g.autoplay = true;
		};
		viper::audio_pump(snd);
		viper::present(win);
	};
};

