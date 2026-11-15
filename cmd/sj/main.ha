// SJ Mini — read the newest chapters on MANGA Plus, with Hare + ViperGui.
//
// The little Python helper next to this file (sj.py) talks to MANGA Plus:
// it fetches the latest updates, a series' free chapters, and a chapter's
// pages (unlocked and saved as pictures). Everything is shown right here:
// click a cover for its chapters, click a chapter to read it.
// Right-click a cover (or click the star) to make it a favourite.
//
// Run it from the vipergui folder:  ./sj-mini
use fmt;
use io;
use os;
use os::exec;
use strings;
use viper;

def W: int = 1100;
def H: int = 700;
def MAX: size = 90;

def BG: viper::color = 0xff121214;
def CARD: viper::color = 0xff1d1d22;
def CARD_HOT: viper::color = 0xff26262d;
def LINE: viper::color = 0xff2e2e36;
def RED: viper::color = 0xffe8303a;
def RED_D: viper::color = 0xffb81f28;
def TEXT: viper::color = 0xfff2f2f2;
def DIM: viper::color = 0xff9a9aa6;
def STAR: viper::color = 0xfff5c518;
def STAR_HOT: viper::color = 0xffc8a020;
def GREEN: viper::color = 0xff3ccf74;

// The grid of covers.
def GRID_Y: int = 128;
def GRID_H: int = 544;
def CARD_W: int = 160;
def CARD_H: int = 304;
def STEP_X: int = 172;
def STEP_Y: int = 316;
def COLS: int = 6;

type comic = struct {
	id: str,
	name: str,
	author: str,
	ago: str,
	fresh: bool,
	fav: bool,
	img: str,
	pic: viper::image,
	pic_ok: bool,
	pic_tried: bool,
};

type tab = enum { ALL, NEW, FAV };

type view = enum { GRID, CHAPTERS, READ };

def MAXCH: size = 400;
def MAXPAGES: size = 300;
def VIEW_H: int = 672;         // the reader's height above the bottom bar
def PAGE_STEP: int = 908;      // a page (900 high, see sj.py) plus a gap
def END_H: int = 260;          // the "end of chapter" part after the pages

type chapter = struct {
	id: str,
	name: str,             // "#1181"
	sub: str,              // the chapter's title
	date: str,
};

type app = struct {
	comics: [MAX]comic,
	n: size,
	data: []u8,            // list.tsv; the strings in comics point into it
	favs: []u8,            // favoritter.txt
	search: viper::textinput,
	show: tab,
	loading: bool,
	poll_t: f64,
	scroll: int,
	// A series' chapters
	mode: view,
	sel: size,             // the comic we look at
	chapters: [MAXCH]chapter,
	nch: size,
	chdata: []u8,          // chapters-<id>.tsv; the strings above point into it
	ch_about: str,
	ch_last: str,          // the chapter read last time
	lastbuf: [32]u8,
	ch_loading: bool,
	ch_poll_t: f64,
	ch_scroll: int,
	ch_err: str,
	// The reader
	rd_ch: size,           // which chapter (index into chapters)
	rd_total: size,
	rd_ready: bool,        // info.tsv has been read
	rd_wait: f64,
	rd_scroll: int,        // how far down the long strip of pages we are
	page: size,
	pages: [MAXPAGES]viper::image,
	page_ok: [MAXPAGES]bool,
	msgbuf: [512]u8,
	msg: str,
	msg_col: viper::color,
	msg_t: f64,
	t: f64,
};

// --- small helpers ---

fn home() str = match (os::getenv("HOME")) {
case let h: str => yield h;
case void => yield ".";
};

fn data_path(buf: []u8, file: str) str =
	fmt::bsprintf(buf, "{}/.local/share/sj-mini/{}", home(), file)!;

fn helper() str = match (os::getenv("SJ_PY")) {
case let p: str => yield p;
case void => yield "cmd/sj/sj.py";
};

fn say(a: *app, col: viper::color, f: str, args: fmt::field...) void = {
	a.msg = fmt::bsprintf(a.msgbuf, f, args...)!;
	a.msg_col = col;
	a.msg_t = 6.0;
};

fn clicked(win: *viper::window) bool =
	(viper::mouse_clicks(win) & viper::LEFT_BUTTON) != 0;

fn right_clicked(win: *viper::window) bool =
	(viper::mouse_clicks(win) & viper::RIGHT_BUTTON) != 0;

fn inside(win: *viper::window, x: int, y: int, w: int, h: int) bool =
	win.mouse_x >= x && win.mouse_x < x + w && win.mouse_y >= y && win.mouse_y < y + h;

// Cuts s to at most n characters, with "..." when something was cut.
fn fit(s: str, n: int, buf: []u8) str = {
	const b = strings::toutf8(s);
	let count = 0, i = 0z;
	for (i < len(b)) {
		if ((b[i] & 0xc0) != 0x80) {
			if (count == n) break;
			count += 1;
		};
		i += 1;
	};
	if (i >= len(b)) return s;
	return fmt::bsprintf(buf, "{}...", strings::fromutf8_unsafe(b[..i]))!;
};

