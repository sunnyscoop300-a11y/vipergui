// GOTHECER: Monsters of Yote Wood — a 2D turn-based RPG battle demo.
// The goth gnome band (Welteum, Slusara and Facia) against MORGHUL,
// the Ancient Hair Slime. Made with Hare + ViperGui.
//
// Mouse or arrow keys + Enter. R plays again. Esc quits.
use fmt;
use math;
use math::random;
use strings;
use viper;

def W: int = 1100;
def H: int = 700;
def GROUND: int = 455;        // where the feet stand
def NFRAMES: size = 6;
def ELIXIRS: int = 3;

// Actions in the menu.
def A_ATTACK: int = 0;
def A_SKILL: int = 1;
def A_MAGIC: int = 2;
def A_ITEM: int = 3;
def A_GUARD: int = 4;
def A_FLEE: int = 5;

// Who talks in the message box.
def WHO_MORGHUL: int = 3;
def WHO_NONE: int = 4;

def INK: viper::color = 0xff120a1c;
def PANEL: viper::color = 0xff1c1030;
def EDGE: viper::color = 0xff6a3aa8;
def PURPLE: viper::color = 0xff9a4ae0;
def LILAC: viper::color = 0xffd6b4ff;
def GOLD: viper::color = 0xffffd060;
def TEXT: viper::color = 0xfff4ecff;
def DIM: viper::color = 0xff9a88b8;
def RED: viper::color = 0xffe03040;
def GREEN: viper::color = 0xff50e070;
def BLUE: viper::color = 0xff40a8ff;
def SLIME: viper::color = 0xffb0f020;

const MENU: [6]str = ["Angrib", "Evner", "Magi", "Genstande", "Forsvar", "Flygt"];

type hero = struct {
	name: str,
	file: str,
	skill: str,
	skill_text: str,
	skill_mp: int,
	x: int,                // where the hero stands (middle)
	hp: int, maxhp: int,
	mp: int, maxmp: int,
	atk: int, mag: int,
	guard: bool,
	stuck: bool,
	hurt_t: f64,
	frames: [6]viper::image,
	portrait: viper::image,
};

type pop = struct {
	x: f64, y: f64,
	t: f64,
	text: [24]u8,
	n: size,
	col: viper::color,
};

type spark = struct {
	x: f64, y: f64, vx: f64, vy: f64,
	t: f64, life: f64,
	r: int,
	col: viper::color,
	note: bool,            // a music note instead of a dot
};

type state = enum { TITLE, CHOOSE, ACT, ENEMY, WIN, LOSE };

type game = struct {
	st: state,
	t: f64,
	rng: random::random,
    bg: [6]viper::image,
	map: [6]viper::image,
	heroes: [3]hero,
	cur: size,             // whose turn it is
	sel: int,              // menu choice
	act: int,              // the chosen action
	act_t: f64,
	applied: bool,
	// Morghul
	m_hp: int, m_maxhp: int,
	m_frames: [6]viper::image,
	m_portrait: viper::image,
	m_big: viper::image,
	m_hurt_t: f64,
	m_turn: int,
	m_charging: bool,
	m_move: int,           // the attack it is doing
	m_hits_left: int,      // 2 when it is enraged
	shake: f64,
	hymn: int,             // rounds left of Slusara's hymn
	elixirs: int,
	round: int,
	// The message box
	who: int,
	msg: str,
	msgbuf: [256]u8,
	pops: [24]pop,
	sparks: [96]spark,
	sfx: int,
	// Pictures
	logo: viper::image,
	logo_big: viper::image,
};

// --- pictures ---

fn picture(path: str) viper::image = match (viper::load_png(path)) {
case let im: viper::image => yield im;
case viper::imgerror => fmt::fatal("Mangler billedet", path, "- kør fra vipergui-mappen");
};

fn load_hero(h: *hero) void = {
	let b: [96]u8 = [0...];
	for (let k = 0z; k < NFRAMES; k += 1) {
		h.frames[k] = picture(fmt::bsprintf(b, "assets/gothecer/{}-{}.png", h.file, k)!);
	};
	h.portrait = picture(fmt::bsprintf(b, "assets/gothecer/p-{}.png", h.file)!);
};

fn free_hero(h: *hero) void = {
	for (let k = 0z; k < NFRAMES; k += 1) viper::image_free(&h.frames[k]);
	viper::image_free(&h.portrait);
};

// --- small helpers ---

fn rnd(g: *game, lo: int, hi: int) int = lo + random::u32n(&g.rng, (hi - lo + 1): u32): int;

fn chance(g: *game, pct: int) bool = random::u32n(&g.rng, 100): int < pct;

fn say(g: *game, who: int, f: str, args: fmt::field...) void = {
	g.who = who;
	g.msg = fmt::bsprintf(g.msgbuf, f, args...)!;
};

fn alive(h: *hero) bool = h.hp > 0;

fn clicked(win: *viper::window) bool =
	(viper::mouse_clicks(win) & viper::LEFT_BUTTON) != 0;

fn all_dead(g: *game) bool = {
	for (let i = 0z; i < 3; i += 1) {
		if (alive(&g.heroes[i])) return false;
	};
	return true;
};

