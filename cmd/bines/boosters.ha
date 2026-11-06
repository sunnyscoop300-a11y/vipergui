// BINES — boosters. They are bought in the Hive Shop (shop.ha) and used
// from the panel during a level: click one or press its number key (1-4).
// Each plays its animation over the board and does its magic at the peak.
// Using a booster costs no move.
//
//   1 Scepteret      7 pieces become honey drops
//   2 Honningkrukke  fills the honey jar by a quarter of the goal
//   3 Gylden Bikage  3 pieces become honey bombs
//   4 Kongestav      5 extra moves
use fmt;
use math::random;
use viper;

def NBOOST: size = 4;
def SCEPTER: size = 0;
def JAR: size = 1;
def COMB: size = 2;
def WAND: size = 3;
def MAX_OWN: int = 9;

def SLOT: int = 56;            // panel slot size
def BIG: int = 220;            // size over the board
def SHOP_ICON: int = 100;      // size in the shop

type binfo = struct {
	name: str,
	line1: str,
	line2: str,
	price: int,
	file: str,
	frame: f64,    // seconds per frame
	peak: int,     // the frame where the magic happens
	hold: f64,     // how long the last frame stays up
};

const BOOSTERS: [NBOOST]binfo = [
	binfo { name = "Scepteret", line1 = "7 brikker bliver til honning.",
		line2 = "Kan starte nye combos.", price = 30, file = "scepter",
		frame = 0.12, peak = 4, hold = 0.0 },
	binfo { name = "Honningkrukke", line1 = "Fylder honningkrukken med",
		line2 = "en fjerdedel af målet.", price = 25, file = "booster_jar",
		frame = 0.22, peak = 2, hold = 0.45 },
	binfo { name = "Gylden Bikage", line1 = "3 brikker bliver til",
		line2 = "honningbomber.", price = 35, file = "booster_comb",
		frame = 0.22, peak = 2, hold = 0.45 },
	binfo { name = "Kongestav", line1 = "Giver 5 ekstra træk.",
		line2 = "Kongelig magi fra Evalin.", price = 20, file = "booster_wand",
		frame = 0.22, peak = 2, hold = 0.45 },
];

type boosters = struct {
	big: [NBOOST]strip,
	slot: [NBOOST]strip,
	shop: [NBOOST]strip,
	evalin: strip,       // Evalin in the shop
};

fn load_boosters() boosters = {
	let b = boosters { evalin = load_strip("evalin_shop", 300, false), ... };
	for (let i = 0z; i < NBOOST; i += 1) {
		b.big[i] = load_strip(BOOSTERS[i].file, BIG, false);
		b.slot[i] = load_strip(BOOSTERS[i].file, SLOT, false);
		b.shop[i] = load_strip(BOOSTERS[i].file, SHOP_ICON, false);
	};
	return b;
};

fn slot_pos(i: size) (int, int) = (520 + i: int * 68, 482);

fn booster_frames(b: *boosters, k: size) size =
	if (len(b.big[k].right) > 0) len(b.big[k].right) else 3;

// Starts a booster if the player asks for one. Call while idle.
fn booster_try(win: *viper::window, g: *game) bool = {
	if (g.bt >= 0.0) return false;
	const (mx, my) = viper::mouse(win);
	for (let i = 0z; i < NBOOST; i += 1) {
		const (sx, sy) = slot_pos(i);
		const clicked = viper::mouse_pressed(win) && mx >= sx && mx < sx + SLOT
			&& my >= sy && my < sy + SLOT;
		// Number keys 1-4 (USB HID 30-33).
		const key = viper::key_pressed(win, (30 + i): viper::key);
		if (!clicked && !key) continue;
		if (g.inv[i] <= 0) {
			play_sfx(g, sfx::BONK, 0.6, 1.0);
			return false;
		};
		g.inv[i] -= 1;
		save_shop(g);
		g.bk = i;
		g.bt = 0.0;
		g.bfired = false;
		g.sel = NONE;
		g.drag = NONE;
		play_sfx(g, sfx::SPARKLE, 1.0, 0.8);
		return true;
	};
	return false;
};

// Runs the animation and fires the magic at its peak.
fn booster_update(g: *game, b: *boosters, dt: f64) void = {
	if (g.bt < 0.0) return;
	const info = &BOOSTERS[g.bk];
	g.bt += dt;
	if (!g.bfired && g.bt >= info.peak: f64 * info.frame) {
		g.bfired = true;
		booster_magic(g, g.bk);
	};
	if (g.bt >= booster_frames(b, g.bk): f64 * info.frame + info.hold) g.bt = -1.0;
};

// Ordinary pieces (no power-up, not the rainbow flower) at random.
fn random_plain(g: *game, honey_ok: bool) ((int, int) | void) = {
	for (let tries = 0; tries < 400; tries += 1) {
		const c = random::u32n(&g.b.rng, COLS: u32): int;
		const r = random::u32n(&g.b.rng, ROWS: u32): int;
		const p = &g.b.c[c][r];
		if (p.kind == RAINBOW || p.kind == EMPTY || p.special != special::NONE) continue;
		if (!honey_ok && p.kind == piece::HONEY) continue;
		return (c, r);
	};
};

