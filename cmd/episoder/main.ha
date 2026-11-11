// EPISODER — an episode tracker for one series, built on ViperGui. The
// series (name, episodes, air dates) comes from a serie.txt you keep
// yourself; see data.ha.
//
// The layout follows Bossun's mockup. With a mockup saved as
// assets/episoder/skin.png it is the background: its art, logo, cover and
// buttons stay, and everything that changes (the menu, the list, the
// progress ring, the details) is drawn live on top. Without it the scenery
// is drawn with ViperGui's shapes.
//
// Mouse: the menu on the left, the two parts, click a status to mark an
// episode seen, the buttons at the bottom. Keys: up/down pick an episode,
// space marks it, Enter plays the next one, 1/2 pick the part, Tab the
// next page, Esc quits.
use ascii;
use fmt;
use fs;
use math;
use os;
use os::exec;
use sort;
use sort::cmp;
use strings;
use viper;

def W: int = 1280;
def H: int = 720;

type page = enum { OVERVIEW, EPISODES, STATS, NOTES, SETTINGS };

const PAGES: [5](str, page) = [
	("Overblik", page::OVERVIEW),
	("Episoder", page::EPISODES),
	("Statistik", page::STATS),
	("Noter", page::NOTES),
	("Indstillinger", page::SETTINGS),
];

type app = struct {
	p: progress,
	pg: page,
	part: int,           // 0 or 1
	sel: size,           // the picked episode
	scroll: int,         // first row shown in the list
	clock: f64,
	msg: [160]u8,
	mlen: size,
	msg_t: f64,
	note_tb: viper::textinput,
	note_for: size,      // the episode note_tb was filled from (+ 1)
	dir_tb: viper::textinput,
	reset_armed: f64,    // the reset button was pressed once, this long ago
	skin: bool,          // the mockup is the background
	bg: viper::image,    // the mockup, or the drawn scenery
	cover: viper::image,
	quit: bool,
	chip_x: int,         // where the status chip goes
};

fn say(a: *app, s: str) void = {
	a.mlen = copy_utf8(a.msg, s);
	a.msg_t = 4.0;
};

export fn main() void = {
	match (load_show()) {
	case let e: str => fmt::fatal("episoder:", e);
	case void => void;
	};
	const title = strings::concat("Episoder - ", SERIES)!;
	const win = match (viper::open(title, W, H)) {
	case let w: *viper::window => yield w;
	case let e: viper::error => fmt::fatal("episoder:", viper::strerror(e));
	case nomem => fmt::fatal("episoder: out of memory");
	};
	free(title);
	defer viper::close(win);
	win.theme = viper::theme {
		bg = C_BLACK,
		panel = 0xff1c1013,
		border = C_RED_DIM,
		text = C_TEXT,
		text_dim = C_DIM,
		widget = 0xff1e1215,
		widget_hot = 0xff2a1a1e,
		accent = C_RED,
		accent_hot = C_RED_GLOW,
		accent_active = C_RED_DIM,
	};
	match (viper::load_png("assets/episoder/episoder-icon-64.png")) {
	case let icon: viper::image =>
		viper::set_icon(win, &icon);
		viper::image_free(&icon);
	case viper::imgerror => void;
	};

	let a = app {
		pg = page::EPISODES,
		bg = viper::image { w = 0, h = 0, pixels = [] },
		cover = viper::image { w = 0, h = 0, pixels = [] },
		...
	};
		// The mockup: next to serie.txt first, else in assets/episoder/.
	    const skin_path = match (save_dir()) {
	case let d: str =>
		const p = strings::concat(d, "/skin.png")!;
		free(d);
		yield if (os::exists(p)) p else {
			free(p);
			yield strings::dup("assets/episoder/skin.png")!;
		};
	case void => yield strings::dup("assets/episoder/skin.png")!;
	};
	defer free(skin_path);
	match (viper::load_png(skin_path)) {
	case let img: viper::image =>
		a.bg = viper::resize(&img, W, H)!;
		viper::image_free(&img);
		a.skin = true;
	case viper::imgerror =>
		a.bg = make_scenery(win);
		a.cover = make_cover(win, COVER_W, COVER_H);
	};
	load(&a.p);
	go_next(&a);
	a.dir_tb.length = copy_utf8(a.dir_tb.buf, folder(&a.p));

	for (viper::frame(win)) {
		const dt = viper::delta(win);
		a.clock += dt;
		if (a.msg_t > 0.0) a.msg_t -= dt;
		if (a.reset_armed > 0.0) a.reset_armed -= dt;
		const typing = a.note_tb.focused || a.dir_tb.focused;
		if (!typing && keys(win, &a)) break;
		draw(win, &a);
		if (a.quit) break;
		viper::present(win);
	};
};

// Picks the next episode to see, and shows its part.
fn go_next(a: *app) void = {
	const n = next_ep(&a.p);
	a.sel = if (n < NEP) n else NEP - 1;
	show_sel(a);
};

// Makes sure the picked episode is on the screen.
fn show_sel(a: *app) void = {
	a.part = (a.sel / PER): int;
	const row = (a.sel % PER): int;
	if (row < a.scroll) a.scroll = row;
	if (row >= a.scroll + ROWS) a.scroll = row - ROWS + 1;
};

fn toggle(a: *app, i: size) void = {
	a.p.seen[i] = if (a.p.seen[i] == 0) now() else 0;
	save(&a.p);
	let b: [64]u8 = [0...];
	say(a, if (a.p.seen[i] != 0) fmt::bsprintf(b, "E{:_02} er markeret som set.", i + 1)!
		else fmt::bsprintf(b, "E{:_02} er ikke set alligevel.", i + 1)!);
};