// The ally that needs help the most (lowest HP in %, KO counts as 0).
fn weakest(g: *game, with_ko: bool) size = {
	let best = 0z, bp = 2.0;
	for (let i = 0z; i < 3; i += 1) {
		const h = &g.heroes[i];
		if (!with_ko && !alive(h)) continue;
		const p = h.hp: f64 / h.maxhp: f64;
		if (p < bp) {
			bp = p;
			best = i;
		};
	};
	return best;
};

fn pop_text(g: *game, x: f64, y: f64, s: str, col: viper::color) void = {
	for (let i = 0z; i < len(g.pops); i += 1) {
		let p = &g.pops[i];
		if (p.t > 0.0) continue;
		const b = strings::toutf8(s);
		const n = if (len(b) > len(p.text)) len(p.text) else len(b);
		p.text[..n] = b[..n];
		p.n = n;
		p.x = x;
		p.y = y;
		p.t = 1.2;
		p.col = col;
		return;
	};
};

fn pop_num(g: *game, x: f64, y: f64, n: int, col: viper::color, crit: bool) void = {
	let b: [24]u8 = [0...];
	pop_text(g, x, y, fmt::bsprintf(b, if (crit) "{}!" else "{}", n)!, col);
};

fn burst(g: *game, x: f64, y: f64, n: int, col: viper::color, speed: f64, notes: bool) void = {
	let made = 0;
	for (let i = 0z; i < len(g.sparks) && made < n; i += 1) {
		let s = &g.sparks[i];
		if (s.t > 0.0) continue;
		const a = random::u32n(&g.rng, 628): f64 / 100.0;
		const v = speed * (0.4 + random::u32n(&g.rng, 60): f64 / 100.0);
		s.x = x;
		s.y = y;
		s.vx = math::cosf64(a) * v;
		s.vy = math::sinf64(a) * v - speed * 0.3;
		s.life = 0.6 + random::u32n(&g.rng, 50): f64 / 100.0;
		s.t = s.life;
		s.r = 2 + rnd(g, 0, 3);
		s.col = col;
		s.note = notes;
		made += 1;
	};
};

// --- a new fight ---

fn new_fight(g: *game) void = {
	const names: [3]str = ["WELTEUM", "SLUSARA", "FACIA"];
	const hp: [3]int = [3420, 4880, 3260];
	const mp: [3]int = [312, 540, 620];
	const atk: [3]int = [520, 330, 240];
	const mag: [3]int = [120, 380, 560];
	for (let i = 0z; i < 3; i += 1) {
		let h = &g.heroes[i];
		h.name = names[i];
		h.hp = hp[i];
		h.maxhp = hp[i];
		h.mp = mp[i];
		h.maxmp = mp[i];
		h.atk = atk[i];
		h.mag = mag[i];
		h.guard = false;
		h.stuck = false;
		h.hurt_t = 0.0;
	};
	g.m_hp = 24800;
	g.m_maxhp = 24800;
	g.m_turn = 0;
	g.m_charging = false;
	g.hymn = 0;
	g.elixirs = ELIXIRS;
	g.round = 1;
	g.cur = 0;
	g.sel = 0;
	for (let i = 0z; i < len(g.pops); i += 1) g.pops[i].t = 0.0;
	for (let i = 0z; i < len(g.sparks); i += 1) g.sparks[i].t = 0.0;
	say(g, 1, "Så er det tid, GOTHECER! Lad os sende det urgamle hårslimmonster tilbage til mørket!");
	g.st = state::CHOOSE;
};

// --- whose turn ---

// Finds the next hero who can act, or lets Morghul have its turn.
fn next_turn(g: *game, from: size) void = {
	for (let i = from; i < 3; i += 1) {
		let h = &g.heroes[i];
		if (!alive(h)) continue;
		if (h.stuck) {
			h.stuck = false;
			say(g, WHO_NONE, "{} sidder fast i Morghuls slim og må stå over!", h.name);
			continue;
		};
		h.guard = false;
		g.cur = i;
		g.sel = 0;
		g.st = state::CHOOSE;
		return;
	};
	start_enemy(g);
};

fn start_enemy(g: *game) void = {
	g.m_hits_left = if (g.m_hp * 2 <= g.m_maxhp) 2 else 1;
	pick_move(g);
};

// --- the heroes act ---

fn choose(g: *game, action: int) void = {
	const h = &g.heroes[g.cur];
	switch (action) {
	case A_FLEE =>
		say(g, g.cur: int, "Man flygter ikke fra Morghul! Hele Yote Wood regner med os!");
		g.sfx = 9;
		return;
	case A_SKILL =>
		if (h.mp < h.skill_mp) {
			say(g, g.cur: int, "Jeg har ikke nok MP til {} ({} MP)...", h.skill, h.skill_mp);
			g.sfx = 9;
			return;
		};
	case A_MAGIC =>
		if (h.mp < 70) {
			say(g, g.cur: int, "Jeg har ikke nok MP til Måneheling (70 MP)...");
			g.sfx = 9;
			return;
		};
	case A_ITEM =>
		if (g.elixirs <= 0) {
			say(g, g.cur: int, "Vi har ikke flere svampe-eliksirer!");
			g.sfx = 9;
			return;
		};
	case => void;
	};
	g.act = action;
	g.act_t = 0.0;
	g.applied = false;
	g.st = state::ACT;
};