fn lower(c: u8) u8 = if (c >= 65 && c <= 90) c + 32 else c;

// Does hay contain needle? (A-Z and a-z count as the same.)
fn contains(hay: str, needle: str) bool = {
	const h = strings::toutf8(hay), n = strings::toutf8(needle);
	if (len(n) == 0) return true;
	if (len(n) > len(h)) return false;
	for (let i = 0z; i + len(n) <= len(h); i += 1) {
		let ok = true;
		for (let j = 0z; j < len(n); j += 1) {
			if (lower(h[i + j]) != lower(n[j])) {
				ok = false;
				break;
			};
		};
		if (ok) return true;
	};
	return false;
};

// Splits a line at tabs.
fn fields(line: []u8, out: []str) size = {
	let n = 0z, start = 0z;
	for (let i = 0z; i <= len(line) && n < len(out); i += 1) {
		if (i == len(line) || line[i] == 9) {
			out[n] = strings::fromutf8_unsafe(line[start..i]);
			n += 1;
			start = i + 1;
		};
	};
	return n;
};

// Runs a shell line that puts its work in the background (ends with &).
fn sh_bg(script: str, a1: str, a2: str, a3: str) bool = {
	let cmd = match (exec::cmd("sh", "-c", script, "sj", a1, a2, a3)) {
	case let c: exec::command => yield c;
	case => return false;
	};
	exec::nullstd(&cmd)!;
	const p = match (exec::start(&cmd)) {
	case let p: exec::process => yield p;
	case => return false;
	};
	match (exec::wait(&p)) {
	case let st: exec::status => return exec::check(&st) is void;
	case => return false;
	};
};

fn read_file(path: str) ([]u8 | void) = {
	const f = match (os::open(path)) {
	case let f: io::file => yield f;
	case => return;
	};
	defer io::close(f)!;
	match (io::drain(f)) {
	case let d: []u8 => return d;
	case => return;
	};
};

// --- favourites (one id per line in favoritter.txt) ---

fn load_favs(a: *app) void = {
	free(a.favs);
	a.favs = [];
	let pb: [512]u8 = [0...];
	match (read_file(data_path(pb, "favoritter.txt"))) {
	case let d: []u8 => a.favs = d;
	case void => void;
	};
};

fn is_fav(a: *app, id: str) bool = {
	const want = strings::toutf8(id);
	let start = 0z;
	for (let i = 0z; i <= len(a.favs); i += 1) {
		if (i < len(a.favs) && a.favs[i] != 10) continue;
		const line = a.favs[start..i];
		start = i + 1;
		if (len(line) == len(want) && strings::fromutf8_unsafe(line) == id) return true;
	};
	return false;
};

fn toggle_fav(a: *app, c: *comic) void = {
	c.fav = !c.fav;
	if (!sh_bg("python3 \"$1\" fav \"$2\" >/dev/null 2>&1 &", helper(), c.id, "")) {
		say(a, RED, "Kunne ikke gemme favoritten.");
		return;
	};
	if (c.fav) {
		say(a, STAR, "{} er nu en favorit.", c.name);
	} else {
		say(a, DIM, "{} er ikke favorit længere.", c.name);
	};
};

// --- the list of comics ---

fn free_comics(a: *app) void = {
	for (let i = 0z; i < a.n; i += 1) {
		if (a.comics[i].pic_ok) viper::image_free(&a.comics[i].pic);
	};
	a.n = 0;
	free(a.data);
	a.data = [];
};

// Reads list.tsv, written by sj.py. Returns false while it is not there.
fn load_list(a: *app) bool = {
	let pb: [512]u8 = [0...];
	const data = match (read_file(data_path(pb, "list.tsv"))) {
	case let d: []u8 => yield d;
	case void => return false;
	};
	free_comics(a);
	a.data = data;
	load_favs(a);

	let fl: [6]str = [""...];
	let first = true, start = 0z;
	for (let i = 0z; i <= len(data); i += 1) {
		if (i < len(data) && data[i] != 10) continue;
		const line = data[start..i];
		start = i + 1;
		if (len(line) == 0) continue;
		const nf = fields(line, fl);
		if (first) {
			first = false;
			if (fl[0] == "ERR") {
				say(a, RED, "{}", if (nf > 1) fl[1] else "Noget gik galt.");
				return true;
			};
			continue;
		};
		if (nf < 6 || a.n >= MAX) continue;
		let c = &a.comics[a.n];
		c.id = fl[0];
		c.name = fl[1];
		c.author = fl[2];
		c.ago = fl[3];
		c.fresh = fl[4] == "1";
		c.img = fl[5];
		c.fav = is_fav(a, c.id);
		c.pic_ok = false;
		c.pic_tried = false;
		a.n += 1;
	};
	return true;
};

