// SAMLING — a tracker for a family of series and films, built on ViperGui.
// What is in the family comes from samling.txt; see data.ha.
//
// The layout follows Bossun's mockup (1536 x 1024 with a title bar): every
// position below is in the mockup's pixels and X/Y/L scale it to the
// window. With the mockup saved as skin.png it is the background: its art,
// covers and buttons stay, and what changes is painted over and drawn live.
//
// Mouse: the menu, the cards, the season tabs; click an episode to pick
// it, click it again to mark it seen. Keys: arrows move, space marks,
// 1-9 pick a season, Tab the next page, Esc quits.
use ascii;
use fmt;
use math;
use os;
use strings;
use time;
use time::date;
use viper;

def W: int = 1200;
def H: int = 767;

// Mockup pixels to window pixels (the mockup's title bar is cut off).
fn X(v: int) int = v * 25 / 32;
fn Y(v: int) int = (v - 42) * 25 / 32;
fn L(v: int) int = v * 25 / 32;

type page = enum { OVERVIEW, SERIES, FILMS, STATS, SYNC, SETTINGS, ABOUT };

type app = struct {
	p: progress,
	pg: page,
	ent: size,           // the series shown
	season: size,
	sel: size,           // the picked episode, in ent's list
	gscroll: int,        // first grid row shown
	lscroll: int,        // first list row shown
	skin: bool,
	bg: viper::image,
	msg: [160]u8,
	mlen: size,
	msg_t: f64,
	sync: [48]u8,        // what MEGA said last
	slen: size,
	reset_armed: f64,
	reset_ent: size,
	covers: [MAXENT]cover,
	mail_tb: viper::textinput,
	pass_tb: viper::textinput,
	sync_checked: bool,  // the sync page has asked MEGA once
};

// A cover: the picture as found, and copies sized for a card and for
// the film page (made the first time they are needed).
type cover = struct {
	src: viper::image,
	card: viper::image,
	film: viper::image,
};

const NO_IMAGE: viper::image = viper::image { w = 0, h = 0, pixels = [] };

fn say(a: *app, s: str) void = {
	a.mlen = copy_utf8(a.msg, s);
	a.msg_t = 4.0;
};

export fn main() void = {
	match (load_collection()) {
	case let e: str => fmt::fatal("samling:", e);
	case void => void;
	};
	const title = strings::concat(TITLE, " - ViperGui")!;
	const win = match (viper::open(title, W, H)) {
	case let w: *viper::window => yield w;
	case let e: viper::error => fmt::fatal("samling:", viper::strerror(e));
	case nomem => fmt::fatal("samling: out of memory");
	};
	free(title);
	defer viper::close(win);
	win.theme = viper::theme {
		bg = C_BG,
		panel = C_PANEL,
		border = C_BORDER,
		text = C_TEXT,
		text_dim = C_DIM,
		widget = C_UNSEEN,
		widget_hot = 0xff22337a,
		accent = C_YELLOW,
		accent_hot = C_YEL_HI,
		accent_active = 0xffb08a0a,
	};
	match (viper::load_png("assets/samling/samling-icon-64.png")) {
	case let icon: viper::image =>
		viper::set_icon(win, &icon);
		viper::image_free(&icon);
	case viper::imgerror => void;
	};

	let a = app {
		bg = viper::image { w = 0, h = 0, pixels = [] },
		...
	};
	for (let e = 0z; e < MAXENT; e += 1) {
		a.covers[e] = cover { src = NO_IMAGE, card = NO_IMAGE, film = NO_IMAGE };
	};
	load_covers(&a);
	const skin = find_file("skin.png");
	match (viper::load_png(skin)) {
	case let img: viper::image =>
		covers_from_mockup(&a, &img);
		// The mockup's own title bar goes; the window has one.
		const top = img.h * 42 / 1024;
		const cut = viper::crop(&img, 0, top, img.w, img.h - top)!;
		a.bg = viper::resize(&cut, W, H)!;
		viper::image_free(&cut);
		viper::image_free(&img);
		a.skin = true;
	case viper::imgerror => void;
	};
	free(skin);
	load(&a.p);
	a.ent = first_series();
	go_next(&a);

	for (viper::frame(win)) {
		const dt = viper::delta(win);
		if (a.msg_t > 0.0) a.msg_t -= dt;
		if (a.reset_armed > 0.0) a.reset_armed -= dt;
		if (keys(win, &a)) break;
		draw(win, &a);
		viper::present(win);
	};
};

// cover-<name>.png in the save folder (or assets/samling/), for any entry:
// "The Family Return" -> cover-the-family-return.png
fn load_covers(a: *app) void = {
	for (let e = 0z; e < len(ENTRIES); e += 1) {
		const s = slug(ENTRIES[e].name);
		const name = strings::concat("cover-", s, ".png")!;
		free(s);
		const path = find_file(name);
		free(name);
		match (viper::load_png(path)) {
		case let img: viper::image => a.covers[e].src = img;
		case viper::imgerror => void;
		};
		free(path);
	};
};

// Where the mockup has its three covers (mockup pixels, inside the frame).
const MOCK_COVERS: [3](int, int, int, int) = [
	(276, 302, 128, 156), (710, 304, 126, 154), (1122, 304, 126, 154),
];

// The first three entries without a cover file get theirs from the mockup.
fn covers_from_mockup(a: *app, img: *viper::image) void = {
	for (let c = 0z; c < len(MOCK_COVERS) && c < len(ENTRIES); c += 1) {
		if (a.covers[c].src.w != 0) continue;
		const (x, y, w, h) = MOCK_COVERS[c];
		a.covers[c].src = viper::crop(img, x * img.w / 1536, y * img.h / 1024,
			w * img.w / 1536, h * img.h / 1024)!;
	};
};

// Entry e's cover at w x h, or null when it has none.
fn cover_at(a: *app, e: size, film: bool, w: int, h: int) nullable *viper::image = {
	const c = &a.covers[e];
	if (c.src.w == 0) return null;
	const img = if (film) &c.film else &c.card;
	if (img.w != w || img.h != h) {
		if (img.w != 0) viper::image_free(img);
		*img = viper::resize(&c.src, w, h)!;
	};
	return img;
};

// The cover, or a drawn one.
fn show_cover(win: *viper::window, a: *app, e: size, film: bool, x: int, y: int, w: int, h: int) void = {
	match (cover_at(a, e, film, w, h)) {
	case let img: *viper::image =>
		viper::round_rect(win, x - 1, y - 1, w + 2, h + 2, 7, 0xff5a73ff);
		viper::draw_image(win, img, x, y);
	case null => draw_cover(win, x, y, w, h, ENTRIES[e].name, e);
	};
};