fn damage_morghul(g: *game, base: f64, what: str) void = {
	let d = base * (0.9 + random::u32n(&g.rng, 21): f64 / 100.0);
	if (g.hymn > 0) d *= 1.4;
	const crit = chance(g, 12);
	if (crit) d *= 1.75;
	let n = d: int;
	if (n > g.m_hp) n = g.m_hp;
	g.m_hp -= n;
	g.m_hurt_t = 0.4;
	pop_num(g, 880.0, 230.0, n, if (crit) GOLD else TEXT, crit);
	burst(g, 860.0, 320.0, 18, LILAC, 220.0, false);
	if (crit) {
		say(g, g.cur: int, "{}! KRITISK TRÆF for {} skade!", what, n);
	} else {
		say(g, g.cur: int, "{} rammer Morghul for {} skade!", what, n);
	};
	g.sfx = if (g.cur == 0) 1 else if (g.cur == 1) 2 else 3;
};

fn apply_action(g: *game) void = {
	let h = &g.heroes[g.cur];
	switch (g.act) {
	case A_ATTACK =>
		damage_morghul(g, h.atk: f64, "Angreb");
	case A_SKILL =>
		h.mp -= h.skill_mp;
		switch (g.cur) {
		case 0 =>
			damage_morghul(g, h.atk: f64 * 2.3, "POWER CHORD");
			burst(g, 330.0, 330.0, 12, LILAC, 160.0, true);
		case 1 =>
			g.hymn = 3;
			for (let i = 0z; i < 3; i += 1) {
				if (alive(&g.heroes[i])) {
					burst(g, g.heroes[i].x: f64, 300.0, 8, LILAC, 120.0, true);
				};
			};
			say(g, 1, "Gotisk Hymne! Hele bandet slår 40% hårdere i 3 runder!");
			g.sfx = 2;
		case =>
			damage_morghul(g, h.mag: f64 * 2.2, "ROSENSTORM");
			burst(g, 880.0, 300.0, 24, RED, 260.0, false);
		};
	case A_MAGIC =>
		h.mp -= 70;
		const t = weakest(g, false);
		let o = &g.heroes[t];
		const heal = h.mag * 22 / 10 + 300;
		const got = if (o.hp + heal > o.maxhp) o.maxhp - o.hp else heal;
		o.hp += got;
		pop_num(g, o.x: f64, 250.0, got, GREEN, false);
		burst(g, o.x: f64, 360.0, 16, GREEN, 140.0, false);
		say(g, g.cur: int, "Måneheling! {} får {} HP tilbage.", o.name, got);
		g.sfx = 4;
	case A_ITEM =>
		g.elixirs -= 1;
		const w = weakest(g, true);
		let o = &g.heroes[w];
		const was_ko = !alive(o);
		o.hp += 1500;
		if (o.hp > o.maxhp) o.hp = o.maxhp;
		o.mp += 80;
		if (o.mp > o.maxmp) o.mp = o.maxmp;
		pop_num(g, o.x: f64, 250.0, 1500, GREEN, false);
		burst(g, o.x: f64, 360.0, 16, PURPLE, 140.0, false);
		if (was_ko) {
			say(g, g.cur: int, "Svampe-eliksir! {} er tilbage i kampen! ({} eliksirer tilbage)", o.name, g.elixirs);
		} else {
			say(g, g.cur: int, "Svampe-eliksir til {}: +1500 HP og +80 MP. ({} tilbage)", o.name, g.elixirs);
		};
		g.sfx = 4;
	case =>
		h.guard = true;
		h.mp += 40;
		if (h.mp > h.maxmp) h.mp = h.maxmp;
		say(g, g.cur: int, "{} går i forsvar og samler 40 MP.", h.name);
		g.sfx = 10;
	};
};

// --- Morghul acts ---

def M_WHIP: int = 0;
def M_RAIN: int = 1;
def M_GLUE: int = 2;
def M_CHARGE: int = 3;
def M_ROAR: int = 4;

fn pick_move(g: *game) void = {
	g.m_turn += 1;
	if (g.m_charging) {
		g.m_move = M_ROAR;
		g.m_charging = false;
	} else if (g.m_turn % 4 == 0) {
		g.m_move = M_CHARGE;
	} else {
		const r = rnd(g, 0, 99);
		g.m_move = if (r < 50) M_WHIP else if (r < 85) M_RAIN else M_GLUE;
	};
	g.act_t = 0.0;
	g.applied = false;
	g.st = state::ENEMY;
};

fn hurt_hero(g: *game, i: size, lo: int, hi: int) int = {
	let h = &g.heroes[i];
	if (!alive(h)) return 0;
	let d = rnd(g, lo, hi);
	if (h.guard) d /= 2;
	if (d > h.hp) d = h.hp;
	h.hp -= d;
	h.hurt_t = 0.4;
	pop_num(g, h.x: f64, 250.0, d, RED, false);
	burst(g, h.x: f64, 360.0, 10, SLIME, 160.0, false);
	return d;
};

