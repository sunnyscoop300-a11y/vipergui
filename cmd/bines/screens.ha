// BINES — start menu, how-to-play, level complete and game over, plus the
// high score that is kept between games.
use fmt;
use fs;
use io;
use math;
use os;
use strconv;
use strings;
use viper;

type screen = enum { MENU, HOWTO, PLAY, LEVEL_DONE, GAME_OVER, SHOP, CUP, HIGHSCORE };

// The honey colours for ViperGui's widgets (buttons etc.).
const honey_theme: viper::theme = viper::theme {
	bg = 0xff3d230a,
	panel = 0xff2a1604,
	border = 0xff8a5212,
	text = 0xfffff4d0,
	text_dim = 0xffc79a5a,
	widget = 0xff4a2a08,
	widget_hot = 0xff5a3410,
	accent = 0xffe0951e,
	accent_hot = 0xffffb33a,
	accent_active = 0xffa86a10,
};

// ---- Levels ----

fn kinds_for(level: int) u8 =
	if (level >= 5) 7 else if (level >= 3) 6 else 5;

// Honey needed to finish a level. More piece kinds make honey scarcer, so
// the goal drops when a new kind arrives and then climbs again.
fn level_goal(level: int) f64 = switch (level) {
case 1 => yield 300.0;
case 2 => yield 400.0;
case 3 => yield 250.0;
case 4 => yield 300.0;
case => yield 200.0 + 25.0 * (level - 5): f64;
};

fn level_moves(level: int) int =
	if (level >= 5) 24 else if (level >= 3) 22 else 20;

// Worlds from the design document, one per two levels.
fn world_name(level: int) str = switch ((level - 1) / 2) {
case 0 => yield "Det Lille Bistade";
case 1 => yield "Blomsterengen";
case 2 => yield "Honningfabrikken";
case 3 => yield "Den Mørke Bikube";
case => yield "Dronningens Honningpalads";
};

fn start_level(g: *game) void = {
	g.moves = 0;
	g.moves_left = level_moves(g.level);
	g.goal = level_goal(g.level);
	g.meter = 0.0;
	g.combo = 0;
	g.nban = 0;
	g.b.kinds = kinds_for(g.level);
	thief_reset(&g.thief);
	g.bt = -1.0;
	queen_clear(g);
	g.thief.next = if (g.level == 1) 8 else FIRST_THIEF;
	g.st = state::FALL;
	g.sel = NONE;
	g.drag = NONE;
	g.idle = 0.0;
	fill(&g.b);
	g.scr = screen::PLAY;
	let buf: [48]u8 = [0...];
	announce(g, fmt::bsprintf(buf, "Niveau {}", g.level)!, 0xfffff4d0);
	announce(g, world_name(g.level), 0xffffc23a);
	let b1: [48]u8 = [0...], b2: [48]u8 = [0...];
	queen_say(g, fmt::bsprintf(b1, "Niveau {}: {}!", g.level, world_name(g.level))!,
		fmt::bsprintf(b2, "Saml {} honning på {} træk.", g.goal: int, g.moves_left)!);
	if (g.level == 1) {
		queen_say(g, "Pas på Honningtyven!", "Fyld krukken, så flygter han.");
		queen_say(g, "Kniber det, så brug en booster.", "Køb flere i min Hive Shop!");
	};
};

fn new_game(g: *game) void = {
	g.score = 0;
	g.level = 1;
	g.new_best = false;
	g.rank = 0;
	start_level(g);
};