fn first_series() size = {
	for (let e = 0z; e < len(ENTRIES); e += 1) if (!ENTRIES[e].film) return e;
	return 0;
};

// Picks the next episode to see in the shown series.
fn go_next(a: *app) void = {
	if (ENTRIES[a.ent].film) return;
	const n = next_ep(&a.p, a.ent);
	a.sel = if (n < nep(a.ent)) n else nep(a.ent) - 1;
	a.season = season_of(a.ent, a.sel);
	show_sel(a);
};

fn show_sel(a: *app) void = {
	const se = ENTRIES[a.ent].seasons[a.season];
	const i = (a.sel - se.first): int;
	const row = i / 5;
	if (row < a.gscroll) a.gscroll = row;
	if (row >= a.gscroll + 4) a.gscroll = row - 3;
	if (i < a.lscroll) a.lscroll = i;
	if (i >= a.lscroll + LIST_ROWS) a.lscroll = i - LIST_ROWS + 1;
};

fn pick_season(a: *app, s: size) void = {
	a.season = s;
	a.gscroll = 0;
	a.lscroll = 0;
	const se = ENTRIES[a.ent].seasons[s];
	// The first one not seen in it, else its first.
	a.sel = se.first;
	for (let i = 0z; i < se.n; i += 1) {
		if (a.p.seen[a.ent][se.first + i] == 0) {
			a.sel = se.first + i;
			break;
		};
	};
	show_sel(a);
};

fn show_series(a: *app, e: size) void = {
	a.ent = e;
	a.gscroll = 0;
	a.lscroll = 0;
	go_next(a);
};

fn toggle(a: *app, e: size, i: size) void = {
	a.p.seen[e][i] = if (a.p.seen[e][i] == 0) now() else 0;
	save(&a.p);
	let b: [160]u8 = [0...];
	const seen = a.p.seen[e][i] != 0;
	if (ENTRIES[e].film) {
		say(a, fmt::bsprintf(b, "{} er {}.", cut(ENTRIES[e].name, 60),
			if (seen) "markeret som set" else "ikke set alligevel")!);
	} else {
		const s = season_of(e, i);
		const se = ENTRIES[e].seasons[s];
		let sb: [32]u8 = [0...];
		say(a, fmt::bsprintf(b, "{}, episode {} er {}.", season_name(sb, se.label),
			i - se.first + 1, if (seen) "markeret som set" else "ikke set alligevel")!);
	};
};

// Returns true to quit.
fn keys(win: *viper::window, a: *app) bool = {
	// Typing in a field: the keys are the field's (Esc leaves it).
	if (a.mail_tb.focused || a.pass_tb.focused) {
		if (viper::key_pressed(win, viper::key::ESCAPE)) {
			a.mail_tb.focused = false;
			a.pass_tb.focused = false;
		};
		return false;
	};
	if (viper::key_pressed(win, viper::key::ESCAPE)) return true;
	if (viper::key_pressed(win, viper::key::TAB)) {
		a.pg = ((a.pg: int + 1) % (page::ABOUT: int + 1)): page;
	};
	if (ENTRIES[a.ent].film) return false;
	const se = ENTRIES[a.ent].seasons[a.season];
	let i = (a.sel - se.first): int;
	const n = se.n: int;
	if (viper::key_pressed(win, viper::key::RIGHT)) i += 1;
	if (viper::key_pressed(win, viper::key::LEFT)) i -= 1;
	const step = if (a.pg == page::SERIES) 1 else 5;
	if (viper::key_pressed(win, viper::key::DOWN)) i += step;
	if (viper::key_pressed(win, viper::key::UP)) i -= step;
	if (i < 0) i = 0;
	if (i >= n) i = n - 1;
	if (se.first + i: size != a.sel) {
		a.sel = se.first + i: size;
		show_sel(a);
	};
	if (viper::key_pressed(win, viper::key::SPACE)) toggle(a, a.ent, a.sel);
	const ns = len(ENTRIES[a.ent].seasons);
	for (let k = 0z; k < 9 && k < ns; k += 1) {
		if (viper::key_pressed(win, (30 + k: int): viper::key)) pick_season(a, k);
	};
	return false;
};

// ---- Little helpers ----

fn hit(win: *viper::window, x: int, y: int, w: int, h: int) bool = {
	const (mx, my) = viper::mouse(win);
	return mx >= x && mx < x + w && my >= y && my < y + h;
};

fn clicked(win: *viper::window, x: int, y: int, w: int, h: int) bool =
	viper::mouse_pressed(win) && hit(win, x, y, w, h);

// Over the mockup: paints a box (mockup pixels) row by row with the
// mockup's own colour at column sx, so gradients stay.
fn paint(win: *viper::window, a: *app, x: int, y: int, w: int, h: int, sx: int) void = {
	if (!a.skin) return;
	const px = X(sx);
	for (let r = Y(y); r < Y(y + h) && r < H; r += 1) {
		if (r < 0) continue;
		viper::rect(win, X(x), r, L(w), 1, a.bg.pixels[r * W + px]);
	};
};

fn upper(s: str) str = ascii::strupper(s)!;

// s, cut to n characters.
fn cut(s: str, n: size) str = {
	let it = strings::iter(s);
	for (let i = 0z; i < n; i += 1) {
		match (strings::next(&it)) {
		case rune => void;
		case done => return s;
		};
	};
	return strings::sub(s, 0, n);
};

// Splits s into lines no wider than w pixels (at scale 1); returns how
// many. A word too long for a line gets a line of its own.
fn wrap(s: str, w: int, out: []str) size = {
	const b = strings::toutf8(s);
	const maxc = w / 8;   // the font is 8 pixels wide
	let n = 0z, start = 0z;
	for (n < len(out)) {
		for (start < len(b) && b[start] == ' ') start += 1;
		if (start >= len(b)) break;
		let end = start, runes = 0, j = start;
		for (j < len(b)) {
			let k = j;
			for (k < len(b) && b[k] != ' ') k += 1;
			const wr = runes_in(b[j..k]);
			const need = if (end == start) wr else runes + 1 + wr;
			if (need > maxc && end != start) break;
			runes = need;
			end = k;
			j = k;
			for (j < len(b) && b[j] == ' ') j += 1;
			if (need > maxc) break;
		};
		out[n] = strings::fromutf8_unsafe(b[start..end]);
		n += 1;
		start = end;
	};
	return n;
};

fn runes_in(b: []u8) int = {
	let n = 0;
	for (let c .. b) if (c & 0xC0 != 0x80) n += 1;
	return n;
};