fn random_target(g: *game) size = {
	for (let k = 0; k < 50; k += 1) {
		const i = random::u32n(&g.rng, 3): size;
		if (alive(&g.heroes[i])) return i;
	};
	for (let i = 0z; i < 3; i += 1) {
		if (alive(&g.heroes[i])) return i;
	};
	return 0;
};

fn apply_enemy(g: *game) void = {
	switch (g.m_move) {
	case M_CHARGE =>
		say(g, WHO_MORGHUL, "Morghul samler alt sit hår... Næste tur kommer URBRØLET!");
		g.sfx = 6;
	case M_ROAR =>
		let total = 0;
		for (let i = 0z; i < 3; i += 1) total += hurt_hero(g, i, 520, 680);
		say(g, WHO_MORGHUL, "UUUURRRBRØØØL! Hele bandet tager skade ({} i alt)!", total);
		g.shake = 0.6;
		g.sfx = 7;
	case M_RAIN =>
		for (let i = 0z; i < 3; i += 1) hurt_hero(g, i, 260, 380);
		say(g, WHO_MORGHUL, "Slimregn! Grøn slim drypper ned over hele bandet!");
		g.shake = 0.25;
		g.sfx = 6;
	case M_GLUE =>
		const t = random_target(g);
		const d = hurt_hero(g, t, 260, 340);
		g.heroes[t].stuck = true;
		say(g, WHO_MORGHUL, "Klister-slim! {} tager {} skade og sidder fast!", g.heroes[t].name, d);
		g.sfx = 6;
	case =>
		const v = random_target(g);
		const dmg = hurt_hero(g, v, 600, 820);
		say(g, WHO_MORGHUL, "Hårpisk! Morghul slår {} for {} skade!", g.heroes[v].name, dmg);
		g.shake = 0.3;
		g.sfx = 5;
	};
};

fn end_round(g: *game) void = {
	if (g.hymn > 0) g.hymn -= 1;
	g.round += 1;
	next_turn(g, 0);
};

// --- update ---

fn update(win: *viper::window, g: *game, dt: f64) bool = {
	g.t += dt;
	if (g.shake > 0.0) g.shake -= dt;
	if (g.m_hurt_t > 0.0) g.m_hurt_t -= dt;
	for (let i = 0z; i < 3; i += 1) {
		if (g.heroes[i].hurt_t > 0.0) g.heroes[i].hurt_t -= dt;
	};
	for (let i = 0z; i < len(g.pops); i += 1) {
		let p = &g.pops[i];
		if (p.t <= 0.0) continue;
		p.t -= dt;
		p.y -= 40.0 * dt;
	};
	for (let i = 0z; i < len(g.sparks); i += 1) {
		let s = &g.sparks[i];
		if (s.t <= 0.0) continue;
		s.t -= dt;
		s.x += s.vx * dt;
		s.y += s.vy * dt;
		s.vy += 260.0 * dt;
	};

	const go = viper::key_pressed(win, viper::key::RETURN)
		|| viper::key_pressed(win, viper::key::SPACE);
	switch (g.st) {
	case state::TITLE =>
		if (go || clicked(win)) {
			new_fight(g);
			g.sfx = 1;
		};
	case state::CHOOSE =>
		if (viper::key_pressed(win, viper::key::UP)) {
			g.sel = (g.sel + 5) % 6;
			g.sfx = 9;
		};
		if (viper::key_pressed(win, viper::key::DOWN)) {
			g.sel = (g.sel + 1) % 6;
			g.sfx = 9;
		};
		for (let i = 0; i < 6; i += 1) {
			const y = 160 + i * 48;
			const over = win.mouse_x >= 18 && win.mouse_x < 196
				&& win.mouse_y >= y && win.mouse_y < y + 42;
			if (over && g.sel != i) g.sel = i;
			if (over && clicked(win)) choose(g, i);
		};
		if (go && g.st == state::CHOOSE) choose(g, g.sel);
	case state::ACT =>
		g.act_t += dt;
		if (!g.applied && g.act_t >= 0.45) {
			g.applied = true;
			apply_action(g);
		};
		if (g.act_t >= 0.95) {
			if (g.m_hp <= 0) {
				g.st = state::WIN;
				say(g, 1, "Vi klarede det! Morghul smelter væk, og Yote Wood er reddet!");
				g.sfx = 8;
			} else {
				next_turn(g, g.cur + 1);
			};
		};
	case state::ENEMY =>
		g.act_t += dt;
		if (!g.applied && g.act_t >= 0.55) {
			g.applied = true;
			apply_enemy(g);
		};
		if (g.act_t >= 1.3) {
			if (all_dead(g)) {
				g.st = state::LOSE;
				say(g, WHO_MORGHUL, "Morghul slugte hele bandet... Tryk R for at prøve igen.");
				g.sfx = 11;
			} else {
				g.m_hits_left -= 1;
				if (g.m_hits_left > 0 && g.m_move != M_CHARGE) {
					say(g, WHO_MORGHUL, "Morghul er RASENDE og angriber igen!");
					pick_move(g);
				} else {
					end_round(g);
				};
			};
		};
	case state::WIN, state::LOSE =>
		if (viper::key_pressed(win, viper::key::R)) {
			new_fight(g);
		};
	};
	return !viper::key_pressed(win, viper::key::ESCAPE);
};