// Returns true to quit.
fn keys(win: *viper::window, a: *app) bool = {
	if (viper::key_pressed(win, viper::key::ESCAPE)) return true;
	if (viper::key_pressed(win, viper::key::TAB)) {
		a.pg = ((a.pg: int + 1) % len(PAGES): int): page;
	};
	if (viper::key_pressed(win, viper::key::DOWN) && a.sel + 1 < NEP) {
		a.sel += 1;
		show_sel(a);
	};
	if (viper::key_pressed(win, viper::key::UP) && a.sel > 0) {
		a.sel -= 1;
		show_sel(a);
	};
	if (viper::key_pressed(win, viper::key::SPACE)) toggle(a, a.sel);
	if (viper::key_pressed(win, viper::key::RETURN)
			|| viper::key_pressed(win, viper::key::KP_ENTER)) play(a);
	// 1-9 pick a part.
	for (let i = 0; i < 9 && i < nparts(); i += 1) {
		if (viper::key_pressed(win, (30 + i): viper::key)) {
			a.part = i;
			a.scroll = 0;
		};
	};
	return false;
};

// ---- Playing an episode ----

// The video files in the folder, sorted by name: file n is episode n.
fn videos(dir: str) []str = {
	let out: []str = [];
	const ents = match (os::readdir(dir)) {
	case let e: []fs::dirent => yield e;
	case => return out;
	};
	defer fs::dirents_free(ents);
	for (let e .. ents) {
		const n = ascii::strlower(e.name)!;
		defer free(n);
		for (let ext .. [".mkv", ".mp4", ".avi", ".webm", ".m4v", ".mov"]) {
			if (strings::hassuffix(n, ext)) {
				append(out, strings::dup(e.name)!)!;
				break;
			};
		};
	};
	sort::sort(out, size(str), &cmp::strs)!;
	return out;
};

fn play(a: *app) void = {
	const i = next_ep(&a.p);
	if (i == NEP) {
		say(a, "Du har set alle afsnit!");
		return;
	};
	if (a.p.flen == 0) {
		say(a, "Vælg mappen med afsnittene under Indstillinger.");
		a.pg = page::SETTINGS;
		return;
	};
	const files = videos(folder(&a.p));
	defer strings::freeall(files);
	let b: [160]u8 = [0...];
	if (i >= len(files)) {
		say(a, fmt::bsprintf(b, "Fandt kun {} videofiler i mappen.", len(files))!);
		return;
	};
	const path = strings::concat(folder(&a.p), "/", files[i])!;
	defer free(path);
	match (exec::cmd("xdg-open", path)) {
	case let c: exec::command =>
		match (exec::start(&c)) {
		case exec::process =>
			const m = fmt::asprintf("Afspiller E{:_02}: {}", i + 1, files[i])!;
			say(a, m);
			free(m);
		case => say(a, "Kunne ikke starte xdg-open.");
		};
	case => say(a, "Fandt ikke xdg-open.");
	};
	a.sel = i;
	show_sel(a);
};

// ---- The layout (the mockup's, scaled to 1280 x 720) ----

def TOP_H: int = 50;
def COVER_X: int = 34;
def COVER_Y: int = 63;
def COVER_W: int = 127;
def COVER_H: int = 171;
def SIDE_X: int = 15;
def SIDE_W: int = 164;
def SERIES_Y: int = 249;
def MENU_Y: int = 292;          // the first page's top
def MENU_STEP: int = 47;
def MENU_H: int = 38;
def HERO_X: int = 213;
def CHIP_X: int = 443;
def CHIP_Y: int = 267;
def PANEL_X: int = 213;
def PANEL_Y: int = 306;
def PANEL_W: int = 684;
def PANEL_H: int = 322;
def TAB_Y: int = 314;
def HEAD_Y: int = 361;
def LIST_X: int = 224;
def LIST_W: int = 662;
def LIST_Y: int = 393;
def ROW_H: int = 36;
def ROWS: int = 6;
def COL_TITLE: int = 297;
def COL_LEN: int = 646;
def COL_STATUS: int = 733;
def RIGHT_X: int = 919;
def RIGHT_W: int = 256;
def PROG_Y: int = 293;
def PROG_H: int = 139;
def RING_X: int = 1053;
def RING_Y: int = 375;
def RING_R: int = 47;
def DET_Y: int = 446;
def DET_H: int = 171;
def BTN_Y: int = 651;
def BTN_H: int = 38;
const BUTTONS: [4](int, int) = [(247, 163), (427, 171), (616, 156), (789, 181)];

// Colours of the mockup's surfaces, to paint over its fixed contents.
def S_SIDE: u32 = 0xff1d0b0c;
def S_PANEL: u32 = 0xff19090a;
def S_ROW: u32 = 0xff141012;
def S_HEAD: u32 = 0xff1e181b;

fn hit(win: *viper::window, x: int, y: int, w: int, h: int) bool = {
	const (mx, my) = viper::mouse(win);
	return mx >= x && mx < x + w && my >= y && my < y + h;
};

fn clicked(win: *viper::window, x: int, y: int, w: int, h: int) bool =
	viper::mouse_pressed(win) && hit(win, x, y, w, h);

// A dark glassy panel with a red rim.
fn panel(win: *viper::window, x: int, y: int, w: int, h: int) void = {
	viper::round_rect(win, x - 1, y - 1, w + 2, h + 2, 12, C_RED_DIM);
	viper::round_rect(win, x, y, w, h, 11, 0xff130709);
	shade(win, x + 4, y + 2, w - 8, 2, 0xffff6060, 40);
};

