// BINES — the highscore board and THE HONEY DROP CUP.
//
// The five best games are kept in ~/.local/share/bines/highscore. A game
// that makes the list ends with a ceremony: Queen Evalin flies in and
// conjures up the cup (gold for 1st place, silver for 2nd, bronze for
// 3rd; 4th and 5th get her congratulations), and the player types a name.
use fmt;
use fs;
use io;
use math;
use os;
use strconv;
use strings;
use viper;

def NHS: size = 5;
def NAME_MAX: size = 10;      // characters in a name

type hsentry = struct {
	score: int,
	level: int,
	name: [40]u8,
	nlen: size,
};

type hsart = struct {
	bg: nullable *viper::image,
	evalin: [3]strip,      // gold, silver, bronze ceremony
	cup: [3]strip,         // small cups for the board
};

fn load_hsart() hsart = {
	let a = hsart { bg = null, ... };
	match (viper::load_png("assets/bines/highscore_bg.png")) {
	case let img: viper::image => a.bg = alloc(img)!;
	case viper::imgerror => void;
	};
	const names = ["gold", "silver", "bronze"];
	let buf: [32]u8 = [0...];
	for (let i = 0z; i < 3; i += 1) {
		a.evalin[i] = load_strip(fmt::bsprintf(buf, "evalin_cup_{}", names[i])!, 300, false);
		a.cup[i] = load_strip(fmt::bsprintf(buf, "cup_{}", names[i])!, 44, false);
	};
	return a;
};

fn set_last_name(g: *game, s: str) void = {
	const b = strings::toutf8(s);
	const n = if (len(b) > len(g.last_name_buf)) len(g.last_name_buf) else len(b);
	g.last_name_buf[..n] = b[..n];
	g.last_name = strings::fromutf8_unsafe(g.last_name_buf[..n]);
};

fn hs_name(e: *hsentry) str = strings::fromutf8_unsafe(e.name[..e.nlen]);

// Where a score would land on the board: 1-5, or 0 if it doesn't.
fn hs_rank(g: *game, score: int) int = {
	if (score <= 0) return 0;
	for (let i = 0z; i < NHS; i += 1) {
		if (i >= g.nhs || score > g.hs[i].score) return i: int + 1;
	};
	return 0;
};

// ---- The ceremony ----

fn start_ceremony(g: *game) void = {
	g.scr = screen::CUP;
	g.cel_t = 0.0;
	g.cel_cup = false;
	g.name_tb.focused = true;
	g.name_tb.length = 0;
	const last = strings::toutf8(g.last_name);
	g.name_tb.buf[..len(last)] = last;
	g.name_tb.length = len(last);
};

// Evalin's animation frame: she flies in on frame 1, conjures the cup
// (frame 2), and then shows it off (frames 3-6, looping).
fn ceremony_frame(t: f64, has_cup: bool) f64 = {
	if (!has_cup || t < 0.9) return 0.0;
	const f = 1.0 + (t - 0.9) / 0.3;
	if (f < 6.0) return f;
	return 2.0 + math::modf64(f - 2.0, 4.0);
};