// --- drawing ---

fn panel(win: *viper::window, x: int, y: int, w: int, h: int, edge: viper::color) void = {
	viper::round_rect(win, x, y, w, h, 10, edge);
	viper::round_rect(win, x + 2, y + 2, w - 4, h - 4, 8, PANEL);
};

fn bar(win: *viper::window, x: int, y: int, w: int, v: int, max: int, col: viper::color) void = {
	viper::round_rect(win, x, y, w, 8, 4, 0xff2a1a3a);
	if (v > 0) viper::round_rect(win, x, y, w * v / max, 8, 4, col);
};

// Text with a dark edge so it shows on any background.
fn outlined(win: *viper::window, x: int, y: int, s: str, col: viper::color, sc: int) void = {
	viper::text_scaled(win, x + 2, y + 2, s, 0xff000000, sc);
	viper::text_scaled(win, x, y, s, col, sc);
};

// Draws text, breaking it into lines of at most n bytes at spaces.
fn wrapped(win: *viper::window, x: int, y: int, s: str, n: size, maxl: int, col: viper::color) void = {
	let b = strings::toutf8(s);
	let line = 0;
	for (len(b) > 0 && line < maxl) {
		let end = len(b);
		if (end > n) {
			end = n;
			for (end > 0 && b[end] != 32) end -= 1;
			if (end == 0) end = n;
		};
		viper::text(win, x, y + line * 20, strings::fromutf8_unsafe(b[..end]), col);
		b = b[end..];
		for (len(b) > 0 && b[0] == 32) b = b[1..];
		line += 1;
	};
};

fn draw_sprite(win: *viper::window, im: *viper::image, cx: int, feet: int) void = {
	viper::draw_image(win, im, cx - im.w / 2, feet - im.h);
};

// Which frame of the moving background and map to show.
fn anim(g: *game) size = ((g.t / 0.16): int % 6): size;
 
fn shake_x(g: *game) int = if (g.shake > 0.0) rnd(g, -6, 6) else 0;

fn draw_scene(win: *viper::window, g: *game) void = {
	const sx = shake_x(g);
	viper::draw_image(win, &g.bg[anim(g)], sx, 0);

	// Morghul: wobbles all the time, lunges when it attacks.
	let mx = 880 + sx;
	if (g.st == state::ENEMY) {
		mx -= (math::sinf64(math::PI * g.act_t / 1.3) * 120.0): int;
	};
	if (g.m_hurt_t > 0.0) mx += rnd(g, -8, 8);
	if (g.m_hp > 0 || g.st != state::WIN) {
		const mf = ((g.t / 0.18): int % NFRAMES: int): size;
		draw_sprite(win, &g.m_frames[mf], mx, GROUND + 8);
	};

	// The band.
	for (let i = 0z; i < 3; i += 1) {
		const h = &g.heroes[i];
		let x = h.x + sx;
		let feet = GROUND + (math::sinf64(g.t * 2.0 + i: f64) * 2.0): int;
		let f = 0z;
		if (g.st == state::ACT && g.cur == i) {
			f = ((g.act_t / 0.95 * 6.0): int % 6): size;
			if (g.act == A_ATTACK || (g.act == A_SKILL && i != 1)) {
				x += (math::sinf64(math::PI * g.act_t / 0.95) * 90.0): int;
			};
		};
		if (h.hurt_t > 0.0) x += rnd(g, -6, 6);
		if (!alive(h)) {
			// A little gravestone with a rose.
			viper::round_rect(win, x - 22, feet - 54, 44, 54, 14, 0xff4a4058);
			viper::rect(win, x - 22, feet - 30, 44, 30, 0xff4a4058);
			viper::text(win, x - 8, feet - 40, "KO", DIM);
			viper::circle(win, x, feet - 6, 5, RED);
			continue;
		};
		draw_sprite(win, &h.frames[f], x, feet);
		if (h.guard) {
			viper::round_rect(win, x - 14, feet - h.frames[0].h - 26, 28, 20, 6, BLUE);
			viper::text(win, x - 8, feet - h.frames[0].h - 24, "DF", TEXT);
		};
		if (h.stuck) {
			viper::round_rect(win, x - 40, feet - 22, 80, 20, 8, SLIME);
		};
		// The arrow over the one whose turn it is.
		if (g.st == state::CHOOSE && g.cur == i) {
			const ay = feet - h.frames[0].h - 22 + (math::sinf64(g.t * 6.0) * 4.0): int;
			const tri: [3](f64, f64) = [
				((x - 10): f64, ay: f64), ((x + 10): f64, ay: f64), (x: f64, (ay + 12): f64),
			];
			viper::polygon(win, tri, GOLD);
		};
	};

	// Sparks and music notes.
	for (let i = 0z; i < len(g.sparks); i += 1) {
		const s = &g.sparks[i];
		if (s.t <= 0.0) continue;
		const fade = s.t / s.life;
		const col = viper::mix(INK, s.col, fade);
		if (s.note) {
			viper::circle(win, s.x: int, s.y: int, 4, col);
			viper::rect(win, s.x: int + 3, s.y: int - 14, 2, 14, col);
			viper::rect(win, s.x: int + 3, s.y: int - 14, 7, 2, col);
		} else {
			viper::circle(win, s.x: int, s.y: int, s.r, col);
		};
	};

	// Damage numbers.
	for (let i = 0z; i < len(g.pops); i += 1) {
		const p = &g.pops[i];
		if (p.t <= 0.0) continue;
		const s = strings::fromutf8_unsafe(p.text[..p.n]);
		outlined(win, p.x: int - viper::text_width(s, 3) / 2, p.y: int, s, p.col, 3);
	};

	viper::draw_image(win, &g.logo, 10, 8);
};