// Loads one cover each frame, so the window never freezes.
fn load_one_cover(a: *app) void = {
	for (let i = 0z; i < a.n; i += 1) {
		let c = &a.comics[i];
		if (c.pic_tried) continue;
		c.pic_tried = true;
		if (len(c.img) == 0) continue;
		match (viper::load_png(c.img)) {
		case let im: viper::image =>
			c.pic = im;
			c.pic_ok = true;
		case viper::imgerror => void;
		};
		return;
	};
};

// Asks sj.py for the newest updates.
fn refresh(a: *app) void = {
	if (!os::exists(helper())) {
		say(a, RED, "Kan ikke finde {} - start appen fra vipergui-mappen.", helper());
		return;
	};
	let pb: [512]u8 = [0...];
	match (os::remove(data_path(pb, "list.tsv"))) {
	case => void;
	};
	if (!sh_bg("python3 \"$1\" list >/dev/null 2>&1 &", helper(), "", "")) {
		say(a, RED, "Kunne ikke starte python3.");
		return;
	};
	a.loading = true;
	a.poll_t = 0.0;
	say(a, RED, "Henter de nyeste kapitler fra MANGA Plus...");
};

// Opens the series on the MANGA Plus website instead.
fn open_comic(a: *app, c: *comic) void = {
	if (sh_bg("python3 \"$1\" open \"$2\" >/dev/null 2>&1 &", helper(), c.id, "")) {
		say(a, GREEN, "Åbner {}...", c.name);
	} else {
		say(a, RED, "Kunne ikke starte python3.");
	};
};

// The comics that pass the search and the tab.
fn visible(a: *app, out: []size) size = {
	const q = strings::trim(viper::textinput_str(&a.search));
	let n = 0z;
	for (let i = 0z; i < a.n; i += 1) {
		const c = &a.comics[i];
		if (a.show == tab::NEW && !c.fresh) continue;
		if (a.show == tab::FAV && !c.fav) continue;
		if (!contains(c.name, q) && !contains(c.author, q)) continue;
		out[n] = i;
		n += 1;
	};
	return n;
};

// --- a series' chapters ---

fn chapters_file(buf: []u8, id: str) str = {
	let nb: [64]u8 = [0...];
	return data_path(buf, fmt::bsprintf(nb, "chapters-{}.tsv", id)!);
};

fn open_chapters(a: *app, i: size) void = {
	a.sel = i;
	a.mode = view::CHAPTERS;
	a.nch = 0;
	free(a.chdata);
	a.chdata = [];
	a.ch_about = "";
	a.ch_last = "";
	a.ch_err = "";
	a.ch_scroll = 0;
	const c = &a.comics[i];
	let pb: [512]u8 = [0...];
	match (os::remove(chapters_file(pb, c.id))) {
	case => void;
	};
	if (!sh_bg("python3 \"$1\" chapters \"$2\" >/dev/null 2>&1 &", helper(), c.id, "")) {
		a.ch_err = "Kunne ikke starte python3.";
		return;
	};
	a.ch_loading = true;
	a.ch_poll_t = 0.0;
};

// Reads chapters-<id>.tsv. Returns false while it is not there.
fn load_chapters(a: *app) bool = {
	let pb: [512]u8 = [0...];
	const data = match (read_file(chapters_file(pb, a.comics[a.sel].id))) {
	case let d: []u8 => yield d;
	case void => return false;
	};
	free(a.chdata);
	a.chdata = data;
	a.nch = 0;
	let fl: [4]str = [""...];
	let first = true, start = 0z;
	for (let i = 0z; i <= len(data); i += 1) {
		if (i < len(data) && data[i] != 10) continue;
		const line = data[start..i];
		start = i + 1;
		if (len(line) == 0) continue;
		const nf = fields(line, fl);
		if (first) {
			first = false;
			if (fl[0] == "ERR") {
				a.ch_err = if (nf > 1) fl[1] else "Noget gik galt.";
				return true;
			};
			if (nf > 2) a.ch_about = fl[2];
			if (nf > 3) a.ch_last = fl[3];
			continue;
		};
		if (nf < 4 || a.nch >= MAXCH) continue;
		a.chapters[a.nch] = chapter {
			id = fl[0],
			name = fl[1],
			sub = fl[2],
			date = fl[3],
		};
		a.nch += 1;
	};
	return true;
};

// --- the reader ---

fn page_path(buf: []u8, a: *app, k: size) str = {
	let nb: [64]u8 = [0...];
	const zeros = if (k < 10) "00" else if (k < 100) "0" else "";
	return data_path(buf, fmt::bsprintf(nb, "pages/{}/{}{}.png",
		a.chapters[a.rd_ch].id, zeros, k)!);
};