// A button; true when clicked. Over the mockup's own buttons only the
// glow is drawn (they are in the picture already) unless `own` is set.
fn btn(win: *viper::window, a: *app, x: int, y: int, w: int, label: str,
		icon: int, green: bool, own: bool) bool = {
	const over = hit(win, x, y, w, BTN_H);
	if (a.skin && !own) {
		if (over) {
			viper::outline(win, x - 1, y - 1, w + 2, BTN_H + 2, C_RED_GLOW);
			viper::outline(win, x - 2, y - 2, w + 4, BTN_H + 4, C_RED_DIM);
		};
		return over && viper::mouse_pressed(win);
	};
	const rim: u32 = if (green) (if (over) 0xff7dff8a else C_GREEN)
		else (if (over) C_RED_GLOW else 0xff4a3036);
	const fill: u32 = if (green) (if (over) 0xff2a7a33 else 0xff1e5e27)
		else (if (over) 0xff2a1a1e else 0xff1c1013);
	viper::round_rect(win, x, y, w, BTN_H, 8, rim);
	viper::round_rect(win, x + 2, y + 2, w - 4, BTN_H - 4, 7, fill);
	const tw = viper::text_width(label, 1) + 26;
	const tx = x + (w - tw) / 2;
	draw_icon(win, icon, tx + 8, y + BTN_H / 2, C_TEXT);
	viper::text(win, tx + 26, y + (BTN_H - 16) / 2, label, C_TEXT);
	return over && viper::mouse_pressed(win);
};

fn draw(win: *viper::window, a: *app) void = {
	viper::draw_image(win, &a.bg, 0, 0);
	if (!a.skin) draw_frame(win, a);
	draw_side(win, a);
	draw_chip(win, a);
	switch (a.pg) {
	case page::OVERVIEW => draw_overview(win, a);
	case page::EPISODES => draw_episodes(win, a);
	case page::STATS => draw_stats(win, a);
	case page::NOTES => draw_notes(win, a);
	case page::SETTINGS => draw_settings(win, a);
	};
	draw_progress(win, a);
	draw_details(win, a);
	draw_bottom(win, a);
	draw_message(win, a);
	// The mockup's close button, top right.
	if (a.skin && clicked(win, W - 44, 4, 40, 34)) a.quit = true;
};

// What the mockup has painted in already: the top bar, the cover, the
// title and the empty panels.
fn draw_frame(win: *viper::window, a: *app) void = {
	shade(win, 0, 0, W, TOP_H, 0x0a0406, 200);
	viper::rect(win, 0, TOP_H - 2, W, 2, C_RED_DIM);
	// A little hare head, for Hare.
	viper::circle(win, 30, 30, 10, C_TEXT);
	viper::round_rect(win, 21, 8, 6, 16, 3, C_TEXT);
	viper::round_rect(win, 31, 8, 6, 16, 3, C_TEXT);
	viper::circle(win, 26, 29, 2, C_BLACK);
	viper::circle(win, 34, 29, 2, C_BLACK);
	viper::text_scaled(win, 52, 10, "Hare", C_TEXT, 2);
	viper::text(win, 124, 18, "-  Episode Tracker", C_DIM);
	viper::text_scaled(win, W - 150, 10, "ViperGUI", C_TEXT, 2);
	shade(win, 0, TOP_H, SIDE_X + SIDE_W + 14, H - TOP_H, 0x0a0406, 150);
	viper::round_rect(win, COVER_X - 2, COVER_Y - 2, COVER_W + 4, COVER_H + 4, 6, C_RED_DIM);
	viper::draw_image(win, &a.cover, COVER_X, COVER_Y);
	// The title.
	const big = ascii::strupper(SERIES)!;
	defer free(big);
	let scale = 7;
	for (scale > 2 && viper::text_width(big, scale) > 640) scale -= 1;
	title_text(win, HERO_X, 76 + (7 - scale) * 8, big, scale);
	for (let i = 0; i < 4; i += 1) {
		viper::line(win, HERO_X + 10, 196 + i, HERO_X + 470, 182 + i,
			if (i == 0) C_RED_GLOW else C_RED);
	};
	viper::text_scaled(win, HERO_X, 203, SERIES, C_TEXT, 2);
	viper::text(win, HERO_X, 240, GENRES, C_DIM);
	draw_icon(win, 6, HERO_X + 8, 278, C_DIM);
	let hb: [96]u8 = [0...];
	const info = fmt::bsprintf(hb, "{} {}  ·  {} episoder ({})",
		nparts(), if (nparts() == 1) "del" else "dele", NEP, YEAR)!;
	viper::text(win, HERO_X + 26, 270, info, C_DIM);
	const end = HERO_X + 26 + viper::text_width(info, 1) + 14;
	a.chip_x = if (end > CHIP_X) end else CHIP_X;
	panel(win, PANEL_X, PANEL_Y, PANEL_W, PANEL_H);
	panel(win, RIGHT_X, PROG_Y, RIGHT_W, PROG_H);
	viper::text(win, RIGHT_X + 14, PROG_Y + 10, "Fremgang", C_TEXT);
	panel(win, RIGHT_X, DET_Y, RIGHT_W, DET_H);
	viper::text(win, RIGHT_X + 14, DET_Y + 10, "Detaljer", C_TEXT);
};