fn draw_boss(win: *viper::window, g: *game) void = {
	panel(win, 700, 10, 390, 78, EDGE);
	viper::draw_image(win, &g.m_portrait, 1024, 16);
	viper::text_scaled(win, 714, 16, "BOSS", RED, 1);
	viper::text_scaled(win, 714, 32, "MORGHUL", TEXT, 2);
	viper::text(win, 714, 66, "The Ancient Hair Slime", DIM);
	let b: [32]u8 = [0...];
	const hp = fmt::bsprintf(b, "HP {} / {}", g.m_hp, g.m_maxhp)!;
	viper::text(win, 1012 - viper::text_width(hp, 1), 34, hp, TEXT);
	viper::round_rect(win, 880, 54, 134, 10, 5, 0xff2a1a3a);
	if (g.m_hp > 0) viper::round_rect(win, 880, 54, 134 * g.m_hp / g.m_maxhp, 10, 5, RED);
	if (g.m_hp * 2 <= g.m_maxhp && g.m_hp > 0) {
		viper::text(win, 770, 16, "RASENDE!", RED);
	};
	if (g.m_charging) viper::text(win, 850, 16, "samler kræfter!", GOLD);
};

fn draw_menu(win: *viper::window, g: *game) void = {
	panel(win, 12, 150, 192, 300, EDGE);
	const on = g.st == state::CHOOSE;
	for (let i = 0; i < 6; i += 1) {
		const y = 160 + i * 48;
		const sel = on && g.sel == i;
		const edge: viper::color = if (sel) GOLD else 0xff3a2458;
		const bg: viper::color = if (sel) 0xff5a2a90 else 0xff26163e;
		viper::round_rect(win, 18, y, 180, 42, 8, edge);
		viper::round_rect(win, 20, y + 2, 176, 38, 7, bg);
		const col: viper::color = if (!on) DIM else if (sel) TEXT else LILAC;
		viper::text_scaled(win, 40, y + 13, MENU[i: size], col, 1);
		if (i == A_ITEM) {
			let b: [8]u8 = [0...];
			viper::text(win, 168, y + 13, fmt::bsprintf(b, "x{}", g.elixirs)!, GOLD);
		};
	};
	if (g.hymn > 0) {
		let b: [32]u8 = [0...];
		outlined(win, 18, 458, fmt::bsprintf(b, "Hymne: {} runde(r)", g.hymn)!, LILAC, 1);
	};
};

fn draw_cards(win: *viper::window, g: *game) void = {
	let b: [32]u8 = [0...];
	for (let i = 0z; i < 3; i += 1) {
		const h = &g.heroes[i];
		const x = 212 + i: int * 296, y = 482;
		const now = (g.st == state::CHOOSE || g.st == state::ACT) && g.cur == i;
		const edge: viper::color = if (!alive(h)) 0xff5a3040 else if (now) GOLD else EDGE;
		panel(win, x, y, 284, 108, edge);
		viper::draw_image(win, &h.portrait, x + 8, y + 9);
		viper::text_scaled(win, x + 102, y + 10, h.name, if (alive(h)) TEXT else DIM, 2);
		viper::text(win, x + 230, y + 14, "Lv.24", LILAC);
		viper::text(win, x + 102, y + 40, "HP", GREEN);
		const hp = fmt::bsprintf(b, "{} / {}", h.hp, h.maxhp)!;
		viper::text(win, x + 274 - viper::text_width(hp, 1), y + 40, hp, TEXT);
		bar(win, x + 102, y + 58, 172, h.hp, h.maxhp, GREEN);
		viper::text(win, x + 102, y + 72, "MP", BLUE);
		const mp = fmt::bsprintf(b, "{} / {}", h.mp, h.maxmp)!;
		viper::text(win, x + 274 - viper::text_width(mp, 1), y + 72, mp, TEXT);
		bar(win, x + 102, y + 90, 172, h.mp, h.maxmp, BLUE);
		if (!alive(h)) viper::text_scaled(win, x + 30, y + 40, "KO", RED, 2);
	};
};

// What the chosen menu line does, for the message box.
fn hint(g: *game) str = {
	const h = &g.heroes[g.cur];
	return switch (g.sel) {
	case A_ATTACK => yield "Et almindeligt angreb mod Morghul.";
	case A_SKILL => yield h.skill_text;
	case A_MAGIC => yield "Måneheling (70 MP): heler den, der har mindst HP tilbage.";
	case A_ITEM => yield "Svampe-eliksir: +1500 HP og +80 MP - og kan vække en KO'et nisse.";
	case A_GUARD => yield "Halv skade til din næste tur, og +40 MP.";
	case => yield "Flygt fra kampen.";
	};
};