fn when(buf: []u8, t: i64) str = {
	const d = date::from_instant(date::LOCAL, time::instant { sec = t, nsec = 0 });
	const today = date::localnow();
	const months = ["jan", "feb", "mar", "apr", "maj", "jun",
		"jul", "aug", "sep", "okt", "nov", "dec"];
	if (date::year(&d) == date::year(&today) && date::month(&d) == date::month(&today)
			&& date::day(&d) == date::day(&today)) {
		return fmt::bsprintf(buf, "i dag kl. {:_02}:{:_02}", date::hour(&d), date::minute(&d))!;
	};
	return fmt::bsprintf(buf, "{}. {} kl. {:_02}:{:_02}", date::day(&d),
		months[date::month(&d) - 1], date::hour(&d), date::minute(&d))!;
};

// A button with text (and an icon); true when clicked. Over the mockup
// with `fixed` set only a glow is drawn: the button is in the picture.
fn btn(win: *viper::window, a: *app, x: int, y: int, w: int, h: int, label: str,
		ic: (icon | void), fixed: bool) bool = {
	const over = hit(win, X(x), Y(y), L(w), L(h));
	if (!(a.skin && fixed)) {
		viper::round_rect(win, X(x), Y(y), L(w), L(h), 9, if (over) C_YEL_HI else C_YELLOW);
		viper::round_rect(win, X(x) + 2, Y(y) + 2, L(w) - 4, L(h) - 4, 8,
			if (over) 0xff16245e else C_DEEP);
		const iw = match (ic) { case icon => yield 30; case void => yield 0; };
		const tw = viper::text_width(label, 1) + iw;
		const tx = X(x) + (L(w) - tw) / 2, cy = Y(y) + L(h) / 2;
		match (ic) {
		case let i: icon => draw_icon(win, i, tx + 11, cy, C_TEXT);
		case void => void;
		};
		bold(win, tx + iw, cy - 8, label, C_TEXT);
	} else if (over) {
		viper::outline(win, X(x) - 2, Y(y) - 2, L(w) + 4, L(h) + 4, C_YEL_HI);
	};
	return over && viper::mouse_pressed(win);
};

fn bar(win: *viper::window, x: int, y: int, w: int, h: int, f: f64) void = {
	viper::round_rect(win, x, y, w, h, h / 2, C_TRACK);
	const fw = (w: f64 * (if (f > 1.0) 1.0 else f)): int;
	if (fw > 0) {
		viper::round_rect(win, x, y, if (fw < h) h else fw, h, h / 2, C_CYAN);
		viper::round_rect(win, x + 2, y + 1, (if (fw < h) h else fw) - 4, h / 3, h / 6, 0xff7fd8ff);
	};
};

// ---- Drawing ----

fn draw(win: *viper::window, a: *app) void = {
	if (a.skin) {
		viper::draw_image(win, &a.bg, 0, 0);
	} else {
		draw_frame(win, a);
	};
	draw_side(win, a);
	// The page's title.
	paint(win, a, 262, 232, 600, 52, 250);
	const name = switch (a.pg) {
	case page::OVERVIEW => yield "Oversigt";
	case page::SERIES => yield ENTRIES[a.ent].name;
	case page::FILMS => yield "Film";
	case page::STATS => yield "Statistik";
	case page::SYNC => yield "Synkronisering";
	case page::SETTINGS => yield "Indstillinger";
	case page::ABOUT => yield "Om";
	};
	viper::clip(win, X(262), Y(232), L(1240), L(52));
	bold2(win, X(270), Y(240), name, C_TEXT);
	viper::noclip(win);
	if (a.pg != page::OVERVIEW) {
		// The mockup's overview goes; this page's own panel comes.
		paint(win, a, 248, 286, 1262, 640, 248);
	};
	switch (a.pg) {
	case page::OVERVIEW =>
		draw_cards(win, a);
		draw_panel(win, a);
	case page::SERIES => draw_series(win, a);
	case page::FILMS => draw_films(win, a);
	case page::STATS => draw_stats(win, a);
	case page::SYNC => draw_sync(win, a);
	case page::SETTINGS => draw_settings(win, a);
	case page::ABOUT => draw_about(win, a);
	};
	draw_footer(win, a);
	draw_message(win, a);
};

// What the mockup has painted in already.
fn draw_frame(win: *viper::window, a: *app) void = {
	vgrad(win, 0, 0, W, H, 0xff0a1340, 0xff050a24);
	// The sidebar.
	vgrad(win, 0, 0, X(232), H, 0xff0a0f36, 0xff070a26);
	viper::rect(win, X(232), 0, 2, H, 0xff1b2a8a);
	bolt(win, X(20), Y(760), L(190), L(240), 0xff8a6a08);
	bolt(win, X(28), Y(770), L(170), L(220), C_YELLOW);
	// The logo.
	for (let d = 0; d < 5; d += 1) {
		viper::line(win, X(24) + d, Y(80), X(36) + d, Y(110), C_CYAN);
		viper::line(win, X(36) + d, Y(110), X(52) + d, Y(80), 0xff6b4dff);
	};
	bold2(win, X(62), Y(80), "ViperGui", C_TEXT);
	let lines: [2]str = [""...];
	const n = wrap(TITLE, L(190), lines);
	for (let i = 0z; i < n; i += 1) viper::text(win, X(34), Y(132) + i: int * 18, lines[i], C_DIM);
	viper::text(win, X(34), Y(132) + n: int * 18, "v0.1.0", C_DIM);
	// The banner and the big panel.
	draw_banner(win, X(234), Y(42), W - X(234), L(180), NAME);
	viper::rect(win, X(234), Y(222), W - X(234), 2, C_BORDER);
	glass(win, X(234), Y(226), L(1286), L(704), 12, 0xff0c1a4c);
	glass(win, X(234), Y(941), L(1286), L(80), 12, 0xff0c1a4c);
};

type item = struct {
	label: str,
	ic: icon,
	pg: page,
	ent: size,
};