fn draw_side(win: *viper::window, a: *app) void = {
	// Over the mockup: paint out its menu and draw ours.
	if (a.skin) viper::rect(win, SIDE_X, SERIES_Y - 4, SIDE_W + 2, MENU_Y +
		len(PAGES): int * MENU_STEP - SERIES_Y + 4, S_SIDE);
	viper::round_rect(win, SIDE_X, SERIES_Y, SIDE_W, 32, 7, 0xff3a0c12);
	draw_icon(win, 0, SIDE_X + 20, SERIES_Y + 16, C_RED_GLOW);
	viper::clip(win, SIDE_X, SERIES_Y, SIDE_W - 6, 32);
	viper::text(win, SIDE_X + 42, SERIES_Y + 8, SERIES, C_RED_GLOW);
	viper::noclip(win);
	for (let i = 0z; i < len(PAGES); i += 1) {
		const (name, pg) = PAGES[i];
		const y = MENU_Y + i: int * MENU_STEP;
		const on = a.pg == pg;
		const over = hit(win, SIDE_X, y, SIDE_W, MENU_H);
		if (on) {
			viper::round_rect(win, SIDE_X, y, SIDE_W, MENU_H, 8, C_RED_GLOW);
			viper::round_rect(win, SIDE_X + 2, y + 2, SIDE_W - 4, MENU_H - 4, 7, 0xff3a0c12);
		} else if (over) {
			viper::round_rect(win, SIDE_X, y, SIDE_W, MENU_H, 8, 0xff2a1418);
		};
		draw_icon(win, i: int + 1, SIDE_X + 22, y + MENU_H / 2, if (on) C_TEXT else C_DIM);
		viper::text(win, SIDE_X + 44, y + (MENU_H - 16) / 2, name, if (on) C_TEXT else C_DIM);
		if (over && viper::mouse_pressed(win)) a.pg = pg;
	};
};

fn draw_chip(win: *viper::window, a: *app) void = {
	const n = nseen(&a.p);
	const chip = if (n == NEP: int) "Færdig" else if (n == 0) "Ikke startet" else "I gang";
	if (a.skin) viper::rect(win, CHIP_X - 4, CHIP_Y - 3, 110, 30, S_PANEL);
	const cw = viper::text_width(chip, 1) + 24;
	const cx = if (a.skin) CHIP_X else a.chip_x;
	viper::round_rect(win, cx, CHIP_Y, cw, 24, 7, C_GREEN);
	viper::round_rect(win, cx + 2, CHIP_Y + 2, cw - 4, 20, 6, 0xff1e5e27);
	viper::text(win, cx + 12, CHIP_Y + 4, chip, 0xffe8ffe8);
};

// The panel's inside, painted out (over the mockup: all of it, header
// and tabs too, for the pages that aren't the list).
fn clear_panel(win: *viper::window, a: *app) void = {
	if (!a.skin) return;
	viper::round_rect(win, PANEL_X + 4, PANEL_Y + 4, PANEL_W - 8, PANEL_H - 8, 9, S_PANEL);
	clear_foot(win);
};

// The mockup's panel reaches a little lower than the scaled box: paint out
// the last, half-shown row of its list.
fn clear_foot(win: *viper::window) void = {
	viper::rect(win, PANEL_X + 8, LIST_Y + ROWS * ROW_H, PANEL_W - 16,
		PANEL_Y + PANEL_H + 8 - (LIST_Y + ROWS * ROW_H), S_PANEL);
};

// ---- Episodes ----