// Called when everything has settled after a move.
fn check_level_end(g: *game) bool = {
	g.overlay_t = g.clock;
	if (g.meter >= g.goal) {
		// Leftover moves are worth points.
		g.bonus = g.moves_left * 100;
		g.score += g.bonus;
		record(g);
		g.scr = screen::LEVEL_DONE;
		g.thief.phase = tphase::OFF;
		queen_clear(g);
		g.earned = level_coins(g);
		earn(g, g.earned);
		let cb: [48]u8 = [0...];
		queen_say(g, "Godt klaret, lille bi!",
			fmt::bsprintf(cb, "Her er {} guldhonning.", g.earned)!);
		play_sfx(g, sfx::LEVELUP, 1.0, 1.0);
		return true;
	};
	if (g.moves_left <= 0) {
		record(g);
		g.scr = screen::GAME_OVER;
		g.thief.phase = tphase::OFF;
		queen_clear(g);
		queen_say(g, "Åh nej... honningen slap op.", "Vi prøver igen!");
		play_sfx(g, sfx::ESCAPE, 1.0, 1.0);
		return true;
	};
	return false;
};

fn record(g: *game) void = {
	g.rank = if (g.autoplay) 0 else hs_rank(g, g.score);
	if (g.score > g.saved_best) {
		g.new_best = true;
		g.saved_best = g.score;
		save_best(g.score);
	};
	if (g.score > g.best) g.best = g.score;
};

// ---- High score file: ~/.local/share/bines/rekord ----

fn best_path() (str | void) = {
	match (os::getenv("XDG_DATA_HOME")) {
	case let d: str =>
		if (len(d) > 0) return strings::concat(d, "/bines")!;
	case void => void;
	};
	match (os::getenv("HOME")) {
	case let h: str => return strings::concat(h, "/.local/share/bines")!;
	case void => return;
	};
};

fn load_best() int = {
	const dir = match (best_path()) {
	case let d: str => yield d;
	case void => return 0;
	};
	defer free(dir);
	const path = strings::concat(dir, "/rekord")!;
	defer free(path);
	const f = match (os::open(path)) {
	case let f: io::file => yield f;
	case => return 0;
	};
	defer io::close(f)!;
	let buf: [32]u8 = [0...];
	const n = match (io::read(f, buf)) {
	case let n: size => yield n;
	case => return 0;
	};
	const s = strings::trim(strings::fromutf8_unsafe(buf[..n]));
	match (strconv::stoi(s)) {
	case let v: int => return v;
	case => return 0;
	};
};

fn save_best(score: int) void = {
	const dir = match (best_path()) {
	case let d: str => yield d;
	case void => return;
	};
	defer free(dir);
	match (os::mkdirs(dir, fs::mode::USER_RWX)) { case => void; };
	const path = strings::concat(dir, "/rekord")!;
	defer free(path);
	const f = match (os::create(path, fs::mode::USER_RW)) {
	case let f: io::file => yield f;
	case => return;
	};
	defer io::close(f)!;
	match (fmt::fprintfln(f, "{}", score)) { case => void; };
};

// ---- Drawing ----

fn centered(win: *viper::window, y: int, text: str, col: viper::color, scale: int) void = {
	const x = (W - viper::text_width(text, scale)) / 2;
	viper::text_scaled(win, x + scale, y + scale, text, 0xff1a0d02, scale);
	viper::text_scaled(win, x, y, text, col, scale);
};

// A button centered on the screen.
fn big_button(win: *viper::window, label: str, y: int) bool = {
	const w = viper::text_width(label, 1) + 24;
	return viper::button(win, label, (W - w) / 2, y);
};