// The menu: the overview, each series, the films, then the rest.
fn menu(out: []item) size = {
	let n = 0z;
	out[n] = item { label = "Oversigt", ic = icon::HOME, pg = page::OVERVIEW, ... };
	n += 1;
	let films = false;
	for (let e = 0z; e < len(ENTRIES) && n < 5; e += 1) {
		if (ENTRIES[e].film) {
			films = true;
			continue;
		};
		out[n] = item { label = side_name(e), ic = icon::TV, pg = page::SERIES, ent = e };
		n += 1;
	};
	for (let e = 0z; e < len(ENTRIES); e += 1) if (ENTRIES[e].film) films = true;
	if (films) {
		out[n] = item { label = "Film", ic = icon::FILM, pg = page::FILMS, ... };
		n += 1;
	};
	out[n] = item { label = "Statistik", ic = icon::STATS, pg = page::STATS, ... };
	out[n + 1] = item { label = "Synkronisering (MEGA.nz)", ic = icon::CLOUD, pg = page::SYNC, ... };
	out[n + 2] = item { label = "Indstillinger", ic = icon::COG, pg = page::SETTINGS, ... };
	out[n + 3] = item { label = "Om", ic = icon::INFO, pg = page::ABOUT, ... };
	return n + 4;
};

// "The Family" -> "The Family (Serie)"; "The Family: Next" -> "Next".
let side_buf: [MAXENT][128]u8 = [[0...]...];

fn side_name(e: size) str = {
	const name = ENTRIES[e].name;
	if (name == NAME) {
		const s = fmt::bsprintf(side_buf[e], "{} (Serie)", cut(name, 100))!;
		return s;
	};
	if (strings::hasprefix(name, NAME) && len(name) > len(NAME)) {
		const rest = strings::ltrim(strings::trimprefix(name, NAME), ':', ' ', '-');
		if (len(rest) > 0) return rest;
	};
	return name;
};

fn draw_side(win: *viper::window, a: *app) void = {
	paint(win, a, 0, 214, 230, 500, 5);
	let items: [10]item = [item { ... }...];
	const n = menu(items);
	for (let i = 0z; i < n; i += 1) {
		const it = items[i];
		const y = 222 + i: int * 60;
		const on = a.pg == it.pg && (it.pg != page::SERIES || a.ent == it.ent);
		const over = hit(win, X(10), Y(y), L(214), L(52));
		if (on) {
			viper::round_rect(win, X(10), Y(y), L(214), L(52), 8, C_YELLOW);
			viper::round_rect(win, X(10), Y(y), L(214), L(22), 8, C_YEL_HI);
			viper::rect(win, X(10), Y(y) + L(14), L(214), L(10), mix(C_YEL_HI, C_YELLOW, 0.5));
		} else if (over) {
			viper::round_rect(win, X(10), Y(y), L(214), L(52), 8, 0xff16225e);
		};
		const col = if (on) C_INK else C_TEXT;
		draw_icon(win, it.ic, X(40), Y(y) + L(26), col);
		let lines: [2]str = [""...];
		const k = wrap(it.label, X(228) - X(70), lines);
		for (let j = 0z; j < k; j += 1) {
			const ty = Y(y) + L(26) - k: int * 9 + j: int * 18;
			if (on) bold(win, X(70), ty, lines[j], col) else viper::text(win, X(70), ty, lines[j], col);
		};
		if (over && viper::mouse_pressed(win)) {
			a.pg = it.pg;
			if (it.pg == page::SERIES && a.ent != it.ent) show_series(a, it.ent);
		};
	};
};

// ---- The overview: three cards and the series panel ----

const CARDS: [3](int, int) = [(260, 410), (690, 393), (1103, 410)];

fn draw_cards(win: *viper::window, a: *app) void = {
	let b: [64]u8 = [0...];
	for (let c = 0z; c < 3 && c < len(ENTRIES); c += 1) {
		const e = ENTRIES[c];
		const (cx, cw) = CARDS[c];
		const tx = cx + 166;
		if (!a.skin) {
			glass(win, X(cx), Y(290), L(cw), L(182), 10, C_CARD);
			show_cover(win, a, c, false, X(cx + 13), Y(300), L(132), L(160));
		};
		paint(win, a, tx - 6, 298, cx + cw - tx - 6, 166, tx - 8);
		// The name.
		let lines: [2]str = [""...];
		const n = wrap(e.name, L(cx + cw - tx - 16), lines);
		for (let j = 0z; j < n; j += 1) {
			bold(win, X(tx), Y(n: int * -13 + 335) + j: int * 20, lines[j], C_TEXT);
		};
		if (e.film) {
			viper::text(win, X(tx), Y(372), fmt::bsprintf(b, "Film  ·  {}", e.year)!, C_DIM);
			const seen = a.p.seen[c][0] != 0;
			if (seen) {
				ok_badge(win, X(tx + 16), Y(429));
			} else {
				viper::circle(win, X(tx + 16), Y(429), 11, C_DIM);
				viper::circle(win, X(tx + 16), Y(429), 9, C_CARD);
			};
			bold(win, X(tx + 40), Y(429) - 8, if (seen) "Set" else "Ikke set", C_TEXT);
		} else {
			const ns = len(e.seasons), total = nep(c);
			viper::text(win, X(tx), Y(372), fmt::bsprintf(b, "{} {}  ·  {} afs.", ns,
				if (ns == 1) "sæson" else "sæsoner", total)!, C_DIM);
			const s = nseen(&a.p, c);
			bar(win, X(tx), Y(402), L(cw - 166 - 26), L(15), s: f64 / total: f64);
			bold(win, X(tx), Y(430), fmt::bsprintf(b, "{} / {} ({} %)", s, total,
				s * 100 / total: int)!, C_TEXT);
		};
		if (clicked(win, X(cx), Y(290), L(cw), L(182))) {
			if (e.film) toggle(a, c, 0) else show_series(a, c);
		};
	};
};

fn draw_panel(win: *viper::window, a: *app) void = {
	const e = a.ent;
	const ent = ENTRIES[e];
	if (!a.skin) glass(win, X(260), Y(495), L(1253), L(420), 12, 0xff0a1648);
	// The header.
	paint(win, a, 286, 505, 764, 44, 275);
	draw_icon(win, icon::TV, X(307), Y(525), C_TEXT);
	let hb: [160]u8 = [0...];
	viper::clip(win, X(340), Y(505), L(710), L(44));
	bold2(win, X(345), Y(510), if (ent.name == NAME) side_name(e) else ent.name, C_TEXT);
	viper::noclip(win);
	// The season's progress, right.
	const se = ent.seasons[a.season];
	const s = nseen_season(&a.p, e, a.season);
	paint(win, a, 1062, 506, 440, 70, 1063);
	viper::text(win, X(1070), Y(518), fmt::bsprintf(hb, "{} episoder", se.n)!, C_TEXT);
	const right = fmt::bsprintf(hb, "{} / {} ({} %)", s, se.n, s * 100 / se.n: int)!;
	bold(win, X(1488) - viper::text_width(right, 1), Y(518), right, C_TEXT);
	bar(win, X(1070), Y(547), L(418), L(21), s: f64 / se.n: f64);
	// Tabs and the grid.
	paint(win, a, 276, 550, 776, 356, 275);
	tabs(win, a, 289, 555, 751);
	grid(win, a);
	detail(win, a, 1060, 595, 305, true);
};