fn draw_episodes(win: *viper::window, a: *app) void = {
	// The parts, one tab each (narrower when there are many).
	const np = nparts();
	if (a.part >= np) a.part = np - 1;
	if (a.skin) viper::rect(win, LIST_X - 4, TAB_Y - 4, LIST_W + 8, 42, S_PANEL);
	const tw = if ((LIST_W + 6) / np - 6 < 191) (LIST_W + 6) / np - 6 else 191;
	let lb: [48]u8 = [0...];
	for (let i = 0; i < np; i += 1) {
		const x = LIST_X + i * (tw + 6), on = a.part == i;
		const first = i * PER: int + 1;
		let label = fmt::bsprintf(lb, "Del {} (E{:_02} - E{:_02})", i + 1, first,
			first + part_len(i) - 1)!;
		if (viper::text_width(label, 1) > tw - 8) label = fmt::bsprintf(lb, "Del {}", i + 1)!;
		if (viper::text_width(label, 1) > tw - 8) label = fmt::bsprintf(lb, "{}", i + 1)!;
		viper::round_rect(win, x, TAB_Y, tw, 34, 7, if (on) C_RED_GLOW else 0xff3a2428);
		viper::round_rect(win, x + 2, TAB_Y + 2, tw - 4, 30, 6, if (on) 0xff5a0c14 else 0xff1e1215);
		viper::text(win, x + (tw - viper::text_width(label, 1)) / 2, TAB_Y + 9, label,
			if (on) C_TEXT else C_DIM);
		if (clicked(win, x, TAB_Y, tw, 34)) {
			a.part = i;
			a.scroll = 0;
		};
	};
	// The header (in the mockup already).
	if (!a.skin) {
		viper::rect(win, LIST_X, HEAD_Y, LIST_W, 30, S_HEAD);
		viper::text(win, LIST_X + 18, HEAD_Y + 7, "#", C_DIM);
		viper::text(win, COL_TITLE, HEAD_Y + 7, "Titel", C_DIM);
		viper::text(win, COL_LEN - 6, HEAD_Y + 7, "Varighed", C_DIM);
		viper::text(win, COL_STATUS, HEAD_Y + 7, "Status", C_DIM);
	};
	if (a.skin) clear_foot(win);
	viper::rect(win, LIST_X, LIST_Y, LIST_W, ROWS * ROW_H, S_ROW);
	// Rows (the wheel scrolls).
	if (hit(win, LIST_X, HEAD_Y, LIST_W, 30 + ROWS * ROW_H)) {
		a.scroll -= viper::wheel(win);
	};
	const plen = part_len(a.part);
	const maxscroll = if (plen > ROWS) plen - ROWS else 0;
	if (a.scroll > maxscroll) a.scroll = maxscroll;
	if (a.scroll < 0) a.scroll = 0;
	const next = next_ep(&a.p);
	let b: [16]u8 = [0...];
	for (let r = 0; r < ROWS && r < plen; r += 1) {
		const i = a.part: size * PER + (a.scroll + r): size;
		const y = LIST_Y + r * ROW_H;
		if (i == a.sel) {
			viper::round_rect(win, LIST_X - 2, y, LIST_W + 4, ROW_H - 1, 7, C_RED_GLOW);
			viper::round_rect(win, LIST_X, y + 2, LIST_W, ROW_H - 5, 6, 0xff4a1518);
		} else if (hit(win, LIST_X, y, LIST_W, ROW_H)) {
			viper::rect(win, LIST_X, y, LIST_W, ROW_H - 1, 0xff221418);
		};
		viper::rect(win, LIST_X, y + ROW_H - 1, LIST_W, 1, 0xff2a1e22);
		viper::text_scaled(win, LIST_X + 10, y + 2, fmt::bsprintf(b, "{:_02}", i + 1)!, C_TEXT, 2);
		viper::clip(win, COL_TITLE, y, COL_LEN - COL_TITLE - 12, ROW_H);
		viper::text(win, COL_TITLE, y + 10, EPISODES[i].title, C_TEXT);
		viper::noclip(win);
		viper::text(win, COL_LEN, y + 10, fmt::bsprintf(b, "{} min", EP_MIN)!, C_TEXT);
		// Status: click to change.
		if (a.p.seen[i] != 0) {
			checkbox(win, COL_STATUS, y + 7, true);
			viper::text(win, COL_STATUS + 30, y + 10, "Set", C_TEXT);
		} else if (i == next) {
			draw_icon(win, 7, COL_STATUS + 10, y + ROW_H / 2, C_TEXT);
			viper::text(win, COL_STATUS + 30, y + 10, "Næste", C_TEXT);
		} else {
			viper::circle(win, COL_STATUS + 11, y + ROW_H / 2, 10, C_DIM);
			viper::circle(win, COL_STATUS + 11, y + ROW_H / 2, 8, S_ROW);
			viper::text(win, COL_STATUS + 30, y + 10, "Ikke set", C_DIM);
		};
		if (clicked(win, COL_STATUS - 6, y, 140, ROW_H)) {
			toggle(a, i);
		} else if (clicked(win, LIST_X, y, LIST_W, ROW_H)) {
			a.sel = i;
		};
	};
	// A scroll bar.
	if (maxscroll == 0) return;
	const bh = ROWS * ROW_H * ROWS / plen;
	const by = LIST_Y + (ROWS * ROW_H - bh) * a.scroll / maxscroll;
	viper::round_rect(win, LIST_X + LIST_W + 3, by, 4, bh, 2, C_RED_DIM);
};

fn checkbox(win: *viper::window, x: int, y: int, on: bool) void = {
	viper::round_rect(win, x, y, 22, 22, 5, C_GREEN);
	viper::round_rect(win, x + 2, y + 2, 18, 18, 4, 0xff10200f);
	if (!on) return;
	for (let d = 0; d < 3; d += 1) {
		viper::line(win, x + 5, y + 11 + d, x + 9, y + 15 + d, C_GREEN);
		viper::line(win, x + 9, y + 15 + d, x + 17, y + 6 + d, C_GREEN);
	};
};

// ---- The right column: progress and details ----

fn draw_progress(win: *viper::window, a: *app) void = {
	if (a.skin) viper::circle(win, RING_X, RING_Y, RING_R + 14, S_PANEL);
	const n = nseen(&a.p);
	ring(win, RING_X, RING_Y, RING_R, n: f64 / NEP: f64);
	let b: [32]u8 = [0...];
	const s = fmt::bsprintf(b, "{} / {}", n, NEP)!;
	viper::text_scaled(win, RING_X - viper::text_width(s, 2) / 2, RING_Y - 22, s, C_TEXT, 2);
	const pc = fmt::bsprintf(b, "{}%", n * 100 / NEP: int)!;
	viper::text(win, RING_X - viper::text_width(pc, 1) / 2, RING_Y + 10, pc, C_DIM);
};

// A progress ring: a dark track and a green arc from the top.
fn ring(win: *viper::window, cx: int, cy: int, r: int, f: f64) void = {
	const steps = 160;
	for (let i = 0; i < steps; i += 1) {
		const t = i: f64 / steps: f64;
		const ang = -math::PI / 2.0 + t * 2.0 * math::PI;
		const x = cx + (math::cosf64(ang) * r: f64): int;
		const y = cy + (math::sinf64(ang) * r: f64): int;
		viper::circle(win, x, y, 5, if (t < f) C_GREEN else 0xff2a1e22);
	};
};