// Returns true when the player picked "Afslut".
fn draw_menu(win: *viper::window, g: *game, ts: *thief_sprites) bool = {
	draw_background(win, g);
	viper::round_rect(win, 160, 70, 500, 230, 24, 0xd02a1604);
	const bob = math::sinf64(g.clock * 2.0) * 4.0;
	centered(win, (96.0 + bob): int, "BINES", 0xffffc23a, 10);
	centered(win, 266, "Match the Honey. Save the Hive!", 0xfffff4d0, 1);
	// A few bees buzzing around the title box.
	for (let i = 0; i < 5; i += 1) {
		const t = g.clock * (0.6 + i: f64 * 0.17) + i: f64 * 1.3;
		const x = W: f64 / 2.0 + math::cosf64(t) * (270.0 + i: f64 * 14.0);
		const y = 185.0 + math::sinf64(t * 1.7) * (110.0 + i: f64 * 6.0);
		draw_bee(win, x, y, 10.0 + (i % 3): f64 * 2.0);
	};

	let buf: [48]u8 = [0...];
	if (g.saved_best > 0) {
		centered(win, 320, fmt::bsprintf(buf, "Rekord: {}", g.saved_best)!, 0xffc79a5a, 1);
	};
	if (big_button(win, "  Spil  ", 340)) {
		play_sfx(g, sfx::SWAP, 1.0, 1.0);
		g.autoplay = false;
		new_game(g);
	};
	if (big_button(win, " Hive Shop ", 378)) {
		play_sfx(g, sfx::SWAP, 1.0, 1.0);
		open_shop(g, screen::MENU);
	};
	if (big_button(win, " Highscore ", 416)) {
		play_sfx(g, sfx::SWAP, 1.0, 1.0);
		open_highscore(g);
	};
	if (big_button(win, "Sådan spiller du", 454)) {
		play_sfx(g, sfx::SWAP, 1.0, 1.0);
		g.scr = screen::HOWTO;
	};
	const quit = big_button(win, " Afslut ", 492);
	centered(win, 534, "D: se en demo   M: lyd   Esc: afslut", 0xffa07a48, 1);

	// The thief sneaks along the bottom of the menu now and then.
	const cycle = g.clock - math::floorf64(g.clock / 14.0) * 14.0;
	if (cycle < 7.0) {
		g.thief.x = W: f64 + 60.0 - cycle * 140.0;
		g.thief.phase = tphase::ENTER;
		g.thief.anim = g.clock;
		g.thief.bubble_t = 0.0;
		draw_shelf_wide(win);
		draw_thief(win, g, ts);
	} else {
		draw_shelf_wide(win);
	};
	return quit;
};

fn draw_shelf_wide(win: *viper::window) void = {
	viper::rect(win, 0, SHELF_Y: int, W, 10, 0xff6b3d0c);
	viper::rect(win, 0, SHELF_Y: int, W, 3, 0xffa8661c);
};

fn draw_howto(win: *viper::window, g: *game) void = {
	draw_background(win, g);
	viper::round_rect(win, 60, 30, 700, 590, 20, 0xe82a1604);
	centered(win, 50, "Sådan spiller du", 0xffffc23a, 3);
	const lines: [_](str, viper::color) = [
		("Byt to nabobrikker - klik på dem efter hinanden,", 0xfffff4d0),
		("eller træk en brik over på naboen.", 0xfffff4d0),
		("Tre eller flere ens på stribe forsvinder. På sekskanter", 0xfffff4d0),
		("tæller alle tre retninger: lodret og de to skrå!", 0xfffff4d0),
		("", 0),
		("MÅL: Fyld honningkrukken, før trækkene slipper op.", 0xffffc23a),
		("Honningdråber og specialbrikker giver mest honning.", 0xfffff4d0),
		("", 0),
		("4 på stribe   -> Honningstribe: rydder hele linjen", 0xfffff4d0),
		("To linjer i kryds -> Honningbombe: rydder 7 felter", 0xfffff4d0),
		("5 på stribe   -> Regnbueblomst: byt den med en farve,", 0xfffff4d0),
		("                 og alle brikker i den farve forsvinder", 0xfffff4d0),
		("", 0),
		("HONNINGTYVEN sniger sig ind på hylden og stjæler", 0xffff7a6a),
		("honning, hver gang du laver et træk. Fyld måleren til", 0xfffff4d0),
		("hans røde mærke, så flygter han (+500 point).", 0xfffff4d0),
		("Slipper han væk, tager han en stor skefuld honning!", 0xfffff4d0),
		("", 0),
		("Træk, du har tilbage, giver 100 point hver.", 0xfffff4d0),
		("", 0),
		("BOOSTERE købes i Hive Shop for guldhonning og bruges", 0xffd88aff),
		("med tasterne 1-4. Guld får du for niveauer og tyve.", 0xfffff4d0),
	];
	let y = 104;
	for (let l .. lines) {
		if (len(l.0) > 0) viper::text(win, 96, y, l.0, l.1);
		y += 20;
	};
	if (big_button(win, " Tilbage ", 570)) {
		play_sfx(g, sfx::SWAP, 1.0, 1.0);
		g.scr = screen::MENU;
	};
};