fn tabs(win: *viper::window, a: *app, x: int, y: int, room: int) void = {
	const ss = ENTRIES[a.ent].seasons;
	const n = len(ss): int;
	const tw = if ((room + 11) / n - 11 < 157) (room + 11) / n - 11 else 157;
	let b: [32]u8 = [0...];
	for (let i = 0; i < n; i += 1) {
		const tx = x + i * (tw + 11);
		const on = a.season == i: size;
		const over = hit(win, X(tx), Y(y), L(tw), L(46));
		viper::round_rect(win, X(tx), Y(y), L(tw), L(46), 8,
			if (on) C_YELLOW else if (over) 0xff26357c else 0xff1b2763);
		if (on) viper::round_rect(win, X(tx), Y(y), L(tw), L(18), 8, C_YEL_HI);
		let label = season_name(b, ss[i].label);
		if (viper::text_width(label, 1) > L(tw) - 8) label = ss[i].label;
		const lw = viper::text_width(label, 1);
		const col = if (on) C_INK else C_TEXT;
		bold(win, X(tx) + (L(tw) - lw) / 2, Y(y) + L(46) / 2 - 8, label, col);
		if (over && viper::mouse_pressed(win)) pick_season(a, i: size);
	};
};

fn grid(win: *viper::window, a: *app) void = {
	const e = a.ent;
	const se = ENTRIES[e].seasons[a.season];
	const rows = (se.n: int + 4) / 5;
	if (hit(win, X(280), Y(615), L(770), L(270))) a.gscroll -= viper::wheel(win);
	if (a.gscroll > rows - 4) a.gscroll = rows - 4;
	if (a.gscroll < 0) a.gscroll = 0;
	let b: [8]u8 = [0...];
	for (let r = 0; r < 4; r += 1) for (let c = 0; c < 5; c += 1) {
		const k = (a.gscroll + r) * 5 + c;
		if (k >= se.n: int) continue;
		const i = se.first + k: size;
		const x = X(289 + c * 151), y = Y(623 + r * 66), w = L(139), h = L(51);
		const seen = a.p.seen[e][i] != 0;
		const over = hit(win, x, y, w, h);
		if (i == a.sel) viper::round_rect(win, x - 3, y - 3, w + 6, h + 6, 10, C_YEL_HI);
		if (seen) {
			viper::round_rect(win, x, y, w, h, 8, 0xff6fd2ff);
			viper::round_rect(win, x + 1, y + 1, w - 2, h - 2, 8, C_SEEN_DK);
			vgrad(win, x + 3, y + 2, w - 6, h / 2, if (over) 0xff4cc4ff else C_SEEN, C_SEEN_DK);
		} else {
			viper::round_rect(win, x, y, w, h, 8, if (over) 0xff4a5aa8 else 0xff2c3a82);
			viper::round_rect(win, x + 2, y + 2, w - 4, h - 4, 7, if (over) 0xff1d2c6c else C_UNSEEN);
		};
		const num = fmt::bsprintf(b, "{}", k + 1)!;
		const nw = viper::text_width(num, 2);
		if (seen) {
			bold2(win, x + w / 2 - nw - 4, y + (h - 32) / 2, num, C_TEXT);
			draw_icon(win, icon::CHECK, x + w / 2 + 20, y + h / 2, C_TEXT);
		} else {
			bold2(win, x + (w - nw) / 2, y + (h - 32) / 2, num, 0xffc9d3f5);
		};
		if (over && viper::mouse_pressed(win)) {
			if (i == a.sel) toggle(a, e, i) else a.sel = i;
		};
	};
	if (rows > 4) {
		const th = L(4 * 66 - 15);
		const bh = th * 4 / rows, by = Y(623) + (th - bh) * a.gscroll / (rows - 4);
		viper::round_rect(win, X(1040), by, 4, bh, 2, C_CYAN);
	};
};

// The picked episode: a picture, its name, what it is about, and the
// button. `photo`: over the mockup its picture stays.
fn detail(win: *viper::window, a: *app, x: int, y: int, h: int, photo: bool) void = {
	const e = a.ent, i = a.sel;
	const ep = ENTRIES[e].eps[i];
	const s = season_of(e, i);
	const se = ENTRIES[e].seasons[s];
	if (!a.skin || !photo) {
		glass(win, X(x), Y(y), L(452), L(h), 10, 0xff081750);
		vgrad(win, X(x + 15), Y(y + 12), L(422), L(113), 0xff2847b8, 0xff0a1450);
		bolt(win, X(x + 30), Y(y + 18), L(60), L(100), C_YELLOW);
		let nb: [8]u8 = [0...];
		const num = fmt::bsprintf(nb, "{}", i - se.first + 1)!;
		loud_text(win, X(x + 430) - viper::text_width(num, 4), Y(y + 40), num, 4, C_YEL_HI);
	};
	if (photo) paint(win, a, x + 8, y + 131, 432, h - 136, x + 8);
	const tx = X(x + 17);
	let b: [64]u8 = [0...], sb: [32]u8 = [0...];
	viper::text(win, tx, Y(y + 138), fmt::bsprintf(b, "{}  ·  Episode {}",
		season_name(sb, se.label), i - se.first + 1)!, C_DIM);
	viper::clip(win, tx, Y(y + 156), L(420), 22);
	bold(win, tx, Y(y + 162), ep.title, C_TEXT);
	viper::noclip(win);
	// What it is about, or when it was on.
	let lines: [3]str = [""...];
	const about = if (len(ep.desc) > 0) ep.desc else "";
	const n = wrap(about, L(420), lines);
	for (let j = 0z; j < n && j < 2; j += 1) {
		viper::text(win, tx, Y(y + 192) + j: int * 18, lines[j], C_DIM);
	};
	const seen = a.p.seen[e][i];
	let wb: [48]u8 = [0...];
	const info = if (seen != 0) fmt::bsprintf(b, "Sendt {}  ·  set {}", ep.aired, when(wb, seen))!
		else fmt::bsprintf(b, "Sendt {}", ep.aired)!;
	viper::text(win, tx, Y(y + 192) + (if (n > 0) 40 else 0), info,
		if (seen != 0) C_GREEN else C_DIM);
	if (btn(win, a, x + 16, y + h - 59, 411, 47,
			if (seen != 0) "Markér som ikke set" else "Markér som set", icon::EYE, false)) {
		toggle(a, e, i);
	};
};