fn free_pages(a: *app) void = {
	for (let k = 0z; k < MAXPAGES; k += 1) {
		if (a.page_ok[k]) viper::image_free(&a.pages[k]);
		a.page_ok[k] = false;
	};
};

fn open_reader(a: *app, k: size) void = {
	free_pages(a);
	a.rd_ch = k;
	a.rd_total = 0;
	a.rd_ready = false;
	a.rd_wait = 0.0;
	a.page = 0;
	a.rd_scroll = 0;
	a.mode = view::READ;
	const ch = &a.chapters[k];
	// Remember it (sj.py saves it too).
	a.ch_last = fmt::bsprintf(a.lastbuf, "{}", ch.id)!;
	if (!sh_bg("python3 \"$1\" pages \"$2\" \"$3\" >/dev/null 2>&1 &",
			helper(), a.comics[a.sel].id, ch.id)) {
		say(a, RED, "Kunne ikke starte python3.");
	};
};

// Reads pages/<chapter>/info.tsv: how many pages there are, or an error.
fn read_info(a: *app) void = {
	let pb: [512]u8 = [0...], nb: [64]u8 = [0...];
	const path = data_path(pb, fmt::bsprintf(nb, "pages/{}/info.tsv",
		a.chapters[a.rd_ch].id)!);
	const data = match (read_file(path)) {
	case let d: []u8 => yield d;
	case void => return;
	};
	defer free(data);
	let fl: [2]str = [""...];
	let end = 0z;
	for (end < len(data) && data[end] != 10) end += 1;
	const nf = fields(data[..end], fl);
	a.rd_ready = true;
	if (fl[0] == "ERR") {
		say(a, RED, "{}", if (nf > 1) fl[1] else "Kapitlet kunne ikke hentes.");
		a.mode = view::CHAPTERS;
		return;
	};
	let n = 0z;
	for (let c .. strings::toutf8(fl[1])) {
		if (c >= 48 && c <= 57) n = n * 10 + (c - 48): size;
	};
	a.rd_total = if (n > MAXPAGES) MAXPAGES else n;
};

// Keeps the pages near the one we read in memory, and loads the next one
// that is ready. Pages far away are let go again, so memory stays small.
fn reader_pages(a: *app, dt: f64) void = {
	if (a.rd_wait > 0.0) {
		a.rd_wait -= dt;
		return;
	};
	if (!a.rd_ready) {
		read_info(a);
		a.rd_wait = 0.25;
		return;
	};
	const lo = if (a.page > 2) a.page - 2 else 0z;
	const hi = if (a.page + 5 < a.rd_total) a.page + 5 else a.rd_total;
	for (let k = 0z; k < a.rd_total; k += 1) {
		if (a.page_ok[k] && (k < lo || k >= hi)) {
			viper::image_free(&a.pages[k]);
			a.page_ok[k] = false;
		};
	};
	// The page we look at first, then the ones after it.
	for (let k = a.page; k < hi; k += 1) {
		if (a.page_ok[k]) continue;
		let pb: [512]u8 = [0...];
		match (viper::load_png(page_path(pb, a, k))) {
		case let im: viper::image =>
			a.pages[k] = im;
			a.page_ok[k] = true;
		case viper::imgerror =>
			a.rd_wait = 0.25;      // not downloaded yet
		};
		return;
	};
	if (a.page > 0 && !a.page_ok[a.page - 1] && a.page - 1 >= lo) {
		let pb: [512]u8 = [0...];
		match (viper::load_png(page_path(pb, a, a.page - 1))) {
		case let im: viper::image =>
			a.pages[a.page - 1] = im;
			a.page_ok[a.page - 1] = true;
		case viper::imgerror => void;
		};
	};
};

// Moves down (or up) the strip of pages, and works out the page we are on.
fn scroll_by(a: *app, d: int) void = {
	let maxs = a.rd_total: int * PAGE_STEP + END_H - VIEW_H;
	if (maxs < 0) maxs = 0;
	a.rd_scroll += d;
	if (a.rd_scroll > maxs) a.rd_scroll = maxs;
	if (a.rd_scroll < 0) a.rd_scroll = 0;
	let p = ((a.rd_scroll + VIEW_H / 3) / PAGE_STEP): size;
	if (a.rd_total > 0 && p >= a.rd_total) p = a.rd_total - 1;
	a.page = p;
};

fn at_end(a: *app) bool =
	a.rd_total > 0 && a.rd_scroll + VIEW_H >= a.rd_total: int * PAGE_STEP + END_H - 4;

fn next_chapter(a: *app) void = {
	if (a.rd_ch + 1 < a.nch) open_reader(a, a.rd_ch + 1);
};

// --- drawing ---

