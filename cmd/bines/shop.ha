// BINES — the Hive Shop. Queen Evalin sells boosters for guldhonning,
// the gold honey you earn by clearing levels and chasing off the thief.
// Coins and boosters are kept between games in ~/.local/share/bines/butik.
use fmt;
use fs;
use io;
use os;
use strconv;
use strings;
use viper;

def START_COINS: int = 60;

// Guldhonning for clearing a level: a base plus a bit per move left over.
fn level_coins(g: *game) int = 10 + 2 * g.moves_left;
def THIEF_COINS: int = 5;

fn earn(g: *game, n: int) void = {
	g.coins += n;
	save_shop(g);
};

fn open_shop(g: *game, back: screen) void = {
	g.shop_back = back;
	g.scr = screen::SHOP;
	g.shop_t = 0.0;
	shop_say(g, "Velkommen til min Hive Shop!", "Brug din guldhonning klogt.");
};

fn shop_say(g: *game, l1: str, l2: str) void = {
	g.shop_msg = (l1, l2);
	g.shop_msg_t = 3.0;
};

fn draw_shop(win: *viper::window, g: *game, b: *boosters) void = {
	const dt = viper::delta(win);
	g.shop_t += dt;
	if (g.shop_msg_t > 0.0) g.shop_msg_t -= dt;
	draw_background(win, g);
	viper::round_rect(win, 16, 12, 788, 636, 20, 0xec2a1604);

	viper::text_scaled(win, 43, 31, "HIVE SHOP", 0xff1a0d02, 4);
	viper::text_scaled(win, 40, 28, "HIVE SHOP", 0xffffc23a, 4);
	// Coins, with a little jar.
	let buf: [48]u8 = [0...];
	match (strip_frame(&b.slot[JAR], true, 0.0, 1.0, true)) {
	case let fr: *viper::image => viper::draw_image(win, fr, 540, 22);
	case null => void;
	};
	viper::text(win, 600, 28, "Guldhonning", 0xffc79a5a);
	viper::text_scaled(win, 600, 44, fmt::bsprintf(buf, "{}", g.coins)!, 0xffffd23a, 2);

	// Evalin behind her counter.
	viper::round_rect(win, 34, 90, 312, 312, 18, 0xffffc23a);
	viper::round_rect(win, 38, 94, 304, 304, 15, 0xff6b2a8a);
	match (strip_frame(&b.evalin, true, g.shop_t, 5.5, false)) {
	case let fr: *viper::image => viper::draw_image(win, fr, 40, 96);
	case null =>
		draw_bee(win, 190.0, 250.0, 60.0);
	};

	const (mx, my) = viper::mouse(win);
	let hover: (size | void) = void;
	for (let i = 0z; i < NBOOST; i += 1) {
		const y = 90 + i: int * 132;
		if (mx >= 370 && mx < 790 && my >= y && my < y + 120) hover = i;
	};

	// Her speech bubble: the last thing she said, or the booster you point at.
	let l1 = g.shop_msg.0, l2 = g.shop_msg.1;
	match (hover) {
	case let i: size =>
		if (g.shop_msg_t <= 0.0) {
			l1 = BOOSTERS[i].line1;
			l2 = BOOSTERS[i].line2;
		};
	case void => void;
	};
	const tail: [3](f64, f64) = [(170.0, 414.0), (200.0, 414.0), (176.0, 400.0)];
	viper::round_rect(win, 32, 412, 316, 62, 12, 0xff6b2a8a);
	viper::polygon(win, tail, 0xff6b2a8a);
	viper::round_rect(win, 36, 416, 308, 54, 10, 0xfffff8e8);
	viper::text(win, 48, 424, l1, 0xff4a1a5a);
	viper::text(win, 48, 444, l2, 0xff2a1604);

	// The boosters for sale.
	for (let i = 0z; i < NBOOST; i += 1) {
		const info = &BOOSTERS[i];
		const y = 90 + i: int * 132;
		const hot = match (hover) {
		case let h: size => yield h == i;
		case void => yield false;
		};
		viper::round_rect(win, 368, y, 424, 120, 14, if (hot) 0xff9a4ac0 else 0xff5a3410);
		viper::round_rect(win, 371, y + 3, 418, 114, 12, 0xff3d230a);
		viper::round_rect(win, 380, y + 10, SHOP_ICON, SHOP_ICON, 12, 0xff3a1a46);
		// The icon plays its animation while you point at it.
		const t = if (hot) g.shop_t else 0.0;
		const fps = 1.0 / (info.frame * 1.6);
		match (strip_frame(&b.shop[i], true, t, fps, false)) {
		case let fr: *viper::image => viper::draw_image(win, fr, 380, y + 10);
		case null => void;
		};
		viper::text_scaled(win, 494, y + 12, info.name, 0xffffc23a, 2);
		viper::text(win, 494, y + 46, info.line1, 0xfffff4d0);
		viper::text(win, 494, y + 64, info.line2, 0xfff2d8a8);
		viper::text(win, 494, y + 92, fmt::bsprintf(buf, "Har: {}", g.inv[i])!, 0xffc79a5a);
		viper::text(win, 590, y + 92, fmt::bsprintf(buf, "{} guld", info.price)!,
			if (g.coins >= info.price) 0xffffd23a else 0xffa07a48);
		if (viper::button(win, " Køb ", 706, y + 84)) buy(g, i);
	};

	const back = " Tilbage ";
	const bw = viper::text_width(back, 1) + 24;
	if (viper::button(win, back, 190 - bw / 2, 500)
			|| viper::key_pressed(win, viper::key::ESCAPE)) {
		play_sfx(g, sfx::SWAP, 1.0, 1.0);
		g.scr = g.shop_back;
	};
	viper::text(win, 52, 560, "Tjen guldhonning ved at klare", 0xffa07a48);
	viper::text(win, 52, 578, "niveauer og jage tyven væk.", 0xffa07a48);
};