fn draw_ceremony(win: *viper::window, g: *game, a: *hsart) void = {
	const dt = viper::delta(win);
	g.cel_t += dt;
	const t = g.cel_t;
	const rank = g.rank;
	const has_cup = rank >= 1 && rank <= 3;
	draw_hs_bg(win, g, a);
	shade(win, 0, 0, W, H, 0x12041e, 170);

	// The cup appears: a fanfare.
	if (has_cup && !g.cel_cup && t >= 0.9) {
		g.cel_cup = true;
		play_sfx(g, sfx::RAINBOW, 1.0, 1.0);
		play_sfx(g, sfx::LEVELUP, 0.9, 1.0);
	};

	// Evalin flies in from the left, bobbing.
	let e = t / 0.7;
	if (e > 1.0) e = 1.0;
	e = 1.0 - (1.0 - e) * (1.0 - e);
	const ex = -320.0 + e * 380.0;
	const ey = 150.0 + math::sinf64(t * 2.2) * 6.0;
	const s = &a.evalin[if (has_cup) rank: size - 1 else 0];
	const fi = ceremony_frame(t, has_cup);
	match (strip_frame(s, true, fi, 1.0, true)) {
	case let fr: *viper::image =>
		viper::draw_image(win, fr, ex: int, ey: int);
	case null =>
		draw_bee(win, ex + 150.0, ey + 150.0, 60.0);
	};
	// Sparkles around the cup.
	if (has_cup && t >= 0.9) {
		const cx = ex + 236.0, cy = ey + 96.0;
		const age = t - 0.9;
		for (let i = 0; i < 18; i += 1) {
			const ang = i: f64 * 0.349 + t * 0.6;
			const r = 30.0 + math::modf64(age * 70.0 + i: f64 * 13.0, 90.0);
			const x = cx + math::cosf64(ang) * r, y = cy + math::sinf64(ang) * r;
			const sz = 2 + (i % 3);
			const col: u32 = if (i % 2 == 0) 0xffffd23a else 0xffd88aff;
			viper::rect(win, x: int - sz * 2, y: int, sz * 4 + 1, 1, col);
			viper::rect(win, x: int, y: int - sz * 2, 1, sz * 4 + 1, col);
			viper::rect(win, x: int - 1, y: int - 1, 3, 3, 0xffffffff);
		};
	};

	if (t < 0.8) return;
	// Her speech bubble.
	let buf: [64]u8 = [0...];
	const bx = 400, by = 110, bw = 396, bh = 190;
	const tail: [3](f64, f64) = [(bx: f64 + 2.0, by: f64 + 60.0),
		(bx: f64 + 2.0, by: f64 + 90.0), (bx: f64 - 30.0, by: f64 + 96.0)];
	viper::round_rect(win, bx - 3, by - 3, bw + 6, bh + 6, 16, 0xffffc23a);
	viper::polygon(win, tail, 0xffffc23a);
	viper::round_rect(win, bx, by, bw, bh, 14, 0xfffff8e8);
	viper::text_scaled(win, bx + 20, by + 16, "BZZ-TASTIC!", 0xff6b2a8a, 3);
	if (has_cup) {
		viper::text(win, bx + 20, by + 72, "You've won the HONEY DROP CUP!", 0xff2a1604);
		viper::text(win, bx + 20, by + 94, "Congratulations, my champion!", 0xff6b2a8a);
		const cups = ["Guld", "Sølv", "Bronze"];
		viper::text_scaled(win, bx + 20, by + 126,
			fmt::bsprintf(buf, "{}. plads - {}", rank, cups[rank - 1])!, 0xffc07a10, 2);
	} else {
		viper::text(win, bx + 20, by + 72, "Du er på highscore-listen!", 0xff2a1604);
		viper::text(win, bx + 20, by + 94, "Flot spillet, lille bi.", 0xff6b2a8a);
		viper::text_scaled(win, bx + 20, by + 126,
			fmt::bsprintf(buf, "{}. plads", rank)!, 0xffc07a10, 2);
	};
	viper::text(win, bx + 20, by + 164, fmt::bsprintf(buf, "{} point", g.score)!, 0xff4a1a5a);

	if (t < 1.4) return;
	// The name.
	viper::round_rect(win, 400, 340, 396, 120, 14, 0xf02a1604);
	viper::text(win, 420, 356, "Skriv dit navn:", 0xffffd23a);
	const enter = viper::textbox(win, &g.name_tb, 420, 380, 260, "Bi");
	trim_name(&g.name_tb);
	const save = viper::button(win, " Gem ", 696, 380);
	viper::text(win, 420, 424, "Enter: gem", 0xffa07a48);
	if (enter || save) {
		play_sfx(g, sfx::CHIME, 1.0, 1.0);
		hs_insert(g);
	};
};

// Keeps a name to NAME_MAX characters.
fn trim_name(tb: *viper::textinput) void = {
	let n = 0z, i = 0z;
	for (i < tb.length; i += 1) {
		if (tb.buf[i] & 0xc0 != 0x80) {
			if (n == NAME_MAX) break;
			n += 1;
		};
	};
	tb.length = i;
};

fn hs_insert(g: *game) void = {
	const rank = g.rank;
	if (rank < 1) return;
	let name = strings::trim(viper::textinput_str(&g.name_tb));
	if (len(name) == 0) name = "Bi";
	let e = hsentry { score = g.score, level = g.level, ... };
	const b = strings::toutf8(name);
	const n = if (len(b) > len(e.name)) len(e.name) else len(b);
	e.name[..n] = b[..n];
	e.nlen = n;
	let last = g.nhs;
	if (last >= NHS) last = NHS - 1 else g.nhs += 1;
	for (let i = last; i > rank: size - 1; i -= 1) g.hs[i] = g.hs[i - 1];
	g.hs[rank - 1] = e;
	set_last_name(g, hs_name(&g.hs[rank - 1]));
	save_hs(g);
	g.hs_new = rank;
	g.rank = 0;
	g.hs_back = screen::GAME_OVER;
	g.scr = screen::HIGHSCORE;
	g.cel_t = 0.0;
};

// ---- The board ----

fn draw_hs_bg(win: *viper::window, g: *game, a: *hsart) void = {
	match (a.bg) {
	case let img: *viper::image => viper::draw_image(win, img, 0, 0);
	case null =>
		draw_background(win, g);
		centered(win, 40, "HIGHSCORE", 0xffffc23a, 5);
	};
};

const ROW_Y: [NHS]int = [255, 319, 385, 449, 508];