fn chip(win: *viper::window, x: int, y: int, w: int, s: str, on: bool) bool = {
	const over = inside(win, x, y, w, 28);
	const bg: viper::color = if (on) RED else if (over) CARD_HOT else CARD;
	viper::round_rect(win, x, y, w, 28, 14, if (on) RED else LINE);
	viper::round_rect(win, x + 1, y + 1, w - 2, 26, 13, bg);
	viper::text(win, x + (w - viper::text_width(s, 1)) / 2, y + 6, s, if (on) TEXT else DIM);
	return over && clicked(win);
};

fn button(win: *viper::window, x: int, y: int, w: int, h: int, s: str) bool = {
	const over = inside(win, x, y, w, h);
	viper::round_rect(win, x, y, w, h, 8, if (over) RED_D else RED);
	viper::text(win, x + (w - viper::text_width(s, 1)) / 2, y + (h - 16) / 2, s, TEXT);
	return over && clicked(win);
};

fn spinner(win: *viper::window, cx: int, cy: int, t: f64) void = {
	const lead = (t * 10.0): int % 8;
	const dx: [8]int = [0, 7, 10, 7, 0, -7, -10, -7];
	const dy: [8]int = [-10, -7, 0, 7, 10, 7, 0, -7];
	for (let i = 0; i < 8; i += 1) {
		const age = (lead - i + 8) % 8;
		const col = viper::mix(RED, BG, age: f64 / 8.0);
		viper::circle(win, cx + dx[i: size], cy + dy[i: size], 3, col);
	};
};

fn star(win: *viper::window, cx: int, cy: int, r: f64, col: viper::color) void = {
	const pts: [10](f64, f64) = [
		(0.0, -1.0), (0.3, -0.33), (1.0, -0.3), (0.47, 0.17), (0.62, 0.92),
		(0.0, 0.5), (-0.62, 0.92), (-0.47, 0.17), (-1.0, -0.3), (-0.3, -0.33),
	];
	let p: [10](f64, f64) = [(0.0, 0.0)...];
	for (let i = 0z; i < 10; i += 1) {
		p[i] = (pts[i].0 * r + cx: f64, pts[i].1 * r + cy: f64);
	};
	viper::polygon(win, p, col);
};

// Draws a name over two lines, broken at a space.
fn two_lines(win: *viper::window, x: int, y: int, s: str, n: size, col: viper::color) void = {
	let b = strings::toutf8(s);
	let buf: [96]u8 = [0...];
	for (let line = 0; line < 2 && len(b) > 0; line += 1) {
		let end = len(b);
		if (end > n && line == 0) {
			end = n;
			for (end > 0 && b[end] != 32) end -= 1;
			if (end == 0) end = n;
		};
		let part = strings::fromutf8_unsafe(b[..end]);
		if (line == 1) part = fit(part, n: int - 3, buf);
		viper::text(win, x, y + line * 18, part, col);
		b = b[end..];
		for (len(b) > 0 && b[0] == 32) b = b[1..];
	};
};

// Returns 1 when the cover was clicked, 2 when the star was.
fn draw_card(win: *viper::window, c: *comic, x: int, y: int) int = {
	const in_grid = win.mouse_y >= GRID_Y && win.mouse_y < GRID_Y + GRID_H;
	const over = in_grid && inside(win, x, y, CARD_W, CARD_H);
	viper::round_rect(win, x - 1, y - 1, CARD_W + 2, CARD_H + 2, 9, if (over) RED else LINE);
	viper::round_rect(win, x, y, CARD_W, CARD_H, 8, if (over) CARD_HOT else CARD);

	if (c.pic_ok) {
		viper::draw_image(win, &c.pic, x + 2, y + 2);
	} else {
		viper::rect(win, x + 2, y + 2, 156, 220, LINE);
		if (len(c.name) > 0) {
			viper::text_scaled(win, x + 64, y + 90, strings::sub(c.name, 0, 1), DIM, 4);
		};
	};
	if (c.fresh) {
		viper::round_rect(win, x + 8, y + 8, 36, 20, 10, RED);
		viper::text(win, x + 14, y + 10, "NY!", TEXT);
	};

	// The favourite star in the corner.
	const sx = x + CARD_W - 20, sy = y + 20;
	const on_star = in_grid && inside(win, sx - 14, sy - 14, 28, 28);
	if (c.fav || over) {
		viper::circle(win, sx, sy, 13, 0xff000000);
		star(win, sx, sy, 10.0, if (c.fav) STAR else if (on_star) STAR_HOT else DIM);
	};

	two_lines(win, x + 8, y + 228, c.name, 19, TEXT);
	let b: [96]u8 = [0...];
	viper::text(win, x + 8, y + 266, fit(c.author, 18, b), DIM);
	viper::text(win, x + 8, y + 284, c.ago, if (c.fresh) GREEN else DIM);

	if (on_star && clicked(win)) return 2;
	if (over && right_clicked(win)) return 2;
	if (over && clicked(win)) return 1;
	return 0;
};