// The box drawn over the frozen board at the end of a level or game.
fn overlay_box(win: *viper::window) void = {
	viper::round_rect(win, 30, 150, 450, 330, 20, 0xf02a1604);
	viper::round_rect(win, 36, 156, 438, 318, 16, 0xf03d230a);
};

fn centered_box(win: *viper::window, y: int, text: str, col: viper::color, scale: int) void = {
	const x = 255 - viper::text_width(text, scale) / 2;
	viper::text_scaled(win, x + scale, y + scale, text, 0xff1a0d02, scale);
	viper::text_scaled(win, x, y, text, col, scale);
};

fn box_button(win: *viper::window, label: str, y: int) bool = {
	const w = viper::text_width(label, 1) + 24;
	return viper::button(win, label, 255 - w / 2, y);
};

fn draw_level_done(win: *viper::window, g: *game) void = {
	overlay_box(win);
	let buf: [48]u8 = [0...];
	centered_box(win, 180, fmt::bsprintf(buf, "Niveau {} klaret!", g.level)!, 0xff7ee07e, 3);
	// A full jar.
	viper::round_rect(win, 230, 236, 50, 56, 10, 0xffe0951e);
	viper::rect(win, 226, 228, 58, 12, 0xff8a5212);
	viper::rect(win, 240, 252, 8, 26, 0xffffd88a);
	centered_box(win, 310, fmt::bsprintf(buf, "Bonus for {} træk tilbage: +{}",
		g.bonus / 100, g.bonus)!, 0xfffff4d0, 1);
	centered_box(win, 336, fmt::bsprintf(buf, "Point: {}", g.score)!, 0xffffc23a, 2);
	if (g.new_best) centered_box(win, 366, "Ny rekord!", 0xffff9cf0, 1);
	centered_box(win, 386, fmt::bsprintf(buf, "Guldhonning +{}  (i alt {})",
		g.earned, g.coins)!, 0xffffd23a, 1);
	if (viper::button(win, " Næste niveau ", 104, 420)) {
		play_sfx(g, sfx::SWAP, 1.0, 1.0);
		g.level += 1;
		start_level(g);
	};
	if (viper::button(win, " Hive Shop ", 280, 420)) {
		play_sfx(g, sfx::SWAP, 1.0, 1.0);
		open_shop(g, screen::LEVEL_DONE);
	};
};

fn draw_game_over(win: *viper::window, g: *game) void = {
	overlay_box(win);
	let buf: [48]u8 = [0...];
	centered_box(win, 176, "Honningen slap op!", 0xffff7a6a, 3);
	centered_box(win, 226, "Krukken blev ikke fyldt i tide.", 0xfff2d8a8, 1);
	centered_box(win, 262, fmt::bsprintf(buf, "Point: {}", g.score)!, 0xffffc23a, 2);
	centered_box(win, 300, fmt::bsprintf(buf, "Du nåede niveau {} - {}", g.level,
		world_name(g.level))!, 0xfffff4d0, 1);
	if (g.new_best) {
		centered_box(win, 324, "Ny rekord!", 0xffff9cf0, 2);
	} else {
		centered_box(win, 328, fmt::bsprintf(buf, "Rekord: {}", g.saved_best)!, 0xffc79a5a, 1);
	};
	if (g.rank > 0 && !g.autoplay) {
		const what = if (g.rank <= 3) " Hent din pokal! " else " Til highscore-listen ";
		if (box_button(win, what, 380)) start_ceremony(g);
	} else if (box_button(win, " Prøv igen ", 380)) {
		play_sfx(g, sfx::SWAP, 1.0, 1.0);
		new_game(g);
	};
	if (box_button(win, " Menu ", 424)) {
		play_sfx(g, sfx::SWAP, 1.0, 1.0);
		g.scr = screen::MENU;
	};
};