fn draw_details(win: *viper::window, a: *app) void = {
	if (a.skin) viper::rect(win, RIGHT_X + 6, DET_Y + 32, RIGHT_W - 12, DET_H - 40, S_PANEL);
	const e = a.sel;
	let b: [32]u8 = [0...], lb: [32]u8 = [0...];
	const rows: [5](int, str, str) = [
		(6, "Afsnit:", fmt::bsprintf(b, "E{:_02} - Del {}", e + 1, e / PER + 1)!),
		(8, "Sendt:", EPISODES[e].aired),
		(9, "Længde:", fmt::bsprintf(lb, "ca. {} min", EP_MIN)!),
		(10, "Studie:", STUDIO),
		(11, "Status:", if (a.p.seen[e] != 0) "Set" else if (e == next_ep(&a.p)) "Næste" else "Ikke set"),
	];
	for (let i = 0z; i < len(rows); i += 1) {
		const y = DET_Y + 40 + i: int * 25;
		draw_icon(win, rows[i].0, RIGHT_X + 24, y + 8, C_DIM);
		viper::text(win, RIGHT_X + 42, y, rows[i].1, C_DIM);
		viper::clip(win, RIGHT_X + 112, y, RIGHT_W - 122, 18);
		viper::text(win, RIGHT_X + 112, y, rows[i].2, C_TEXT);
		viper::noclip(win);
	};
};

// ---- Overview, statistics, notes, settings ----

fn draw_overview(win: *viper::window, a: *app) void = {
	clear_panel(win, a);
	const x = LIST_X;
	viper::text_scaled(win, x, PANEL_Y + 14, "Overblik", C_TEXT, 2);
	let b: [96]u8 = [0...];
	// A bar per part; with more than three parts, one for them all.
	const np = nparts();
	const rows = if (np > 3) 1 else np;
	const step = if (rows == 3) 40 else 56;
	for (let part = 0; part < rows; part += 1) {
		const y = PANEL_Y + 62 + part * step;
		const (n, of) = if (np > 3) (nseen(&a.p), NEP: int)
			else (nseen_part(&a.p, part), part_len(part));
		const first = part * PER: int + 1;
		viper::text(win, x, y, if (np > 3) "Alle afsnit"
			else fmt::bsprintf(b, "Del {}  (E{:_02} - E{:_02})", part + 1,
				first, first + of - 1)!, C_TEXT);
		viper::text(win, x + 560, y, fmt::bsprintf(b, "{} / {}", n, of)!, C_DIM);
		bar(win, x, y + 24, 620, n: f64 / of: f64);
	};
	const nx = next_ep(&a.p);
	const left = NEP: int - nseen(&a.p);
	if (nx < NEP) {
		viper::text(win, x, PANEL_Y + 192, "Næste afsnit", C_DIM);
		viper::text_scaled(win, x, PANEL_Y + 214, fmt::bsprintf(b, "E{:_02}", nx + 1)!, C_TEXT, 2);
		viper::clip(win, x + 76, PANEL_Y + 210, LIST_W - 80, 40);
		viper::text_scaled(win, x + 76, PANEL_Y + 214, EPISODES[nx].title, C_TEXT, 2);
		viper::noclip(win);
		viper::text(win, x, PANEL_Y + 262, fmt::bsprintf(b,
			"{} afsnit tilbage  ·  ca. {} t {} min", left,
			left * EP_MIN / 60, left * EP_MIN % 60)!, C_DIM);
	} else {
		viper::text_scaled(win, x, PANEL_Y + 214, "Alle afsnit er set!", C_GREEN, 2);
	};
};

fn bar(win: *viper::window, x: int, y: int, w: int, f: f64) void = {
	viper::round_rect(win, x, y, w, 12, 6, 0xff2a1e22);
	const fw = (w: f64 * f): int;
	if (fw > 0) viper::round_rect(win, x, y, if (fw < 12) 12 else fw, 12, 6, C_GREEN);
};

fn draw_stats(win: *viper::window, a: *app) void = {
	clear_panel(win, a);
	const x = LIST_X;
	viper::text_scaled(win, x, PANEL_Y + 14, "Statistik", C_TEXT, 2);
	const n = nseen(&a.p);
	let b1: [32]u8 = [0...], b2: [32]u8 = [0...], b3: [32]u8 = [0...];
	const tiles: [3](str, str) = [
		("Set", fmt::bsprintf(b1, "{} afsnit", n)!),
		("Tid brugt", fmt::bsprintf(b2, "{} t {} min", n * EP_MIN / 60, n * EP_MIN % 60)!),
		("Tilbage", fmt::bsprintf(b3, "{} t {} min", (NEP: int - n) * EP_MIN / 60,
			(NEP: int - n) * EP_MIN % 60)!),
	];
	for (let i = 0; i < 3; i += 1) {
		const tx = x + i * 214;
		viper::round_rect(win, tx, PANEL_Y + 52, 204, 62, 9, 0xff1e1215);
		viper::text(win, tx + 14, PANEL_Y + 60, tiles[i].0, C_DIM);
		viper::text_scaled(win, tx + 14, PANEL_Y + 80, tiles[i].1, C_TEXT,
			if (viper::text_width(tiles[i].1, 2) < 180) 2 else 1);
	};
	// Episodes per week, the last 8 weeks.
	viper::text(win, x, PANEL_Y + 128, "Afsnit set pr. uge (de sidste 8 uger)", C_DIM);
	let weeks: [8]int = [0...];
	per_week(&a.p, 8, weeks);
	let top = 1;
	for (let w .. weeks) if (w > top) top = w;
	let b: [16]u8 = [0...];
	const base = PANEL_Y + 262;
	for (let i = 0; i < 8; i += 1) {
		const bx = x + 10 + i * 80, h = weeks[i] * 100 / top;
		viper::rect(win, bx, base - 100, 52, 100, 0xff1e1215);
		if (h > 0) viper::round_rect(win, bx, base - h, 52, h, 6, if (i == 7) C_RED_GLOW else C_RED);
		const s = fmt::bsprintf(b, "{}", weeks[i])!;
		viper::text(win, bx + 26 - viper::text_width(s, 1) / 2, base + 4, s, C_DIM);
		const lab = if (i == 7) "nu" else fmt::bsprintf(b, "-{}", 7 - i)!;
		viper::text(win, bx + 26 - viper::text_width(lab, 1) / 2, base + 22, lab, C_DIM);
	};
};