fn draw(win: *viper::window, a: *app) void = {
	viper::clear(win, BG);

	// Header.
	viper::rect(win, 0, 0, W, 120, 0xff0b0b0d);
	viper::rect(win, 0, 120, W, 1, LINE);
	viper::round_rect(win, 24, 20, 8, 44, 4, RED);
	viper::text_scaled(win, 42, 16, "SJ Mini", TEXT, 3);
	viper::text(win, 44, 68, "MANGA Plus - de nyeste kapitler", DIM);

	viper::text(win, 560, 16, "Søg", DIM);
	if (viper::textbox(win, &a.search, 560, 36, 360, "Titel eller tegner...")) {
		a.search.focused = false;
	};
	if (button(win, 940, 36, 136, 30, "Opdater")) refresh(a);

	if (chip(win, 24, 86, 70, "Alle", a.show == tab::ALL)) a.show = tab::ALL;
	if (chip(win, 102, 86, 110, "Nye i dag", a.show == tab::NEW)) a.show = tab::NEW;
	if (chip(win, 220, 86, 110, "Favoritter", a.show == tab::FAV)) a.show = tab::FAV;

	let vis: [MAX]size = [0...];
	const nv = visible(a, vis);
	let cb: [64]u8 = [0...];
	if (a.n > 0) {
		viper::text(win, 350, 92, fmt::bsprintf(cb, "{} serier", nv)!, DIM);
	};
	if (a.loading) spinner(win, 1060, 100, a.t);

	// The grid.
	const rows = ((nv + COLS: size - 1) / COLS: size): int;
	let maxs = rows * STEP_Y + 12 - GRID_H;
	if (maxs < 0) maxs = 0;
	if (a.scroll > maxs) a.scroll = maxs;
	if (a.scroll < 0) a.scroll = 0;

	viper::clip(win, 0, GRID_Y, W, GRID_H);
	let opened: (size | void) = void, starred: (size | void) = void;
	for (let k = 0z; k < nv; k += 1) {
		const x = 24 + (k % COLS: size): int * STEP_X;
		const y = GRID_Y + 12 + (k / COLS: size): int * STEP_Y - a.scroll;
		if (y + CARD_H < GRID_Y || y > GRID_Y + GRID_H) continue;
		switch (draw_card(win, &a.comics[vis[k]], x, y)) {
		case 1 => opened = vis[k];
		case 2 => starred = vis[k];
		case => void;
		};
	};
	if (nv == 0 && !a.loading) {
		const s = if (a.n == 0) "Tryk Opdater for at hente de nyeste kapitler."
			else if (a.show == tab::FAV) "Ingen favoritter endnu - højreklik på et cover."
			else "Ingen serier passer.";
		viper::text(win, (W - viper::text_width(s, 1)) / 2, GRID_Y + 200, s, DIM);
	};
	viper::noclip(win);
	match (starred) {
	case let i: size => toggle_fav(a, &a.comics[i]);
	case void =>
		match (opened) {
		case let i: size => open_chapters(a, i);
		case void => void;
		};
	};

	// Scrollbar.
	if (maxs > 0) {
		const bh = GRID_H * GRID_H / (GRID_H + maxs);
		const by = GRID_Y + (GRID_H - bh) * a.scroll / maxs;
		viper::round_rect(win, W - 10, by, 6, bh, 3, LINE);
	};

	// Footer.
	viper::rect(win, 0, H - 28, W, 28, 0xff0b0b0d);
	viper::rect(win, 0, H - 28, W, 1, LINE);
	if (a.msg_t > 0.0) {
		viper::text(win, 24, H - 22, a.msg, a.msg_col);
	} else {
		viper::text(win, 24, H - 22,
			"Klik på et cover for at se kapitlerne. Højreklik eller stjernen gør det til en favorit.", DIM);
	};
};

// Breaks text into lines of at most n bytes at spaces.
fn wrapped(win: *viper::window, x: int, y: int, s: str, n: size, maxl: int,
		col: viper::color) int = {
	let b = strings::toutf8(s);
	let line = 0;
	for (len(b) > 0 && line < maxl) {
		let end = len(b);
		if (end > n) {
			end = n;
			for (end > 0 && b[end] != 32) end -= 1;
			if (end == 0) end = n;
		};
		viper::text(win, x, y + line * 18, strings::fromutf8_unsafe(b[..end]), col);
		b = b[end..];
		for (len(b) > 0 && b[0] == 32) b = b[1..];
		line += 1;
	};
	return line;
};