// ---- A series, as a list ----

def LIST_ROWS: int = 12;

fn draw_series(win: *viper::window, a: *app) void = {
	const e = a.ent;
	glass(win, X(260), Y(295), L(785), L(620), 12, 0xff0a1648);
	tabs(win, a, 280, 308, 750);
	const se = ENTRIES[e].seasons[a.season];
	if (hit(win, X(270), Y(365), L(770), L(LIST_ROWS * 44))) a.lscroll -= viper::wheel(win);
	const maxs = if (se.n: int > LIST_ROWS) se.n: int - LIST_ROWS else 0;
	if (a.lscroll > maxs) a.lscroll = maxs;
	if (a.lscroll < 0) a.lscroll = 0;
	let b: [16]u8 = [0...];
	for (let r = 0; r < LIST_ROWS && a.lscroll + r < se.n: int; r += 1) {
		const k = a.lscroll + r;
		const i = se.first + k: size;
		const y = Y(368 + r * 44), x = X(280), w = L(750), h = L(40);
		const seen = a.p.seen[e][i] != 0;
		const over = hit(win, x, y, w, h);
		if (i == a.sel) {
			viper::round_rect(win, x - 2, y - 2, w + 4, h + 4, 8, C_YEL_HI);
			viper::round_rect(win, x, y, w, h, 7, 0xff1d2c6c);
		} else {
			viper::round_rect(win, x, y, w, h, 7, if (over) 0xff1a2866 else 0xff111d55);
		};
		bold(win, x + 12, y + (h - 16) / 2, fmt::bsprintf(b, "{:_02}", k + 1)!, C_YEL_HI);
		viper::clip(win, x + 50, y, L(470), h);
		viper::text(win, x + 50, y + (h - 16) / 2, ENTRIES[e].eps[i].title, C_TEXT);
		viper::noclip(win);
		viper::text(win, x + L(530), y + (h - 16) / 2, ENTRIES[e].eps[i].aired, C_DIM);
		// The tick.
		const cx = x + w - 26, cy = y + h / 2;
		if (seen) {
			ok_badge(win, cx, cy);
		} else {
			viper::circle(win, cx, cy, 11, 0xff4a5aa8);
			viper::circle(win, cx, cy, 9, 0xff111d55);
		};
		if (clicked(win, cx - 20, y, 40, h)) {
			toggle(a, e, i);
		} else if (over && viper::mouse_pressed(win)) {
			a.sel = i;
		};
	};
	if (maxs > 0) {
		const th = L(LIST_ROWS * 44 - 4);
		const bh = th * LIST_ROWS / se.n: int, by = Y(368) + (th - bh) * a.lscroll / maxs;
		viper::round_rect(win, X(1036), by, 4, bh, 2, C_CYAN);
	};
	// Right: the progress per season, and the picked episode.
	glass(win, X(1060), Y(295), L(452), L(290), 12, 0xff0a1648);
	const all = nseen(&a.p, e);
	let hb: [64]u8 = [0...], sb: [32]u8 = [0...];
	bold(win, X(1078), Y(310), "Fremgang", C_TEXT);
	const right = fmt::bsprintf(hb, "{} / {}", all, nep(e))!;
	bold(win, X(1494) - viper::text_width(right, 1), Y(310), right, C_TEXT);
	const ss = ENTRIES[e].seasons;
	const step = if (len(ss) > 5) 230 / len(ss): int else 46;
	for (let s = 0z; s < len(ss) && s < 10; s += 1) {
		const y = Y(345 + s: int * step);
		const n = nseen_season(&a.p, e, s);
		viper::text(win, X(1078), y, season_name(sb, ss[s].label), C_DIM);
		const t = fmt::bsprintf(hb, "{}/{}", n, ss[s].n)!;
		viper::text(win, X(1494) - viper::text_width(t, 1), y, t, C_DIM);
		bar(win, X(1078), y + 18, L(416), 8, n: f64 / ss[s].n: f64);
	};
	detail(win, a, 1060, 600, 315, false);
};

// ---- Films ----

fn draw_films(win: *viper::window, a: *app) void = {
	glass(win, X(260), Y(295), L(1253), L(620), 12, 0xff0a1648);
	let k = 0;
	let b: [96]u8 = [0...], wb: [48]u8 = [0...];
	for (let e = 0z; e < len(ENTRIES); e += 1) {
		const ent = ENTRIES[e];
		if (!ent.film) continue;
		const x = 280, y = 315 + k * 245, w = 1213, h = 230;
		k += 1;
		if (y + h > 915) break;
		glass(win, X(x), Y(y), L(w), L(h), 12, C_CARD);
		show_cover(win, a, e, true, X(x + 15), Y(y + 15), L(164), L(200));
		const tx = X(x + 205);
		let lines: [2]str = [""...];
		const n = wrap(ent.name, L(w - 205 - 300) / 2, lines);
		for (let j = 0z; j < n; j += 1) bold2(win, tx, Y(y + 22) + j: int * 34, lines[j], C_TEXT);
		let ty = Y(y + 22) + n: int * 34 + 8;
		viper::text(win, tx, ty, fmt::bsprintf(b, "Film  ·  {}  ·  {} min", ent.year, ent.minutes)!, C_DIM);
		ty += 22;
		if (len(ent.aired) > 0) {
			viper::text(win, tx, ty, fmt::bsprintf(b, "Premiere {}", ent.aired)!, C_DIM);
			ty += 22;
		};
		const seen = a.p.seen[e][0];
		if (seen != 0) {
			ok_badge(win, tx + 11, ty + 18);
			viper::text(win, tx + 30, ty + 10, fmt::bsprintf(b, "Set {}", when(wb, seen))!, C_GREEN);
		} else {
			viper::text(win, tx, ty + 10, "Ikke set endnu", C_DIM);
		};
		if (btn(win, a, x + w - 280, y + h - 75, 260, 52,
				if (seen != 0) "Markér som ikke set" else "Markér som set", icon::EYE, false)) {
			toggle(a, e, 0);
		};
	};
	if (k == 0) viper::text(win, X(290), Y(320), "Ingen film i samling.txt.", C_DIM);
};

// ---- Statistics ----