fn draw_message(win: *viper::window, g: *game) void = {
	panel(win, 212, 600, 876, 92, EDGE);
	let who = g.who;
	let name = "";
	const choosing = g.st == state::CHOOSE;
	if (choosing) who = g.cur: int;
	const px = 220, py = 603;
	switch (who) {
	case 0, 1, 2 =>
		const h = &g.heroes[who: size];
		viper::draw_image(win, &h.portrait, px, py);
		name = h.name;
	case WHO_MORGHUL =>
		viper::draw_image(win, &g.m_big, px, py);
		name = "MORGHUL";
	case => void;
	};
	const tx = if (who == WHO_NONE) 230 else 316;
	if (choosing) {
		// The last thing that happened, then what the menu line does.
		let b: [64]u8 = [0...];
		viper::text(win, tx, 610, fmt::bsprintf(b, "{}: hvad gør du?", name)!, GOLD);
		wrapped(win, tx, 632, g.msg, 92, 1, DIM);
		wrapped(win, tx, 656, hint(g), 92, 2, TEXT);
	} else {
		if (len(name) > 0) viper::text(win, tx, 610, name, GOLD);
		wrapped(win, tx, 634, g.msg, 92, 3, TEXT);
	};
};

fn draw_side(win: *viper::window, g: *game) void = {
	panel(win, 12, 482, 192, 172, EDGE);
	viper::draw_image(win, &g.map[anim(g)], 24, 485);
	let b: [32]u8 = [0...];
	viper::text(win, 24, 660, fmt::bsprintf(b, "Runde {}", g.round)!, DIM);
	viper::text(win, 24, 678, "Hare + ViperGui", PURPLE);
};

fn draw_end(win: *viper::window, g: *game) void = {
	const won = g.st == state::WIN;
	panel(win, 300, 170, 500, 170, if (won) GOLD else RED);
	if (won) {
		outlined(win, 550 - viper::text_width("SEJR!", 5) / 2, 190, "SEJR!", GOLD, 5);
		viper::text(win, 550 - viper::text_width("Yote Wood er reddet. GOTHECER spiller videre!", 1) / 2,
			270, "Yote Wood er reddet. GOTHECER spiller videre!", TEXT);
	} else {
		outlined(win, 550 - viper::text_width("GAME OVER", 4) / 2, 196, "GAME OVER", RED, 4);
		viper::text(win, 550 - viper::text_width("Morghul slugte hele bandet...", 1) / 2,
			270, "Morghul slugte hele bandet...", TEXT);
	};
	let b: [48]u8 = [0...];
	const s = fmt::bsprintf(b, "{} runder  -  tryk R for ny kamp", g.round)!;
	viper::text(win, 550 - viper::text_width(s, 1) / 2, 300, s, DIM);
};

fn draw_title(win: *viper::window, g: *game) void = {
	viper::draw_image(win, &g.bg[anim(g)], 0, 0);
	viper::rect(win, 0, 472, W, H - 472, INK);
	draw_sprite(win, &g.m_frames[((g.t / 0.18): int % 6): size], 880, GROUND + 8);
	for (let i = 0z; i < 3; i += 1) {
		const h = &g.heroes[i];
		draw_sprite(win, &h.frames[0], 260 + i: int * 160, GROUND);
	};
	viper::draw_image(win, &g.logo_big, (W - g.logo_big.w) / 2, 30);
	if ((g.t * 2.0): int % 2 == 0) {
		const s = "Tryk Enter for at kæmpe mod MORGHUL";
		outlined(win, (W - viper::text_width(s, 2)) / 2, 560, s, GOLD, 2);
	};
	const s2 = "Piletaster/mus + Enter vælger  -  Esc afslutter";
	viper::text(win, (W - viper::text_width(s2, 1)) / 2, 620, s2, DIM);
	viper::text(win, (W - viper::text_width("Hare + ViperGui", 1)) / 2, 660, "Hare + ViperGui", PURPLE);
};

fn draw(win: *viper::window, g: *game) void = {
	viper::clear(win, INK);
	if (g.st == state::TITLE) {
		draw_title(win, g);
		return;
	};
	draw_scene(win, g);
	draw_boss(win, g);
	draw_menu(win, g);
	draw_cards(win, g);
	draw_side(win, g);
	draw_message(win, g);
	if (g.st == state::WIN || g.st == state::LOSE) draw_end(win, g);
};