fn draw_chapters(win: *viper::window, a: *app) void = {
	viper::clear(win, BG);
	const c = &a.comics[a.sel];

	// The series, on the left.
	viper::rect(win, 0, 0, 300, H, 0xff0b0b0d);
	if (button(win, 24, 16, 120, 30, "< Tilbage")) {
		a.mode = view::GRID;
		return;
	};
	if (c.pic_ok) {
		viper::draw_image(win, &c.pic, 72, 62);
	} else {
		viper::rect(win, 72, 62, 156, 220, LINE);
	};
	let y = 294 + wrapped(win, 24, 294, c.name, 30, 2, TEXT) * 18;
	viper::text(win, 24, y + 4, c.author, DIM);
	y += 30;
	y += wrapped(win, 24, y, a.ch_about, 30, 12, DIM) * 18;
	if (button(win, 24, H - 84, 252, 30, if (c.fav) "Fjern som favorit" else "Gør til favorit")) {
		toggle_fav(a, c);
	};
	if (button(win, 24, H - 46, 252, 30, "Åbn på MANGA Plus")) open_comic(a, c);

	// The chapters, on the right.
	viper::text_scaled(win, 324, 18, "Kapitler", TEXT, 2);
	if (a.msg_t > 0.0) viper::text(win, 660, 26, a.msg, a.msg_col);
	let cb: [64]u8 = [0...];
	if (a.nch > 0) {
		viper::text(win, 470, 26, fmt::bsprintf(cb, "{} gratis kapitler", a.nch)!, DIM);
	};
	if (a.ch_loading) {
		spinner(win, 1060, 30, a.t);
		viper::text(win, 324, 120, "Henter kapitler...", DIM);
		return;
	};
	if (len(a.ch_err) > 0) {
		wrapped(win, 324, 120, a.ch_err, 90, 3, RED);
		return;
	};

	const top = 64, rowh = 48, list_h = H - top;
	let maxs = a.nch: int * rowh - list_h;
	if (maxs < 0) maxs = 0;
	if (a.ch_scroll > maxs) a.ch_scroll = maxs;
	if (a.ch_scroll < 0) a.ch_scroll = 0;
	viper::clip(win, 300, top, W - 300, list_h);
	let picked: (size | void) = void;
	for (let k = 0z; k < a.nch; k += 1) {
		const ch = &a.chapters[k];
		const ry = top + k: int * rowh - a.ch_scroll;
		if (ry + rowh < top || ry > H) continue;
		const last = ch.id == a.ch_last;
		const over = win.mouse_y >= top && inside(win, 316, ry, W - 340, rowh - 6);
		const bg: viper::color = if (over) CARD_HOT else CARD;
		viper::round_rect(win, 316, ry, W - 340, rowh - 6, 8, if (last) GREEN else bg);
		viper::round_rect(win, 318, ry + 2, W - 344, rowh - 10, 7, bg);
		viper::text_scaled(win, 332, ry + 13, ch.name, RED, 1);
		let b: [128]u8 = [0...];
		viper::text(win, 420, ry + 13, fit(ch.sub, 70, b), TEXT);
		if (last) {
			viper::text(win, W - 210, ry + 13, "Sidst læst", GREEN);
		} else {
			viper::text(win, W - 130, ry + 13, ch.date, DIM);
		};
		if (over && clicked(win)) picked = k;
	};
	viper::noclip(win);
	if (maxs > 0) {
		const bh = list_h * list_h / (list_h + maxs);
		const by = top + (list_h - bh) * a.ch_scroll / maxs;
		viper::round_rect(win, W - 10, by, 6, bh, 3, LINE);
	};
	match (picked) {
	case let k: size => open_reader(a, k);
	case void => void;
	};
};

fn draw_reader(win: *viper::window, a: *app) void = {
	viper::clear(win, 0xff000000);
	const ch = &a.chapters[a.rd_ch];
	let b: [128]u8 = [0...];

	if (!a.rd_ready || a.rd_total == 0) {
		spinner(win, W / 2, VIEW_H / 2 - 20, a.t);
		const s = "Henter kapitlet...";
		viper::text(win, (W - viper::text_width(s, 1)) / 2, VIEW_H / 2 + 10, s, DIM);
	} else {
		// The pages, one under the other, like one long strip.
		viper::clip(win, 0, 0, W, VIEW_H);
		const first = if (a.page > 1) a.page - 1 else 0z;
		for (let k = first; k < a.rd_total && k < first + 4; k += 1) {
			const y = k: int * PAGE_STEP - a.rd_scroll;
			if (y > VIEW_H || y + PAGE_STEP < 0) continue;
			if (a.page_ok[k]) {
				const im = &a.pages[k];
				viper::draw_image(win, im, (W - im.w) / 2, y);
			} else {
				viper::rect(win, (W - 620) / 2, y, 620, PAGE_STEP - 8, 0xff151518);
				let pb: [32]u8 = [0...];
				const s = fmt::bsprintf(pb, "Henter side {}...", k + 1)!;
				viper::text(win, (W - viper::text_width(s, 1)) / 2, y + 300, s, DIM);
			};
		};
		// The end of the chapter.
		const ey = a.rd_total: int * PAGE_STEP - a.rd_scroll;
		if (ey < VIEW_H) {
			const s = "Slut på kapitlet";
			viper::text_scaled(win, (W - viper::text_width(s, 3)) / 2, ey + 60, s, TEXT, 3);
			const n = if (a.rd_ch + 1 < a.nch) fmt::bsprintf(b, "Næste: {} {}  -  tryk Enter",
				a.chapters[a.rd_ch + 1].name, a.chapters[a.rd_ch + 1].sub)!
				else "Det er det nyeste gratis kapitel. Esc går tilbage.";
			viper::text(win, (W - viper::text_width(n, 1)) / 2, ey + 130, n, DIM);
		};
		viper::noclip(win);
	};

	// Bottom bar.
	viper::rect(win, 0, VIEW_H, W, H - VIEW_H, 0xff0b0b0d);
	viper::text(win, 16, VIEW_H + 6, "Hjul/pile ruller   Esc tilbage", DIM);
	let sb: [96]u8 = [0...];
	const t = fmt::bsprintf(b, "{}  {}", ch.name, fit(ch.sub, 50, sb))!;
	viper::text(win, (W - viper::text_width(t, 1)) / 2, VIEW_H + 6, t, TEXT);
	if (a.rd_total > 0) {
		let pb: [32]u8 = [0...];
		const p = fmt::bsprintf(pb, "Side {} / {}", a.page + 1, a.rd_total)!;
		viper::text(win, W - 16 - viper::text_width(p, 1), VIEW_H + 6, p, DIM);
	};
};