fn booster_magic(g: *game, k: size) void = {
	const (cx, cy) = center(COLS / 2, ROWS / 2);
	switch (k) {
	case SCEPTER =>
		for (let i = 0; i < 7; i += 1) match (random_plain(g, false)) {
		case let p: (int, int) =>
			g.b.c[p.0][p.1].kind = piece::HONEY;
			const (x, y) = center(p.0, p.1);
			burst(g, x, y, 0xffffd23a);
			burst(g, x, y, 0xffd88aff);
		case void => void;
		};
		float_text(g, cx, cy - 40.0, "Kongelig honning!", 0xffffd23a, 2);
		play_sfx(g, sfx::RAINBOW, 1.0, 1.0);
	case JAR =>
		const before = g.meter;
		g.meter += g.goal * 0.25;
		if (g.meter > g.goal) g.meter = g.goal;
		float_text(g, cx, cy - 40.0, "Krukken flyder over!", 0xffffd23a, 2);
		for (let i = 0; i < 4; i += 1) burst(g, cx, cy, 0xffffb320);
		if (before < g.goal && g.meter >= g.goal) {
			announce(g, "Krukken er fuld!", 0xffffd23a);
		};
		thief_on_honey(g);
	case COMB =>
		for (let i = 0; i < 3; i += 1) match (random_plain(g, true)) {
		case let p: (int, int) =>
			g.b.c[p.0][p.1].kind = piece::HONEY;
			g.b.c[p.0][p.1].special = special::BOMB;
			const (x, y) = center(p.0, p.1);
			burst(g, x, y, 0xffffd23a);
			burst(g, x, y, 0xfff6e7b0);
		case void => void;
		};
		float_text(g, cx, cy - 40.0, "Honningbomber!", 0xffffd23a, 2);
		play_sfx(g, sfx::BOOM, 0.7, 1.2);
	case WAND =>
		g.moves_left += 5;
		float_text(g, cx, cy - 40.0, "+5 træk!", 0xffd88aff, 3);
		for (let i = 0; i < 4; i += 1) burst(g, cx, cy, 0xffd88aff);
	case => abort();
	};
	play_sfx(g, sfx::CHIME, 0.8, 1.2);
	// Let the board look for matches, and see if the level is done.
	g.combo = 0;
	g.from_swap = false;
	g.st = state::FALL;
};

// The booster over the board while it works.
fn draw_booster_magic(win: *viper::window, g: *game, b: *boosters) void = {
	if (g.bt < 0.0) return;
	const info = &BOOSTERS[g.bk];
	// A golden flash around the peak.
	const d = g.bt - info.peak: f64 * info.frame;
	if (d > -0.15 && d < 0.3) {
		const a = (if (d < 0.0) (d + 0.15) / 0.15 else 1.0 - d / 0.3) * 90.0;
		shade(win, 0, 0, 494, H, 0xffd86a, a: u32);
	};
	const (cx, cy) = center(COLS / 2, ROWS / 2);
	match (strip_frame(&b.big[g.bk], true, g.bt, 1.0 / info.frame, true)) {
	case let fr: *viper::image =>
		viper::draw_image(win, fr, cx: int - fr.w / 2, cy: int - fr.h / 2);
	case null =>
		viper::circle(win, cx: int, cy: int, 40, 0xffffc23a);
	};
};

// The booster slots in the panel.
fn draw_booster_slots(win: *viper::window, g: *game, b: *boosters) void = {
	viper::text(win, 520, 462, "BOOSTERE  (tast 1-4)", 0xffc79a5a);
	const (mx, my) = viper::mouse(win);
	let buf: [8]u8 = [0...];
	for (let i = 0z; i < NBOOST; i += 1) {
		const (sx, sy) = slot_pos(i);
		const ready = g.inv[i] > 0 && g.bt < 0.0 && g.scr == screen::PLAY;
		const hot = mx >= sx && mx < sx + SLOT && my >= sy && my < sy + SLOT;
		viper::round_rect(win, sx - 3, sy - 3, SLOT + 6, SLOT + 6, 10,
			if (hot && ready) 0xff9a4ac0 else if (g.bt >= 0.0 && g.bk == i) 0xffffc23a
			else 0xff2a1604);
		viper::round_rect(win, sx, sy, SLOT, SLOT, 8, 0xff3a1a46);
		match (strip_frame(&b.slot[i], true, 0.0, 1.0, true)) {
		case let fr: *viper::image =>
			viper::draw_image(win, fr, sx + (SLOT - fr.w) / 2, sy + (SLOT - fr.h) / 2);
		case null => void;
		};
		if (g.inv[i] <= 0) shade(win, sx, sy, SLOT, SLOT, 0x2a1604, 150);
		viper::text(win, sx + 3, sy + 1, fmt::bsprintf(buf, "{}", i + 1)!, 0xfffff4d0);
		const n = fmt::bsprintf(buf, "x{}", g.inv[i])!;
		viper::text(win, sx + SLOT - 20, sy + SLOT - 15, n, 0xff1a0d02);
		viper::text(win, sx + SLOT - 21, sy + SLOT - 16, n,
			if (g.inv[i] > 0) 0xffffd23a else 0xffa07a48);
	};
	// The name of the booster under the mouse.
	for (let i = 0z; i < NBOOST; i += 1) {
		const (sx, sy) = slot_pos(i);
		if (mx >= sx && mx < sx + SLOT && my >= sy && my < sy + SLOT) {
			viper::text(win, 520, sy + SLOT + 6, BOOSTERS[i].name, 0xffd88aff);
		};
	};
};