export fn main() void = {
	const win = match (viper::open("GOTHECER - Monsters of Yote Wood", W, H)) {
	case let w: *viper::window =>
		yield w;
	case let e: viper::error =>
		fmt::fatal("viper:", viper::strerror(e));
	case nomem =>
		fmt::fatal("viper: out of memory");
	};
	defer viper::close(win);

	let g = game { rng = random::init(viper::ticks(): u64 + 77), ... };
	g.logo = picture("assets/gothecer/logo.png");
	g.logo_big = picture("assets/gothecer/logo-big.png");
	g.m_portrait = picture("assets/gothecer/p-morghul.png");
	g.m_big = picture("assets/gothecer/p-morghul-big.png");
	let b: [64]u8 = [0...];
	for (let k = 0z; k < NFRAMES; k += 1) {
		g.bg[k] = picture(fmt::bsprintf(b, "assets/gothecer/bg-{}.png", k)!);
		g.map[k] = picture(fmt::bsprintf(b, "assets/gothecer/map-{}.png", k)!);
		g.m_frames[k] = picture(fmt::bsprintf(b, "assets/gothecer/morghul-{}.png", k)!);
	};
	const files: [3]str = ["welteum", "slusara", "facia"];
	const xs: [3]int = [330, 480, 625];
	const skills: [3]str = ["Power Chord", "Gotisk Hymne", "Rosenstorm"];
	const texts: [3]str = [
		"Power Chord (60 MP): et knusende guitarslag med 2,3 gange skade.",
		"Gotisk Hymne (80 MP): hele bandet slår 40% hårdere i 3 runder.",
		"Rosenstorm (90 MP): en storm af røde roser med stærk magi.",
	];
	const costs: [3]int = [60, 80, 90];
	for (let i = 0z; i < 3; i += 1) {
		let h = &g.heroes[i];
		h.file = files[i];
		h.x = xs[i];
		h.skill = skills[i];
		h.skill_text = texts[i];
		h.skill_mp = costs[i];
		load_hero(h);
	};
	new_fight(&g);
	g.st = state::TITLE;

	const snd = viper::audio_open();
	defer viper::audio_close(snd);
	const chord: [4]f64 = [196.0, 246.9, 293.7, 392.0];
	let s_guitar = viper::melody(viper::wave::SQUARE, chord, 0.05, 0.3);
	const sing: [5]f64 = [523.3, 659.3, 784.0, 659.3, 880.0];
	let s_sing = viper::melody(viper::wave::SINE, sing, 0.08, 0.3);
	const mag: [4]f64 = [880.0, 1174.7, 1568.0, 2093.0];
	let s_magic = viper::melody(viper::wave::TRIANGLE, mag, 0.05, 0.3);
	const up: [3]f64 = [523.3, 784.0, 1046.5];
	let s_heal = viper::melody(viper::wave::SINE, up, 0.07, 0.35);
	let s_whip = viper::tone(viper::wave::NOISE, 1400.0, 200.0, 0.18, 0.5, 0.002);
	let s_slime = viper::tone(viper::wave::SQUARE, 140.0, 45.0, 0.35, 0.35, 0.005);
	let s_roar = viper::tone(viper::wave::NOISE, 320.0, 70.0, 0.9, 0.6, 0.02);
	const fan: [6]f64 = [523.3, 659.3, 784.0, 1046.5, 784.0, 1046.5];
	let s_win = viper::melody(viper::wave::TRIANGLE, fan, 0.12, 0.4);
	let s_tick = viper::tone(viper::wave::TRIANGLE, 900.0, 900.0, 0.03, 0.2, 0.001);
	let s_guard = viper::tone(viper::wave::TRIANGLE, 300.0, 600.0, 0.15, 0.3, 0.005);
	const down: [4]f64 = [392.0, 349.2, 329.6, 261.6];
	let s_lose = viper::melody(viper::wave::SINE, down, 0.25, 0.4);
	defer viper::sound_free(&s_guitar);
	defer viper::sound_free(&s_sing);
	defer viper::sound_free(&s_magic);
	defer viper::sound_free(&s_heal);
	defer viper::sound_free(&s_whip);
	defer viper::sound_free(&s_slime);
	defer viper::sound_free(&s_roar);
	defer viper::sound_free(&s_win);
	defer viper::sound_free(&s_tick);
	defer viper::sound_free(&s_guard);
	defer viper::sound_free(&s_lose);

	for (viper::frame(win)) {
		let dt = viper::delta(win);
		if (dt > 0.05) dt = 0.05;
		if (!update(win, &g, dt)) break;
		draw(win, &g);
		switch (g.sfx) {
		case 1 => viper::play(snd, &s_guitar, 0.6, 1.0);
		case 2 => viper::play(snd, &s_sing, 0.6, 1.0);
		case 3 => viper::play(snd, &s_magic, 0.6, 1.0);
		case 4 => viper::play(snd, &s_heal, 0.6, 1.0);
		case 5 => viper::play(snd, &s_whip, 0.6, 1.0);
		case 6 => viper::play(snd, &s_slime, 0.6, 1.0);
		case 7 => viper::play(snd, &s_roar, 0.7, 1.0);
		case 8 => viper::play(snd, &s_win, 0.6, 1.0);
		case 9 => viper::play(snd, &s_tick, 0.4, 1.0);
		case 10 => viper::play(snd, &s_guard, 0.5, 1.0);
		case 11 => viper::play(snd, &s_lose, 0.6, 1.0);
		case => void;
		};
		g.sfx = 0;
		viper::audio_pump(snd);
		viper::present(win);
	};

	for (let i = 0z; i < 3; i += 1) free_hero(&g.heroes[i]);
	for (let k = 0z; k < NFRAMES; k += 1) {
		viper::image_free(&g.m_frames[k]);
		viper::image_free(&g.bg[k]);
		viper::image_free(&g.map[k]);
	};
	viper::image_free(&g.logo);
	viper::image_free(&g.logo_big);
	viper::image_free(&g.m_portrait);
	viper::image_free(&g.m_big);
};