// Keys and the mouse wheel in the reader.
fn reader_input(win: *viper::window, a: *app) void = {
	if (!a.rd_ready || a.rd_total == 0) return;
	scroll_by(a, -viper::wheel(win) * 140);
	if (viper::key_pressed(win, viper::key::DOWN)) scroll_by(a, 140);
	if (viper::key_pressed(win, viper::key::UP)) scroll_by(a, -140);
	if (viper::key_pressed(win, viper::key::SPACE)) scroll_by(a, VIEW_H - 80);
	// Right and left jump a whole page.
	if (viper::key_pressed(win, viper::key::RIGHT)) {
		if (at_end(a)) next_chapter(a) else scroll_by(a, PAGE_STEP);
	};
	if (viper::key_pressed(win, viper::key::LEFT)) scroll_by(a, -PAGE_STEP);
	if (viper::key_pressed(win, viper::key::RETURN) && at_end(a)) next_chapter(a);
};

export fn main() void = {
	const win = match (viper::open("SJ Mini", W, H)) {
	case let w: *viper::window =>
		yield w;
	case let e: viper::error =>
		fmt::fatal("viper:", viper::strerror(e));
	case nomem =>
		fmt::fatal("viper: out of memory");
	};
	defer viper::close(win);
	win.theme = viper::theme {
		bg = BG,
		panel = CARD,
		border = LINE,
		text = TEXT,
		text_dim = DIM,
		widget = 0xff1d1d22,
		widget_hot = 0xff26262d,
		accent = RED,
		accent_hot = 0xfff04a53,
		accent_active = RED_D,
		...
	};
	match (viper::load_png("assets/sj/sj-mini-icon-64.png")) {
	case let icon: viper::image =>
		viper::set_icon(win, &icon);
		viper::image_free(&icon);
	case viper::imgerror => void;
	};

	let a = app { ... };
	load_list(&a);         // the last list while the new one loads
	refresh(&a);

	for (viper::frame(win)) {
		let dt = viper::delta(win);
		if (dt > 0.1) dt = 0.1;
		a.t += dt;
		if (a.msg_t > 0.0 && !a.loading) a.msg_t -= dt;
		const esc = viper::key_pressed(win, viper::key::ESCAPE);
		if (a.loading) {
			a.poll_t += dt;
			if (a.poll_t >= 0.3) {
				a.poll_t = 0.0;
				if (load_list(&a)) {
					a.loading = false;
					if (a.n > 0) say(&a, GREEN, "{} serier med nye kapitler.", a.n);
				};
			};
		};
		load_one_cover(&a);
		switch (a.mode) {
		case view::GRID =>
			if (esc) break;
			a.scroll -= viper::wheel(win) * 80;
			draw(win, &a);
		case view::CHAPTERS =>
			if (a.ch_loading) {
				a.ch_poll_t += dt;
				if (a.ch_poll_t >= 0.25) {
					a.ch_poll_t = 0.0;
					if (load_chapters(&a)) a.ch_loading = false;
				};
			};
			a.ch_scroll -= viper::wheel(win) * 60;
			if (esc) a.mode = view::GRID;
			draw_chapters(win, &a);
		case view::READ =>
			reader_pages(&a, dt);
			reader_input(win, &a);
			if (esc) a.mode = view::CHAPTERS;
			draw_reader(win, &a);
		};
		viper::present(win);
	};
	free_pages(&a);
	free(a.chdata);
	free_comics(&a);
	free(a.favs);
};