fn buy(g: *game, i: size) void = {
	const info = &BOOSTERS[i];
	if (g.inv[i] >= MAX_OWN) {
		shop_say(g, "Din taske er fuld!", "Brug nogle først.");
		play_sfx(g, sfx::BONK, 0.7, 1.0);
		return;
	};
	if (g.coins < info.price) {
		shop_say(g, "Du mangler guldhonning.", "Klar flere niveauer, lille bi!");
		play_sfx(g, sfx::BONK, 0.7, 1.0);
		return;
	};
	g.coins -= info.price;
	g.inv[i] += 1;
	save_shop(g);
	shop_say(g, "Tak for handlen!", "Brug den med omtanke.");
	play_sfx(g, sfx::CHIME, 1.0, 1.0);
};

// ---- The shop file: "guld N", then one line per booster ----

const SAVE_KEYS: [NBOOST]str = ["scepter", "krukke", "bikage", "stav"];

fn shop_path() (str | void) = {
	const dir = match (best_path()) {
	case let d: str => yield d;
	case void => return;
	};
	defer free(dir);
	return strings::concat(dir, "/butik")!;
};

fn load_shop(g: *game) void = {
	g.coins = START_COINS;
	g.inv = [0...];
	g.inv[SCEPTER] = 1;
	const path = match (shop_path()) {
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
		const (k, v) = strings::cut(strings::trim(line), " ");
		const n = match (strconv::stoi(strings::trim(v))) {
		case let n: int => yield n;
		case => continue;
		};
		if (k == "guld") g.coins = n;
		for (let i = 0z; i < NBOOST; i += 1) {
			if (k == SAVE_KEYS[i]) g.inv[i] = if (n > MAX_OWN) MAX_OWN else n;
		};
	};
};

fn save_shop(g: *game) void = {
	const path = match (shop_path()) {
	case let p: str => yield p;
	case void => return;
	};
	defer free(path);
	const dir = match (best_path()) {
	case let d: str => yield d;
	case void => return;
	};
	defer free(dir);
	match (os::mkdirs(dir, fs::mode::USER_RWX)) {
	case => void;
	};
	const f = match (os::create(path, 0o644)) {
	case let f: io::file => yield f;
	case => return;
	};
	defer io::close(f)!;
	match (fmt::fprintfln(f, "guld {}", g.coins)) {
	case => void;
	};
	for (let i = 0z; i < NBOOST; i += 1) {
		match (fmt::fprintfln(f, "{} {}", SAVE_KEYS[i], g.inv[i])) {
		case => void;
		};
	};
};