fn draw_highscore(win: *viper::window, g: *game, a: *hsart) void = {
	g.cel_t += viper::delta(win);
	draw_hs_bg(win, g, a);
	let buf: [48]u8 = [0...];
	const borders: [NHS]u32 = [0xffffc23a, 0xffd8dce8, 0xffd0783a, 0xff8a4ab0, 0xff8a4ab0];
	for (let i = 0z; i < NHS; i += 1) {
		const y = ROW_Y[i] - 24;
		const fresh = g.hs_new == i: int + 1;
		let border = borders[i];
		if (fresh && math::sinf64(g.cel_t * 8.0) > 0.0) border = 0xffff7ad8;
		viper::round_rect(win, 350, y, 344, 48, 12, border);
		viper::round_rect(win, 353, y + 3, 338, 42, 10,
			if (fresh) 0xff4a1a5a else 0xff22102e);
		if (i < 3 && len(a.cup[i].right) > 0) {
			viper::draw_image(win, &a.cup[i].right[0], 356, y + 2);
		} else {
			viper::text_scaled(win, 368, y + 8, fmt::bsprintf(buf, "{}", i + 1)!,
				0xfffff4d0, 2);
		};
		if (i >= g.nhs) {
			viper::text_scaled(win, 410, y + 8, "---", 0xff8a6aa0, 2);
			continue;
		};
		const e = &g.hs[i];
		viper::text_scaled(win, 410, y + 8, hs_name(e), 0xfffff4d0, 2);
		const sc = fmt::bsprintf(buf, "{}", e.score)!;
		viper::text_scaled(win, 684 - viper::text_width(sc, 2), y + 8, sc,
			if (i < 3) border else 0xfff2d8a8, 2);
	};

	let next = false, menu = false;
	if (g.hs_back == screen::GAME_OVER) {
		next = viper::button(win, " Nyt spil ", 400, 556);
		menu = viper::button(win, " Menu ", 560, 556);
	} else {
		menu = viper::button(win, " Tilbage ", 472, 556);
	};
	if (viper::key_pressed(win, viper::key::ESCAPE)) menu = true;
	if (next) {
		play_sfx(g, sfx::SWAP, 1.0, 1.0);
		g.hs_new = 0;
		g.autoplay = false;
		new_game(g);
	} else if (menu) {
		play_sfx(g, sfx::SWAP, 1.0, 1.0);
		g.hs_new = 0;
		g.scr = screen::MENU;
	};
};

fn open_highscore(g: *game) void = {
	g.hs_back = screen::MENU;
	g.hs_new = 0;
	g.cel_t = 0.0;
	g.scr = screen::HIGHSCORE;
};

// ---- The file: "score level name" per line, and "sidste name" ----

fn hs_path() (str | void) = {
	const dir = match (best_path()) {
	case let d: str => yield d;
	case void => return;
	};
	defer free(dir);
	return strings::concat(dir, "/highscore")!;
};

fn load_hs(g: *game) void = {
	g.nhs = 0;
	g.last_name = "";
	const path = match (hs_path()) {
	case let p: str => yield p;
	case void => return;
	};
	defer free(path);
	const f = match (os::open(path)) {
	case let f: io::file => yield f;
	case => return;
	};
	defer io::close(f)!;
	const data = match (io::drain(f)) {
	case let d: []u8 => yield d;
	case => return;
	};
	defer free(data);
	const text = match (strings::fromutf8(data)) {
	case let s: str => yield s;
	case => return;
	};
	const lines = strings::split(text, "\n")!;
	defer free(lines);
	for (let line .. lines) {
		const (a, rest) = strings::cut(line, " ");
		if (a == "sidste") {
			set_last_name(g, rest);
			continue;
		};
		if (g.nhs >= NHS) continue;
		const (b, name) = strings::cut(rest, " ");
		const score = match (strconv::stoi(a)) {
		case let n: int => yield n;
		case => continue;
		};
		const level = match (strconv::stoi(b)) {
		case let n: int => yield n;
		case => continue;
		};
		let e = hsentry { score = score, level = level, ... };
		const nb = strings::toutf8(name);
		const n = if (len(nb) > len(e.name)) len(e.name) else len(nb);
		e.name[..n] = nb[..n];
		e.nlen = n;
		g.hs[g.nhs] = e;
		g.nhs += 1;
	};
};

fn save_hs(g: *game) void = {
	const dir = match (best_path()) {
	case let d: str => yield d;
	case void => return;
	};
	defer free(dir);
	match (os::mkdirs(dir, fs::mode::USER_RWX)) {
	case => void;
	};
	const path = strings::concat(dir, "/highscore")!;
	defer free(path);
	const f = match (os::create(path, 0o644)) {
	case let f: io::file => yield f;
	case => return;
	};
	defer io::close(f)!;
	for (let i = 0z; i < g.nhs; i += 1) {
		const e = &g.hs[i];
		match (fmt::fprintfln(f, "{} {} {}", e.score, e.level, hs_name(e))) {
		case => void;
		};
	};
	match (fmt::fprintfln(f, "sidste {}", g.last_name)) {
	case => void;
	};
};