fn draw_notes(win: *viper::window, a: *app) void = {
	clear_panel(win, a);
	const x = LIST_X;
	let b: [96]u8 = [0...];
	viper::text_scaled(win, x, PANEL_Y + 14, fmt::bsprintf(b, "Note til E{:_02}", a.sel + 1)!, C_TEXT, 2);
	viper::clip(win, x + 250, PANEL_Y + 14, LIST_W - 254, 30);
	viper::text(win, x + 250, PANEL_Y + 20, EPISODES[a.sel].title, C_DIM);
	viper::noclip(win);
	// The box holds the picked episode's note.
	if (a.note_for != a.sel + 1) {
		a.note_tb.length = copy_utf8(a.note_tb.buf, note(&a.p, a.sel));
		a.note_for = a.sel + 1;
	};
	if (viper::textbox(win, &a.note_tb, x, PANEL_Y + 52, 520, "Skriv en note og tryk Enter")) {
		set_note(&a.p, a.sel, viper::textinput_str(&a.note_tb));
		save(&a.p);
		a.note_tb.focused = false;
		say(a, "Noten er gemt.");
	};
	viper::text(win, x + 530, PANEL_Y + 59, "op/ned: afsnit", C_DIM);
	// All the notes so far.
	let y = PANEL_Y + 100;
	let any = false;
	for (let i = 0z; i < NEP && y < PANEL_Y + PANEL_H - 24; i += 1) {
		if (a.p.nlen[i] == 0) continue;
		any = true;
		if (clicked(win, x, y - 2, LIST_W, 22)) a.sel = i;
		viper::text(win, x, y, fmt::bsprintf(b, "E{:_02}", i + 1)!, C_RED_GLOW);
		viper::text(win, x + 50, y, note(&a.p, i), if (i == a.sel) C_TEXT else C_DIM);
		y += 24;
	};
	if (!any) viper::text(win, x, PANEL_Y + 100, "Ingen noter endnu.", C_DIM);
};

fn draw_settings(win: *viper::window, a: *app) void = {
	clear_panel(win, a);
	const x = LIST_X;
	viper::text_scaled(win, x, PANEL_Y + 14, "Indstillinger", C_TEXT, 2);
	viper::text(win, x, PANEL_Y + 56, "Mappen med afsnittene (sorteret efter navn: E01, E02...):", C_DIM);
	if (viper::textbox(win, &a.dir_tb, x, PANEL_Y + 80, 520, "/home/tux/Videos/Serie")) {
		set_folder(&a.p, strings::trim(viper::textinput_str(&a.dir_tb)));
		save(&a.p);
		a.dir_tb.focused = false;
		const files = videos(folder(&a.p));
		defer strings::freeall(files);
		let b: [96]u8 = [0...];
		say(a, fmt::bsprintf(b, "Gemt. Fandt {} videofiler i mappen.", len(files))!);
	};
	viper::text(win, x + 530, PANEL_Y + 87, "Enter: gem", C_DIM);
	viper::text(win, x, PANEL_Y + 130, "Fortsæt afspiller næste afsnit med xdg-open.", C_DIM);
	// Starting over: press twice.
	const label = if (a.reset_armed > 0.0) "Tryk igen for at nulstille" else "Nulstil fremgang";
	if (btn(win, a, x, PANEL_Y + 170, 300, label, 12, false, true)) {
		if (a.reset_armed > 0.0) {
			a.p.seen = [0...];
			save(&a.p);
			go_next(a);
			a.reset_armed = 0.0;
			say(a, "Fremgangen er nulstillet.");
		} else {
			a.reset_armed = 3.0;
		};
	};
	let b: [160]u8 = [0...];
	match (save_dir()) {
	case let d: str =>
		const path = progress_path(d);
		const m = fmt::asprintf("Gemmes i {}", path)!;
		viper::clip(win, x, PANEL_Y + 236, LIST_W, 20);
		viper::text(win, x, PANEL_Y + 240, m, C_DIM);
		viper::noclip(win);
		free(m);
		free(path);
		free(d);
	case void => void;
	};
	viper::text(win, x, PANEL_Y + 262, if (a.skin) "Baggrund: assets/episoder/skin.png"
		else "Læg din mockup som assets/episoder/skin.png for at bruge den.", C_DIM);
};

// ---- The buttons at the bottom ----

fn draw_bottom(win: *viper::window, a: *app) void = {
	const nx = next_ep(&a.p);
	let b: [32]u8 = [0...];
	const cont = if (nx < NEP) fmt::bsprintf(b, "Fortsæt (E{:_02})", nx + 1)! else "Alt er set";
	// "Fortsæt" changes, so it is always drawn; the others are the mockup's.
	if (btn(win, a, BUTTONS[0].0, BTN_Y, BUTTONS[0].1, cont, 7, true, true)) play(a);
	const mark = if (a.p.seen[a.sel] != 0) "Markér som ikke set" else "Markér som set";
	if (btn(win, a, BUTTONS[1].0, BTN_Y, BUTTONS[1].1, mark, 13, false, false)) toggle(a, a.sel);
	if (btn(win, a, BUTTONS[2].0, BTN_Y, BUTTONS[2].1, "Tilføj note", 14, false, false)) {
		a.pg = page::NOTES;
		a.note_for = 0;
		a.note_tb.focused = true;
	};
	if (btn(win, a, BUTTONS[3].0, BTN_Y, BUTTONS[3].1, "Opdatér", 15, false, false)) {
		load(&a.p);
		a.note_for = 0;
		a.dir_tb.length = copy_utf8(a.dir_tb.buf, folder(&a.p));
		let m: [64]u8 = [0...];
		say(a, fmt::bsprintf(m, "Opdateret: {} af {} set.", nseen(&a.p), NEP)!);
	};
};