fn draw_stats(win: *viper::window, a: *app) void = {
	glass(win, X(260), Y(295), L(1253), L(620), 12, 0xff0a1648);
	let b: [96]u8 = [0...];
	// Totals.
	let seen = 0, all = 0;
	for (let e = 0z; e < len(ENTRIES); e += 1) {
		seen += nseen(&a.p, e);
		all += nep(e): int;
	};
	const m = minutes_seen(&a.p);
	const tiles: [3](str, str) = [
		("Set i alt", fmt::bsprintf(b, "{} af {}", seen, all)!),
		("", ""), ("", ""),
	];
	let b2: [48]u8 = [0...], b3: [48]u8 = [0...];
	const t2 = fmt::bsprintf(b2, "{} t {} min", m / 60, m % 60)!;
	let left = 0;
	for (let e = 0z; e < len(ENTRIES); e += 1) {
		const per = if (ENTRIES[e].film) ENTRIES[e].minutes else EP_MIN;
		left += (nep(e): int - nseen(&a.p, e)) * per;
	};
	const t3 = fmt::bsprintf(b3, "{} t {} min", left / 60, left % 60)!;
	const vals: [3](str, str) = [tiles[0], ("Tid brugt", t2), ("Tilbage", t3)];
	for (let i = 0; i < 3; i += 1) {
		const x = X(285 + i * 405);
		viper::round_rect(win, x, Y(315), L(385), L(90), 10, 0xff13216a);
		viper::text(win, x + 16, Y(327), vals[i].0, C_DIM);
		bold2(win, x + 16, Y(352), vals[i].1, C_YEL_HI);
	};
	// One bar per series or film.
	let y = Y(440);
	for (let e = 0z; e < len(ENTRIES) && y < Y(860); e += 1) {
		const n = nseen(&a.p, e), t = nep(e): int;
		viper::clip(win, X(285), y, L(520), 20);
		bold(win, X(285), y, ENTRIES[e].name, C_TEXT);
		viper::noclip(win);
		bar(win, X(820), y + 2, L(500), 12, n: f64 / t: f64);
		const s = fmt::bsprintf(b, "{} / {}", n, t)!;
		viper::text(win, X(1490) - viper::text_width(s, 1), y, s, C_DIM);
		y += 34;
	};
	// The last ones seen.
	viper::text(win, X(285), y + 14, "Senest set", C_DIM);
	y += 36;
	let shown: [5](size, size, i64) = [(0, 0, 0)...];
	for (let e = 0z; e < len(ENTRIES); e += 1) for (let i = 0z; i < nep(e); i += 1) {
		const t = a.p.seen[e][i];
		for (let k = 0z; k < len(shown); k += 1) {
			if (t > shown[k].2) {
				for (let j = len(shown) - 1; j > k; j -= 1) shown[j] = shown[j - 1];
				shown[k] = (e, i, t);
				break;
			};
		};
	};
	let wb: [48]u8 = [0...], sb: [32]u8 = [0...];
	for (let k = 0z; k < len(shown) && shown[k].2 != 0 && y < Y(905); k += 1) {
		const (e, i, t) = shown[k];
		const what = if (ENTRIES[e].film) ENTRIES[e].name else {
			const se = ENTRIES[e].seasons[season_of(e, i)];
			yield fmt::bsprintf(b, "{}  {} E{:_02}  {}", cut(ENTRIES[e].name, 30),
				season_name(sb, se.label), i - se.first + 1, cut(ENTRIES[e].eps[i].title, 34))!;
		};
		viper::clip(win, X(285), y, L(1000), 18);
		viper::text(win, X(285), y, what, C_TEXT);
		viper::noclip(win);
		const ws = when(wb, t);
		viper::text(win, X(1490) - viper::text_width(ws, 1), y, ws, C_DIM);
		y += 22;
	};
};

// ---- MEGA ----

fn sync_status(a: *app) str = strings::fromutf8_unsafe(a.sync[..a.slen]);

fn check_sync(a: *app) void = {
	let out: [48]u8 = [0...];
	const st = mega_status(out);
	a.slen = copy_utf8(a.sync, st);
	a.sync_checked = true;
	if (st == "Synced") {
		a.p.synced = now();
		save(&a.p);
		say(a, "MEGA: alt er synkroniseret.");
	} else {
		let b: [96]u8 = [0...];
		say(a, fmt::bsprintf(b, "MEGA: {}", st)!);
	};
	// Pick up what another machine may have marked.
	const keep = a.p.synced;
	load(&a.p);
	a.p.synced = keep;
};

fn do_login(a: *app) void = {
	const mail = strings::trim(viper::textinput_str(&a.mail_tb));
	const pass = viper::textinput_str(&a.pass_tb);
	if (len(mail) == 0 || len(pass) == 0) {
		say(a, "Skriv både mail og adgangskode.");
		return;
	};
	say(a, "Logger ind på MEGA ...");
	let out: [120]u8 = [0...];
	const r = mega_login(out, mail, pass);
	// The password is not kept.
	a.pass_tb.buf = [0...];
	a.pass_tb.length = 0;
	a.pass_tb.focused = false;
	match (r) {
	case void => check_sync(a);
	case let e: str =>
		let b: [160]u8 = [0...];
		say(a, fmt::bsprintf(b, "MEGA: {}", e)!);
	};
};

fn do_setup(a: *app) void = {
	let out: [120]u8 = [0...];
	match (mega_setup(out)) {
	case void => check_sync(a);
	case let e: str =>
		let b: [160]u8 = [0...];
		say(a, fmt::bsprintf(b, "MEGA: {}", e)!);
	};
};

// A text field that shows stars.
fn password_box(win: *viper::window, tb: *viper::textinput, x: int, y: int, w: int) bool = {
	const enter = viper::textbox(win, tb, x, y, w, "Adgangskode");
	if (tb.length == 0) return enter;
	viper::rect(win, x + 1, y + 1, w - 2, 28, win.theme.widget_hot);
	let n = 0;
	for (let c .. tb.buf[..tb.length]) if (c & 0xC0 != 0x80) n += 1;
	for (let i = 0; i < n && 8 + i * 10 < w - 16; i += 1) viper::circle(win, x + 12 + i * 10, y + 15, 3, C_TEXT);
	return enter;
};

fn draw_sync(win: *viper::window, a: *app) void = {
	glass(win, X(260), Y(295), L(1253), L(620), 12, 0xff0a1648);
	if (!a.sync_checked) check_sync(a);
	const x = X(290);
	let b: [256]u8 = [0...];
	bold(win, x, Y(320), "Fremgangen gemmes i denne mappe, og MEGA holder den i sync:", C_TEXT);
	const dir = match (save_dir()) {
	case let d: str => yield d;
	case void => yield strings::dup("?")!;
	};
	defer free(dir);
	viper::text(win, x + 20, Y(350), dir, C_YEL_HI);
	const st = sync_status(a);
	const good = st == "Synced";
	if (good) ok_badge(win, x + 11, Y(400) + 8) else draw_icon(win, icon::CLOUD, x + 11, Y(400) + 8, C_DIM);
	bold(win, x + 30, Y(400), fmt::bsprintf(b, "Status: {}", st)!, if (good) C_GREEN else C_TEXT);
	const y = Y(445);
	if (st == NO_MEGA) {
		viper::text(win, x, y, "Installér MEGAcmd først (hent .deb'en fra mega.io/cmd):", C_DIM);
		viper::text(win, x + 20, y + 22, "sudo apt install ./megacmd-*.deb", C_TEXT);
		if (btn(win, a, 290, 530, 260, 50, "Tjek igen", icon::CLOUD, false)) check_sync(a);
	} else if (st == NOT_LOGGED_IN) {
		bold(win, x, y, "Log ind på MEGA:", C_TEXT);
		viper::textbox(win, &a.mail_tb, x, y + 26, L(520), "Mail");
		const enter = password_box(win, &a.pass_tb, x, y + 64, L(520));
		if (btn(win, a, 290, 590, 260, 50, "Log ind", icon::CLOUD, false) || enter) do_login(a);
		viper::text(win, x + L(540), y + 33, "Adgangskoden bliver ikke gemt;", C_DIM);
		viper::text(win, x + L(540), y + 55, "MEGAcmd husker selv, at du er logget ind.", C_DIM);
	} else if (st == NOT_SYNCED) {
		viper::text(win, x, y, "Mappen er ikke sat op hos MEGA endnu. Så laves /Samling på MEGA,", C_DIM);
		viper::text(win, x, y + 20, "og mappen her holdes i sync med den:", C_DIM);
		if (btn(win, a, 290, 530, 330, 50, "Opsæt synkronisering", icon::CLOUD, false)) do_setup(a);
	} else {
		viper::text(win, x, y, "MEGA holder mappen i sync i baggrunden, også når Samling er lukket.", C_DIM);
		if (btn(win, a, 290, 520, 260, 50, "Tjek nu", icon::CLOUD, false)) check_sync(a);
	};
	viper::text(win, x, Y(800), "Læg samling.txt, skin.png og cover-*.png i mappen, så følger de", C_DIM);
	viper::text(win, x, Y(800) + 20, "med til dine andre maskiner.", C_DIM);
};

fn draw_footer(win: *viper::window, a: *app) void = {
	paint(win, a, 250, 950, 990, 64, 245);
	let b: [96]u8 = [0...], wb: [48]u8 = [0...];
	if (a.p.synced != 0) {
		ok_badge(win, X(283), Y(978));
		viper::text(win, X(313), Y(978) - 8, fmt::bsprintf(b, "Sidst synkroniseret: {} (MEGA.nz)",
			when(wb, a.p.synced))!, C_TEXT);
	} else {
		draw_icon(win, icon::CLOUD, X(283), Y(978), C_DIM);
		viper::text(win, X(313), Y(978) - 8, "Ikke synkroniseret endnu (MEGA.nz)", C_DIM);
	};
	if (btn(win, a, 1250, 955, 252, 53, "Synkronisér nu", icon::CLOUD, true)) {
		check_sync(a);
		// Something to set up: the sync page shows how.
		if (sync_status(a) != "Synced" && sync_status(a) != "Pending" && sync_status(a) != "Syncing") {
			a.pg = page::SYNC;
		};
	};
};

// ---- Settings and about ----

fn draw_settings(win: *viper::window, a: *app) void = {
	glass(win, X(260), Y(295), L(1253), L(620), 12, 0xff0a1648);
	const x = X(290);
	let b: [256]u8 = [0...];
	const coll = find_file("samling.txt"), skin = find_file("skin.png");
	defer free(coll);
	defer free(skin);
	viper::text(win, x, Y(320), "Samlingen:", C_DIM);
	viper::text(win, x + 110, Y(320), coll, C_TEXT);
	viper::text(win, x, Y(345), "Baggrund:", C_DIM);
	viper::text(win, x + 110, Y(345), if (a.skin) skin else "tegnet (læg dit mockup som skin.png)", C_TEXT);
	bold(win, x, Y(395), "Nulstil fremgang (tryk to gange):", C_TEXT);
	let k = 0;
	for (let e = 0z; e < len(ENTRIES); e += 1) {
		const armed = a.reset_armed > 0.0 && a.reset_ent == e;
		const bx = 290 + (k % 3) * 405, by = 425 + (k / 3) * 62;
		k += 1;
		const label = if (armed) "Tryk igen!" else cut(ENTRIES[e].name, 30);
		if (btn(win, a, bx, by, 390, 48, label, void, false)) {
			if (armed) {
				for (let i = 0z; i < MAXEP; i += 1) a.p.seen[e][i] = 0;
				save(&a.p);
				a.reset_armed = 0.0;
				say(a, fmt::bsprintf(b, "{} er nulstillet.", cut(ENTRIES[e].name, 60))!);
				if (e == a.ent) go_next(a);
			} else {
				a.reset_armed = 3.0;
				a.reset_ent = e;
			};
		};
	};
};

fn draw_about(win: *viper::window, a: *app) void = {
	glass(win, X(260), Y(295), L(1253), L(620), 12, 0xff0a1648);
	const x = X(290);
	bold2(win, x, Y(320), "Samling v0.1.0", C_YEL_HI);
	const lines = [
		"En tracker til en familie af serier og film, bygget med ViperGui i Hare.",
		"",
		"Hvad der er i samlingen står i samling.txt, som du selv har.",
		"Fremgangen gemmes i ~/.local/share/samling/ og kan synkroniseres med MEGA.",
		"",
		"Klik på et afsnit for at vælge det, klik igen for at markere det som set.",
		"Piletaster: flyt   Mellemrum: markér   1-9: sæson   Tab: næste side",
		"Esc: luk",
	];
	for (let i = 0z; i < len(lines); i += 1) {
		viper::text(win, x, Y(380) + i: int * 22, lines[i], C_TEXT);
	};
};

fn draw_message(win: *viper::window, a: *app) void = {
	if (a.msg_t <= 0.0) return;
	const m = strings::fromutf8_unsafe(a.msg[..a.mlen]);
	const w = viper::text_width(m, 1) + 30;
	const x = X(234) + (W - X(234) - w) / 2;
	viper::round_rect(win, x, 10, w, 30, 8, C_YELLOW);
	viper::round_rect(win, x + 2, 12, w - 4, 26, 7, C_DEEP);
	viper::text(win, x + 15, 17, m, C_YEL_HI);
};