fn draw_message(win: *viper::window, a: *app) void = {
	if (a.msg_t <= 0.0) return;
	const m = strings::fromutf8_unsafe(a.msg[..a.mlen]);
	const w = viper::text_width(m, 1) + 30;
	viper::round_rect(win, (W - w) / 2, 10, w, 30, 8, C_RED_GLOW);
	viper::round_rect(win, (W - w) / 2 + 2, 12, w - 4, 26, 7, 0xff3a0c12);
	viper::text(win, (W - w) / 2 + 15, 17, m, C_GOLD);
};

// ---- Little line icons ----

fn draw_icon(win: *viper::window, id: int, cx: int, cy: int, col: u32) void = {
	switch (id) {
	case 0 => // torii
		viper::rect(win, cx - 9, cy - 8, 18, 3, col);
		viper::rect(win, cx - 7, cy - 4, 14, 2, col);
		viper::rect(win, cx - 6, cy - 6, 2, 14, col);
		viper::rect(win, cx + 4, cy - 6, 2, 14, col);
	case 1 => // overview: a framed chart
		viper::outline(win, cx - 8, cy - 8, 16, 16, col);
		viper::line(win, cx - 5, cy + 4, cx - 1, cy, col);
		viper::line(win, cx - 1, cy, cx + 1, cy + 2, col);
		viper::line(win, cx + 1, cy + 2, cx + 5, cy - 4, col);
	case 2, 7 => // play
		const t: [3](f64, f64) = [((cx - 5): f64, (cy - 8): f64),
			((cx + 8): f64, cy: f64), ((cx - 5): f64, (cy + 8): f64)];
		viper::polygon(win, t, col);
	case 3 => // statistics: bars
		viper::rect(win, cx - 8, cy, 4, 8, col);
		viper::rect(win, cx - 2, cy - 7, 4, 15, col);
		viper::rect(win, cx + 4, cy - 3, 4, 11, col);
	case 4, 14 => // notes / bookmark
		viper::outline(win, cx - 6, cy - 8, 12, 16, col);
		viper::line(win, cx - 3, cy - 3, cx + 3, cy - 3, col);
		viper::line(win, cx - 3, cy + 1, cx + 3, cy + 1, col);
	case 5 => // settings: a cog
		for (let i = 0; i < 4; i += 1) {
			const ang = i: f64 * math::PI / 4.0;
			const dx = (math::cosf64(ang) * 9.0): int, dy = (math::sinf64(ang) * 9.0): int;
			viper::line(win, cx - dx, cy - dy, cx + dx, cy + dy, col);
		};
		viper::circle(win, cx, cy, 6, col);
		viper::circle(win, cx, cy, 3, 0xff130709);
	case 6, 8 => // calendar
		viper::outline(win, cx - 8, cy - 7, 16, 15, col);
		viper::rect(win, cx - 8, cy - 7, 16, 4, col);
		viper::rect(win, cx - 4, cy, 2, 2, col);
		viper::rect(win, cx + 2, cy, 2, 2, col);
	case 9 => // clock
		viper::circle(win, cx, cy, 8, col);
		viper::circle(win, cx, cy, 6, 0xff130709);
		viper::line(win, cx, cy, cx, cy - 5, col);
		viper::line(win, cx, cy, cx + 4, cy, col);
	case 10 => // layers
		for (let i = 0; i < 3; i += 1) {
			viper::line(win, cx - 8, cy - 4 + i * 4, cx, cy - 8 + i * 4, col);
			viper::line(win, cx, cy - 8 + i * 4, cx + 8, cy - 4 + i * 4, col);
		};
	case 11 => // star
		for (let i = 0; i < 5; i += 1) {
			const a0 = -math::PI / 2.0 + i: f64 * 4.0 * math::PI / 5.0;
			const a1 = -math::PI / 2.0 + (i + 1): f64 * 4.0 * math::PI / 5.0;
			viper::line(win, cx + (math::cosf64(a0) * 8.0): int, cy + (math::sinf64(a0) * 8.0): int,
				cx + (math::cosf64(a1) * 8.0): int, cy + (math::sinf64(a1) * 8.0): int, col);
		};
	case 12, 15 => // refresh: a broken ring with an arrow
		for (let i = 0; i < 33; i += 1) {
			const ang = i: f64 * 2.0 * math::PI / 40.0;
			viper::pixel(win, cx + (math::cosf64(ang) * 8.0): int, cy + (math::sinf64(ang) * 8.0): int, col);
			viper::pixel(win, cx + (math::cosf64(ang) * 7.0): int, cy + (math::sinf64(ang) * 7.0): int, col);
		};
		const t: [3](f64, f64) = [((cx + 4): f64, (cy - 9): f64), ((cx + 10): f64, (cy - 5): f64),
			((cx + 3): f64, (cy - 2): f64)];
		viper::polygon(win, t, col);
	case 13 => // a tick
		for (let d = 0; d < 2; d += 1) {
			viper::line(win, cx - 7, cy + d, cx - 2, cy + 5 + d, col);
			viper::line(win, cx - 2, cy + 5 + d, cx + 8, cy - 6 + d, col);
		};
	case => void;
	};
};

