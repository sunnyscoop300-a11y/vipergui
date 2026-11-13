// Blade & Soul: Anime Tracker — keeps track of the 13 episodes of the
// Blade & Soul anime (Gonzo, 2014). Made with Hare + ViperGui.
//
// Progress is saved in ~/.bns-tracker. Optional pictures (your own art):
//   assets/bns/banner.png     the banner at the top
//   assets/bns/portrait.png   the picture next to "Min fremdrift"
//   assets/bns/ep-01.png ...  a picture for each episode
use fmt;
use fs;
use io;
use math;
use os;
use os::exec;
use strconv;
use strings;
use time;
use viper;

def W: int = 1100;
def H: int = 700;
def NEP: size = 13;
def EP_MIN: int = 24;          // minutes per episode
def MEGA_DIR: str = "/HPO/BnS-Tracker";

def BG: viper::color = 0xff120c1c;
def SIDE: viper::color = 0xff160f22;
def PANEL: viper::color = 0xff1d1430;
def EDGE: viper::color = 0xff3a2456;
def PINK: viper::color = 0xffe0408a;
def PINK_SOFT: viper::color = 0xffff7eb6;
def RED: viper::color = 0xffd0203a;
def GOLD: viper::color = 0xffffc83a;
def TEXT: viper::color = 0xfff2eaff;
def DIM: viper::color = 0xff9a8cb8;
def GREEN: viper::color = 0xff3ad06a;

// Episode status.
def MISSING: int = 0;
def SEEN: int = 1;
def PAUSED: int = 2;

// Pages.
def P_OVERVIEW: int = 0;
def P_NOTES: int = 1;
def P_STATS: int = 2;
def P_SETTINGS: int = 3;

const TITLES: [13]str = [
	"Road", "Desires", "Revenge", "Sword", "Flower", "Dream", "Time",
	"Sky", "Moon", "Sin", "Punishment", "Soul", "God",
];

// Original Japanese air dates (TBS, 2014).
const AIRED: [13]str = [
	"2014-04-03", "2014-04-10", "2014-04-17", "2014-04-24", "2014-05-01",
	"2014-05-08", "2014-05-15", "2014-05-22", "2014-05-29", "2014-06-05",
	"2014-06-12", "2014-06-19", "2014-06-26",
];

const PAGES: [4]str = ["Oversigt", "Noter", "Statistik", "Indstillinger"];

type app = struct {
	page: int,
	sel: size,
	status: [13]int,
	fav: [13]bool,
	seen: [13][12]u8,       // the date you watched it, "2026-11-13"
	seen_n: [13]size,
	notes: [13]viper::textinput,
	folder: viper::textinput,
	msg: str,
	msg_t: f64,
	msg_col: viper::color,
	t: f64,
	confirm_t: f64,
    mtime: i64,             // when the save file last changed
	check_t: f64,
	mega: int,              // 0 = ?, 1 = synkroniseres, 2 = ikke sat op, 3 = ingen MEGAcmd
	banner: viper::image,
	banner_ok: bool,
	portrait: viper::image,
	portrait_ok: bool,
    logo: viper::image,
	logo_ok: bool,
	episode: viper::image,
	episode_ok: bool,
	shots: [13]viper::image,
	shot_ok: [13]bool,
};

// --- small helpers ---

fn home() str = match (os::getenv("HOME")) {
case let h: str => yield h;
case void => yield ".";
};

// "~/x" -> "/home/tux/x". The result must be freed.
fn expand(p: str) str = {
	if (strings::hasprefix(p, "~/")) {
		return strings::concat(home(), strings::trimprefix(p, "~"))!;
	};
	return strings::dup(p)!;
};

fn say(a: *app, s: str, col: viper::color) void = {
	a.msg = s;
	a.msg_col = col;
	a.msg_t = 3.0;
};

fn set_input(tb: *viper::textinput, s: str) void = {
	const b = strings::toutf8(s);
	const n = if (len(b) > len(tb.buf)) len(tb.buf) else len(b);
	tb.buf[..n] = b[..n];
	tb.length = n;
};

fn seen_str(a: *app, i: size) str = strings::fromutf8_unsafe(a.seen[i][..a.seen_n[i]]);

fn count(a: *app, st: int) int = {
	let n = 0;
	for (let i = 0z; i < NEP; i += 1) {
		if (a.status[i] == st) n += 1;
	};
	return n;
};

fn favs(a: *app) int = {
	let n = 0;
	for (let i = 0z; i < NEP; i += 1) {
		if (a.fav[i]) n += 1;
	};
	return n;
};

fn unfocus_all(a: *app) void = {
	a.folder.focused = false;
	for (let i = 0z; i < NEP; i += 1) a.notes[i].focused = false;
};

fn any_focused(a: *app) bool = {
	if (a.folder.focused) return true;
	for (let i = 0z; i < NEP; i += 1) {
		if (a.notes[i].focused) return true;
	};
	return false;
};

// Today's date as "YYYY-MM-DD" (days -> civil date, Howard Hinnant's method).
fn today(buf: []u8) str = {
	const days = time::now(time::clock::REALTIME).sec / 86400;
	const z = days + 719468;
	const era = (if (z >= 0) z else z - 146096) / 146097;
	const doe = z - era * 146097;
	const yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
	const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
	const mp = (5 * doy + 2) / 153;
	const d = doy - (153 * mp + 2) / 5 + 1;
	const m = if (mp < 10) mp + 3 else mp - 9;
	const leap: i64 = if (m <= 2) 1 else 0;
	const y = yoe + era * 400 + leap;
	return fmt::bsprintf(buf, "{}-{}{}-{}{}", y,
		if (m < 10) "0" else "", m, if (d < 10) "0" else "", d)!;
};

// --- saving: ~/.bns-tracker ---

fn data_dir(buf: []u8) str = fmt::bsprintf(buf, "{}/.local/share/bns-tracker", home())!;

fn save_path(buf: []u8) str =
	fmt::bsprintf(buf, "{}/.local/share/bns-tracker/bns-tracker.txt", home())!;

fn file_mtime(path: str) i64 = match (os::stat(path)) {
case let st: fs::filestat => yield st.mtime.sec;
case => yield 0;
};

fn save(a: *app) void = {
	let db: [512]u8 = [0...];
	match (os::mkdirs(data_dir(db), 0o755)) { case => void; };
	let pb: [512]u8 = [0...];
	const p = save_path(pb);
	defer a.mtime = file_mtime(p);
	const f = match (os::create(p, 0o644)) {
	case let f: io::file => yield f;
	case => return;
	};
	defer io::close(f)!;
	fmt::fprintfln(f, "dir={}", viper::textinput_str(&a.folder))!;
	for (let i = 0z; i < NEP; i += 1) {
		// A '|' in a note would break the line apart, so it becomes '/'.
		let nb: [2048]u8 = [0...];
		const note = strings::toutf8(viper::textinput_str(&a.notes[i]));
		for (let k = 0z; k < len(note); k += 1) {
			const c: u8 = if (note[k] == 124) 47 else note[k];
			nb[k] = c;
		};
		fmt::fprintfln(f, "{}|{}|{}|{}|{}", i + 1, a.status[i],
			if (a.fav[i]) "1" else "0", seen_str(a, i),
			strings::fromutf8_unsafe(nb[..len(note)]))!;
	};
};

// Splits s at '|' into out; the last field keeps the rest of the line.
fn split_fields(s: str, out: []str) size = {
	const b = strings::toutf8(s);
	let n = 0z, start = 0z;
	for (let i = 0z; i <= len(b); i += 1) {
		if (i == len(b) || (b[i] == 124 && n + 1 < len(out))) {
			if (n < len(out)) {
				out[n] = strings::fromutf8_unsafe(b[start..i]);
				n += 1;
			};
			start = i + 1;
		};
	};
	return n;
};

fn load_file(a: *app, path: str) bool = {
	const f = match (os::open(path)) {
	case let f: io::file => yield f;
	case => return false;
	};
	defer io::close(f)!;
	const data = match (io::drain(f)) {
	case let d: []u8 => yield d;
	case => return false;
	};
	defer free(data);
	let start = 0z;
	for (let i = 0z; i <= len(data); i += 1) {
		if (i == len(data) || data[i] == 10) {
			let end = i;
			if (end > start && data[end - 1] == 13) end -= 1;
			match (strings::fromutf8(data[start..end])) {
			case let s: str => load_line(a, s);
			case => void;
			};
			start = i + 1;
		};
	};
	return true;
};

fn load(a: *app) void = {
	let pb: [512]u8 = [0...];
	const p = save_path(pb);
	if (!load_file(a, p)) {
		// The old place, from before MEGA sync.
		let ob: [512]u8 = [0...];
		load_file(a, fmt::bsprintf(ob, "{}/.bns-tracker", home())!);
	};
	a.mtime = file_mtime(p);
};

// Forgets everything before the file is read again.
fn reset(a: *app) void = {
	for (let i = 0z; i < NEP; i += 1) {
		a.status[i] = MISSING;
		a.fav[i] = false;
		a.seen_n[i] = 0;
		viper::textinput_clear(&a.notes[i]);
	};
};

fn check_mega(a: *app) void = {
	if (!sh_ok("command -v mega-sync >/dev/null", "", "")) {
		a.mega = 3;
		return;
	};
	a.mega = if (sh_ok("mega-sync 2>/dev/null | grep -q BnS-Tracker", "", "")) 1 else 2;
};

fn mega_setup(a: *app) void = {
	save(a);
	let db: [512]u8 = [0...];
	const ok = sh_ok("mega-mkdir -p \"$2\" >/dev/null 2>&1; mega-sync \"$1\" \"$2\" 2>&1 | grep -qiE \"added sync|already\"",
		data_dir(db), MEGA_DIR);
	check_mega(a);
	const good = ok || a.mega == 1;
	const col: viper::color = if (good) GREEN else RED;
	say(a, if (good) "Synkroniseres nu med MEGA!" else "MEGA sagde nej - er du logget ind (mega-login)?", col);
};

fn load_line(a: *app, line: str) void = {
	if (strings::hasprefix(line, "dir=")) {
		set_input(&a.folder, strings::trimprefix(line, "dir="));
		return;
	};
	let f: [5]str = [""...];
	if (split_fields(line, f) < 5) return;
	const n = match (strconv::stoi(f[0])) {
	case let v: int => yield v;
	case => return;
	};
	if (n < 1 || n > NEP: int) return;
	const i = (n - 1): size;
	a.status[i] = match (strconv::stoi(f[1])) {
	case let v: int => yield if (v >= 0 && v <= 2) v else MISSING;
	case => yield MISSING;
	};
	a.fav[i] = f[2] == "1";
	const d = strings::toutf8(f[3]);
	const dn = if (len(d) > len(a.seen[i])) len(a.seen[i]) else len(d);
	a.seen[i][..dn] = d[..dn];
	a.seen_n[i] = dn;
	set_input(&a.notes[i], f[4]);
};

// --- actions ---

fn toggle_seen(a: *app, i: size) void = {
	if (a.status[i] == SEEN) {
		a.status[i] = MISSING;
		a.seen_n[i] = 0;
		say(a, "Fjernet fra sete episoder.", DIM);
	} else {
		a.status[i] = SEEN;
		let b: [16]u8 = [0...];
		const d = strings::toutf8(today(b));
		a.seen[i][..len(d)] = d;
		a.seen_n[i] = len(d);
		say(a, "Markeret som set!", GREEN);
	};
	save(a);
};

fn toggle_fav(a: *app, i: size) void = {
	a.fav[i] = !a.fav[i];
	say(a, if (a.fav[i]) "Tilføjet til favoritter." else "Fjernet fra favoritter.", GOLD);
	save(a);
};

fn toggle_pause(a: *app, i: size) void = {
	if (a.status[i] == PAUSED) {
		a.status[i] = MISSING;
		say(a, "Ikke længere på pause.", DIM);
	} else {
		a.status[i] = PAUSED;
		a.seen_n[i] = 0;
		say(a, "Sat på pause.", GOLD);
	};
	save(a);
};

fn sh_ok(script: str, a1: str, a2: str) bool = {
	let cmd = match (exec::cmd("sh", "-c", script, "bns", a1, a2)) {
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

// Finds the episode in the video folder (E07, Ep 7, - 07 - ...) and opens
// it with the normal video player.
fn play(a: *app, i: size) void = {
	const raw = viper::textinput_str(&a.folder);
	if (len(strings::trim(raw)) == 0) {
		say(a, "Vælg din video-mappe under Indstillinger.", RED);
		return;
	};
	const dir = expand(strings::trim(raw));
	defer free(dir);
	let nb: [8]u8 = [0...];
	const n = fmt::bsprintf(nb, "{}", i + 1)!;
	const script =
		"d=\"$1\"; n=\"$2\"; "
		"f=$(ls -1 \"$d\" 2>/dev/null | grep -iE \"e(p)?[ ._-]*0?$n([^0-9]|$)\" | head -n1); "
		"[ -z \"$f\" ] && f=$(ls -1 \"$d\" 2>/dev/null | grep -E \"(^|[^0-9])0?$n([^0-9]|$)\" | head -n1); "
		"[ -n \"$f\" ] || exit 1; "
		"xdg-open \"$d/$f\" >/dev/null 2>&1 &";
	if (sh_ok(script, dir, n)) {
		say(a, "Starter episoden...", GREEN);
	} else {
		say(a, "Fandt ingen fil til episoden i video-mappen.", RED);
	};
};

// --- pictures ---

// Loads a picture and cuts/scales it to fill w x h exactly.
fn load_cover(path: str, w: int, h: int) (viper::image | void) = {
	let src = match (viper::load_png(path)) {
	case let im: viper::image => yield im;
	case viper::imgerror => return;
	};
	defer viper::image_free(&src);
	const sa = src.w: f64 / src.h: f64, da = w: f64 / h: f64;
	let cw = src.w, ch = src.h;
	if (sa > da) {
		cw = (src.h: f64 * da): int;
	} else {
		ch = (src.w: f64 / da): int;
	};
	let cut = match (viper::crop(&src, (src.w - cw) / 2, (src.h - ch) / 2, cw, ch)) {
	case let c: viper::image => yield c;
	case nomem => return;
	};
	defer viper::image_free(&cut);
	match (viper::resize(&cut, w, h)) {
	case let r: viper::image => return r;
	case nomem => return;
	};
};

fn load_pictures(a: *app) void = {
	match (load_cover("assets/bns/banner.png", 890, 140)) {
	case let im: viper::image =>
		a.banner = im;
		a.banner_ok = true;
	case void => void;
	};
	match (load_cover("assets/bns/portrait.png", 70, 70)) {
	case let im: viper::image =>
		a.portrait = im;
		a.portrait_ok = true;
	case void => void;
	};
    match (load_cover("assets/bns/logo.png", 180, 92)) {
	case let im: viper::image =>
		a.logo = im;
		a.logo_ok = true;
	case void => void;
	};
	match (load_cover("assets/bns/episode.png", 336, 150)) {
	case let im: viper::image =>
		a.episode = im;
		a.episode_ok = true;
	case void => void;
	};
	let pb: [64]u8 = [0...];
	for (let i = 0z; i < NEP; i += 1) {
		const p = fmt::bsprintf(pb, "assets/bns/ep-{}{}.png",
			if (i + 1 < 10) "0" else "", i + 1)!;
		match (load_cover(p, 336, 150)) {
		case let im: viper::image =>
			a.shots[i] = im;
			a.shot_ok[i] = true;
		case void => void;
		};
	};
};

fn free_pictures(a: *app) void = {
	if (a.banner_ok) viper::image_free(&a.banner);
	if (a.portrait_ok) viper::image_free(&a.portrait);
    if (a.logo_ok) viper::image_free(&a.logo);
	if (a.episode_ok) viper::image_free(&a.episode);
	for (let i = 0z; i < NEP; i += 1) {
	if (a.shot_ok[i]) viper::image_free(&a.shots[i]);
	};
};

// --- drawing helpers ---

fn inside(win: *viper::window, x: int, y: int, w: int, h: int) bool =
	win.mouse_x >= x && win.mouse_x < x + w && win.mouse_y >= y && win.mouse_y < y + h;

fn panel(win: *viper::window, x: int, y: int, w: int, h: int) void = {
	viper::round_rect(win, x, y, w, h, 12, EDGE);
	viper::round_rect(win, x + 1, y + 1, w - 2, h - 2, 11, PANEL);
};

// A rounded button; returns true when clicked.
fn btn(win: *viper::window, x: int, y: int, w: int, h: int, s: str, on: bool) bool = {
	const over = inside(win, x, y, w, h);
	const edge: viper::color = if (on || over) PINK_SOFT else EDGE;
	const bg: viper::color = if (on) 0xff5a1a40 else if (over) 0xff2f2347 else 0xff241a36;
	viper::round_rect(win, x, y, w, h, 8, edge);
	viper::round_rect(win, x + 1, y + 1, w - 2, h - 2, 7, bg);
	const tw = viper::text_width(s, 1);
	viper::text(win, x + (w - tw) / 2, y + (h - viper::FONT_H) / 2, s, TEXT);
	return over && viper::mouse_pressed(win);
};

fn thick(win: *viper::window, x0: f64, y0: f64, x1: f64, y1: f64, w: f64, col: viper::color) void = {
	const dx = x1 - x0, dy = y1 - y0;
	const l = math::sqrtf64(dx * dx + dy * dy);
	if (l < 0.5) return;
	const nx = -dy / l * w / 2.0, ny = dx / l * w / 2.0;
	const pts: [4](f64, f64) = [
		(x0 + nx, y0 + ny), (x1 + nx, y1 + ny),
		(x1 - nx, y1 - ny), (x0 - nx, y0 - ny),
	];
	viper::polygon(win, pts, col);
};

fn star(win: *viper::window, cx: int, cy: int, r: f64, col: viper::color) void = {
	let pts: [10](f64, f64) = [(0.0, 0.0)...];
	for (let k = 0z; k < 10; k += 1) {
		const ang = -math::PI / 2.0 + k: f64 * math::PI / 5.0;
		const rr = if (k % 2 == 0) r else r * 0.45;
		pts[k] = (cx: f64 + math::cosf64(ang) * rr, cy: f64 + math::sinf64(ang) * rr);
	};
	viper::polygon(win, pts, col);
};

// The status icon: a green tick, a pause sign or an empty ring.
fn status_icon(win: *viper::window, cx: int, cy: int, st: int, bg: viper::color) void = {
	switch (st) {
	case SEEN =>
		viper::circle(win, cx, cy, 8, GREEN);
		thick(win, (cx - 4): f64, cy: f64, (cx - 1): f64, (cy + 3): f64, 2.0, 0xff0d2a16);
		thick(win, (cx - 1): f64, (cy + 3): f64, (cx + 4): f64, (cy - 3): f64, 2.0, 0xff0d2a16);
	case PAUSED =>
		viper::circle(win, cx, cy, 8, GOLD);
		viper::rect(win, cx - 3, cy - 4, 2, 8, 0xff3a2a0a);
		viper::rect(win, cx + 1, cy - 4, 2, 8, 0xff3a2a0a);
	case =>
		viper::circle(win, cx, cy, 8, DIM);
		viper::circle(win, cx, cy, 6, bg);
	};
};

// Cherry blossom petals drifting through a box.
fn petals(win: *viper::window, t: f64, x: int, y: int, w: int, h: int, n: int) void = {
	for (let i = 0; i < n; i += 1) {
		const px = x + ((i * 137) + (t * (18.0 + (i % 4): f64 * 9.0)): int) % w;
		const py = y + ((i * 53) + (t * (12.0 + (i % 3): f64 * 7.0)): int) % h;
		const col: viper::color = if (i % 3 == 0) 0xffffb0d0 else if (i % 3 == 1) PINK_SOFT else 0xffd060a0;
		viper::circle(win, px, py, 2 + i % 2, col);
	};
};

// --- the parts of the window ---

fn draw_sidebar(win: *viper::window, a: *app) void = {
	viper::rect(win, 0, 0, 190, H, SIDE);
	viper::rect(win, 189, 0, 1, H, EDGE);
	// Logo: a red brush stroke behind white letters.
	// Logo: a red brush stroke behind white letters.
	if (a.logo_ok) {
		viper::draw_image(win, &a.logo, 5, 14);
	} else {
		// Logo: a red brush stroke behind white letters.
		thick(win, 14.0, 70.0, 176.0, 40.0, 10.0, RED);
		viper::text_scaled(win, 12, 18, "BLADE &", TEXT, 3);
		viper::text_scaled(win, 40, 48, "SOUL", TEXT, 3);
		viper::text(win, 42, 84, "Anime Tracker", PINK_SOFT);
	};

	for (let i = 0; i < len(PAGES): int; i += 1) {
		const y = 130 + i * 50;
		const on = a.page == i;
		const over = inside(win, 10, y, 170, 40);
		if (on || over) {
			const hl: viper::color = if (on) 0xff5a1a40 else 0xff241a36;
			viper::round_rect(win, 10, y, 170, 40, 10, hl);
		};
		if (on) viper::rect(win, 10, y + 8, 3, 24, PINK);
		// Small icons.
		const ix = 30, iy = y + 20;
		const ic: viper::color = if (on) PINK_SOFT else DIM;
		switch (i) {
		case 0 =>
			const roof: [3](f64, f64) = [
				((ix - 9): f64, iy: f64), ((ix + 9): f64, iy: f64), (ix: f64, (iy - 9): f64),
			];
			viper::polygon(win, roof, ic);
			viper::rect(win, ix - 6, iy, 12, 8, ic);
		case 1 =>
			viper::rect(win, ix - 7, iy - 9, 14, 18, ic);
			viper::rect(win, ix - 4, iy - 5, 8, 2, SIDE);
			viper::rect(win, ix - 4, iy - 1, 8, 2, SIDE);
			viper::rect(win, ix - 4, iy + 3, 6, 2, SIDE);
		case 2 =>
			viper::rect(win, ix - 8, iy + 1, 4, 8, ic);
			viper::rect(win, ix - 2, iy - 5, 4, 14, ic);
			viper::rect(win, ix + 4, iy - 9, 4, 18, ic);
		case =>
			viper::circle(win, ix, iy, 9, ic);
			const hole: viper::color = if (on) 0xff5a1a40 else SIDE;
			viper::circle(win, ix, iy, 4, hole);
		};
		viper::text(win, 50, y + 12, PAGES[i: size], if (on) TEXT else DIM);
		if (over && viper::mouse_pressed(win) && a.page != i) {
			unfocus_all(a);
			save(a);
			a.page = i;
		};
	};

	petals(win, a.t, 10, 360, 170, 260, 10);
	viper::text(win, 34, H - 34, "Hare + ViperGui", DIM);
};

fn draw_header(win: *viper::window, a: *app) void = {
	const x = 200, y = 10, w = 890, h = 140;
	viper::clip(win, x, y, w, h);
	if (a.banner_ok) {
		viper::draw_image(win, &a.banner, x, y);
	} else {
		for (let k = 0; k < h; k += 4) {
			viper::rect(win, x, y + k, w, 4, viper::mix(0xff2a1440, 0xff12091c, k: f64 / h: f64));
		};
		// Mountains and a temple roof in the distance.
		const hills: [5](f64, f64) = [
			(200.0, 150.0), (330.0, 70.0), (460.0, 120.0), (560.0, 80.0), (700.0, 150.0),
		];
		viper::polygon(win, hills, 0xff1e1030);
		const roof: [4](f64, f64) = [(286.0, 64.0), (374.0, 64.0), (360.0, 54.0), (300.0, 54.0)];
		viper::polygon(win, roof, 0xff3a1a3a);
		viper::rect(win, 304, 64, 52, 16, 0xff2a1430);
		// The title with a red brush stroke.
		thick(win, 400.0, 108.0, 960.0, 52.0, 26.0, RED);
		thick(win, 430.0, 118.0, 900.0, 84.0, 8.0, 0xff901020);
		viper::text_scaled(win, 405, 46, "BLADE & SOUL", 0xff1a0a14, 5);
		viper::text_scaled(win, 402, 43, "BLADE & SOUL", TEXT, 5);
		viper::text_scaled(win, 640, 104, "Anime Tracker", TEXT, 2);
	};
	petals(win, a.t, x, y, w, h, 24);
	viper::noclip(win);
};

fn draw_progress(win: *viper::window, a: *app) void = {
	panel(win, 200, 160, 560, 90);
	if (a.portrait_ok) {
		viper::draw_image(win, &a.portrait, 210, 170);
	} else {
		viper::round_rect(win, 210, 170, 70, 70, 8, 0xff2a1a40);
		thick(win, 222.0, 228.0, 268.0, 182.0, 5.0, 0xffd8d8e8);
		thick(win, 222.0, 228.0, 232.0, 218.0, 7.0, RED);
		petals(win, a.t, 212, 172, 66, 66, 4);
	};
	const seen = count(a, SEEN);
	const pct = seen * 100 / NEP: int;
	viper::text(win, 295, 168, "Min fremdrift", DIM);
	viper::text_scaled(win, 295, 186, "Sæson 1", TEXT, 2);
	viper::round_rect(win, 295, 216, 400, 10, 5, 0xff2a1a40);
	if (seen > 0) viper::round_rect(win, 295, 216, 400 * seen / NEP: int, 10, 5, PINK);
	let b: [48]u8 = [0...];
	viper::text(win, 295, 230, fmt::bsprintf(b, "Set: {} / {} episoder", seen, NEP)!, TEXT);
	const ps = fmt::bsprintf(b, "{}%", pct)!;
	viper::text_scaled(win, 750 - 10 - viper::text_width(ps, 2), 222, ps, TEXT, 2);

	// The four counters.
	const nums: [4]int = [seen, count(a, PAUSED), favs(a), count(a, MISSING)];
	const labels: [4]str = ["Sete", "Pause", "Favorit", "Mangler"];
	for (let i = 0z; i < 4; i += 1) {
		const x = 770 + i: int * 82, y = 160;
		panel(win, x, y, 74, 90);
		const cx = x + 37, cy = y + 22;
		switch (i) {
		case 0 =>
			const tri: [3](f64, f64) = [
				((cx - 6): f64, (cy - 9): f64), ((cx + 9): f64, cy: f64), ((cx - 6): f64, (cy + 9): f64),
			];
			viper::polygon(win, tri, PINK_SOFT);
		case 1 =>
			viper::rect(win, cx - 6, cy - 8, 4, 16, PINK_SOFT);
			viper::rect(win, cx + 2, cy - 8, 4, 16, PINK_SOFT);
		case 2 =>
			star(win, cx, cy, 10.0, GOLD);
		case =>
			viper::circle(win, cx, cy, 9, PINK_SOFT);
			viper::circle(win, cx, cy, 6, PANEL);
		};
		const ns = fmt::bsprintf(b, "{}", nums[i])!;
		viper::text_scaled(win, cx - viper::text_width(ns, 2) / 2, y + 38, ns, TEXT, 2);
		viper::text(win, cx - viper::text_width(labels[i], 1) / 2, y + 68, labels[i], DIM);
	};
};

fn draw_table(win: *viper::window, a: *app) void = {
	panel(win, 200, 260, 520, 430);
	viper::text_scaled(win, 214, 270, "Episoder - Sæson 1", TEXT, 2);
	viper::rect(win, 210, 300, 500, 22, 0xff2a1a40);
	viper::text(win, 216, 303, "#", DIM);
	viper::text(win, 250, 303, "Titel", DIM);
	viper::text(win, 448, 303, "Status", DIM);
	viper::text(win, 520, 303, "Set", DIM);
	viper::text(win, 610, 303, "Sendt", DIM);
	let b: [8]u8 = [0...];
	for (let i = 0z; i < NEP; i += 1) {
		const y = 326 + i: int * 27;
		const on = i == a.sel;
		const over = inside(win, 210, y, 500, 26);
		let bg: viper::color = if (i % 2 == 0) PANEL else 0xff21173a;
		if (on) {
			bg = 0xff4a1a40;
			viper::round_rect(win, 209, y - 1, 502, 28, 6, PINK);
			viper::round_rect(win, 210, y, 500, 26, 5, bg);
		} else {
			if (over) bg = 0xff2a1f45;
			viper::rect(win, 210, y, 500, 26, bg);
		};
		const ty = y + 5;
		viper::text(win, 216, ty, fmt::bsprintf(b, "{}{}", if (i < 9) "0" else "", i + 1)!, TEXT);
		viper::text(win, 250, ty, TITLES[i], TEXT);
		if (a.fav[i]) star(win, 260 + viper::text_width(TITLES[i], 1), y + 13, 6.0, GOLD);
		status_icon(win, 470, y + 13, a.status[i], bg);
		const label = switch (a.status[i]) {
		case SEEN => yield "Set";
		case PAUSED => yield "Pause";
		case => yield "Mangler";
		};
		const lc: viper::color = switch (a.status[i]) {
		case SEEN => yield GREEN;
		case PAUSED => yield GOLD;
		case => yield DIM;
		};
		viper::text(win, 520, ty, label, lc);
		viper::text(win, 610, ty, AIRED[i], DIM);
		if (over && viper::mouse_pressed(win) && !on) {
			unfocus_all(a);
			save(a);
			a.sel = i;
		};
	};
};

fn draw_detail(win: *viper::window, a: *app) void = {
	const i = a.sel;
	const x = 730, y = 260;
	panel(win, x, y, 360, 430);
	let b: [64]u8 = [0...];
	viper::text_scaled(win, x + 14, y + 10, fmt::bsprintf(b, "Episode {}{}",
		if (i < 9) "0" else "", i + 1)!, TEXT, 2);

	// The picture (or a drawn placeholder).
	const ix = x + 12, iy = y + 38;
	if (a.shot_ok[i]) {
		viper::draw_image(win, &a.shots[i], ix, iy);
	} else if (a.episode_ok) {
		viper::draw_image(win, &a.episode, ix, iy);
	} else {
		viper::clip(win, ix, iy, 336, 150);
		for (let k = 0; k < 150; k += 5) {
			viper::rect(win, ix, iy + k, 336, 5, viper::mix(0xff3a1a50, 0xff120818, k: f64 / 150.0));
		};
		thick(win, (ix + 20): f64, (iy + 140): f64, (ix + 320): f64, (iy + 10): f64, 14.0, 0xff901030);
		thick(win, (ix + 40): f64, (iy + 145): f64, (ix + 330): f64, (iy + 30): f64, 3.0, 0xffe8e0f0);
		const big = fmt::bsprintf(b, "{}{}", if (i < 9) "0" else "", i + 1)!;
		viper::text_scaled(win, ix + 16, iy + 14, big, 0x88ffffff, 5);
		petals(win, a.t, ix, iy, 336, 150, 8);
		viper::noclip(win);
	};
	// A play button on the picture.
	viper::circle(win, ix + 168, iy + 75, 24, PINK);
	viper::circle(win, ix + 168, iy + 75, 21, 0xff3a1030);
	const tri: [3](f64, f64) = [
		((ix + 161): f64, (iy + 63): f64), ((ix + 181): f64, (iy + 75): f64), ((ix + 161): f64, (iy + 87): f64),
	];
	viper::polygon(win, tri, PINK_SOFT);
	if (inside(win, ix + 144, iy + 51, 48, 48) && viper::mouse_pressed(win)) play(a, i);

	viper::text_scaled(win, x + 14, y + 198, TITLES[i], TEXT, 2);
	if (a.fav[i]) star(win, x + 24 + viper::text_width(TITLES[i], 2), y + 213, 9.0, GOLD);

	viper::text(win, x + 14, y + 236, fmt::bsprintf(b, "{} min  -  Sendt {}  -  Ep. {}",
		EP_MIN, AIRED[i], i + 1)!, DIM);
	const seen = if (a.status[i] == SEEN && a.seen_n[i] > 0)
		fmt::bsprintf(b, "Set den {}", seen_str(a, i))!
		else if (a.status[i] == PAUSED) "På pause" else "Ikke set endnu";
	viper::text(win, x + 14, y + 256, seen, if (a.status[i] == SEEN) GREEN else DIM);

	viper::text(win, x + 14, y + 284, "Din note:", GOLD);
	if (viper::textbox(win, &a.notes[i], x + 12, y + 302, 336, "Skriv en note til episoden...")) {
		a.notes[i].focused = false;
		save(a);
		say(a, "Note gemt.", GREEN);
	};

	const seen_lbl = if (a.status[i] == SEEN) "Fjern som set" else "Marker som set";
	if (btn(win, x + 12, y + 344, 160, 34, seen_lbl, a.status[i] == SEEN)) toggle_seen(a, i);
	if (btn(win, x + 180, y + 344, 80, 34, "Favorit", a.fav[i])) toggle_fav(a, i);
	if (btn(win, x + 268, y + 344, 80, 34, "Pause", a.status[i] == PAUSED)) toggle_pause(a, i);
	if (btn(win, x + 12, y + 386, 336, 34, "Afspil (lokal)", false)) play(a, i);
};

fn draw_overview(win: *viper::window, a: *app) void = {
	draw_header(win, a);
	draw_progress(win, a);
	draw_table(win, a);
	draw_detail(win, a);
};

fn page_title(win: *viper::window, s: str, sub: str) void = {
	viper::text_scaled(win, 214, 22, s, TEXT, 3);
	thick(win, 214.0, 70.0, (214 + viper::text_width(s, 3)): f64, 66.0, 4.0, RED);
	viper::text(win, 214, 80, sub, DIM);
};

fn draw_notes(win: *viper::window, a: *app) void = {
	page_title(win, "Noter", "Skriv noter til hver episode. Enter gemmer.");
	let b: [32]u8 = [0...];
	for (let i = 0z; i < NEP; i += 1) {
		const y = 110 + i: int * 44;
		status_icon(win, 222, y + 15, a.status[i], BG);
		viper::text(win, 240, y + 7, fmt::bsprintf(b, "{}{}  {}",
			if (i < 9) "0" else "", i + 1, TITLES[i])!, TEXT);
		if (viper::textbox(win, &a.notes[i], 400, y, 680, "...")) {
			a.notes[i].focused = false;
			save(a);
			say(a, "Note gemt.", GREEN);
		};
	};
};

// "2026-01-05" < "2026-11-13": dates in this form sort like text.
fn date_less(x: str, y: str) bool = {
	const a = strings::toutf8(x), b = strings::toutf8(y);
	for (let i = 0z; i < len(a) && i < len(b); i += 1) {
		if (a[i] != b[i]) return a[i] < b[i];
	};
	return len(a) < len(b);
};

fn draw_stats(win: *viper::window, a: *app) void = {
	page_title(win, "Statistik", "Blade & Soul (Gonzo, 2014) - 1 sæson, 13 episoder.");
	const seen = count(a, SEEN), left = NEP: int - seen;
	let b: [64]u8 = [0...];
	// Three big tiles.
	const tiles: [3](str, int, viper::color) = [
		("Episoder set", seen, PINK),
		("Minutter set", seen * EP_MIN, GREEN),
		("Minutter tilbage", left * EP_MIN, GOLD),
	];
	for (let i = 0z; i < 3; i += 1) {
		const x = 214 + i: int * 296;
		panel(win, x, 110, 280, 110);
		viper::text(win, x + 16, 124, tiles[i].0, DIM);
		const s = fmt::bsprintf(b, "{}", tiles[i].1)!;
		viper::text_scaled(win, x + 16, 150, s, tiles[i].2, 4);
	};

	// All 13 episodes as a row of tiles.
	panel(win, 214, 236, 872, 120);
	viper::text(win, 230, 248, "Sæson 1", GOLD);
	for (let i = 0z; i < NEP; i += 1) {
		const x = 230 + i: int * 64, y = 274;
		const col: viper::color = switch (a.status[i]) {
		case SEEN => yield 0xff2a7a48;
		case PAUSED => yield 0xff8a6a1a;
		case => yield 0xff2a1a40;
		};
		viper::round_rect(win, x, y, 56, 56, 8, col);
		const n = fmt::bsprintf(b, "{}", i + 1)!;
		viper::text_scaled(win, x + 28 - viper::text_width(n, 2) / 2, y + 12, n, TEXT, 2);
		if (a.fav[i]) star(win, x + 46, y + 10, 6.0, GOLD);
		if (inside(win, x, y, 56, 56) && viper::mouse_pressed(win)) {
			a.sel = i;
			a.page = P_OVERVIEW;
		};
	};

	// Next up, favourites, first and last watched.
	panel(win, 214, 372, 872, 300);
	let next = NEP;
	for (let i = 0z; i < NEP; i += 1) {
		if (a.status[i] != SEEN) {
			next = i;
			break;
		};
	};
	viper::text(win, 230, 388, "Næste episode:", GOLD);
	if (next < NEP) {
		viper::text(win, 380, 388, fmt::bsprintf(b, "{} - {} (sendt {})",
			next + 1, TITLES[next], AIRED[next])!, TEXT);
	} else {
		viper::text(win, 380, 388, "Du har set det hele! Alle 13 episoder.", GREEN);
	};
	let first = "", last = "";
	for (let i = 0z; i < NEP; i += 1) {
		if (a.status[i] != SEEN || a.seen_n[i] == 0) continue;
		const d = seen_str(a, i);
		if (first == "" || date_less(d, first)) first = d;
		if (last == "" || date_less(last, d)) last = d;
	};
	viper::text(win, 230, 416, "Første set:", GOLD);
	viper::text(win, 380, 416, if (first == "") "-" else first, TEXT);
	viper::text(win, 230, 444, "Senest set:", GOLD);
	viper::text(win, 380, 444, if (last == "") "-" else last, TEXT);
	viper::text(win, 230, 480, "Favoritter:", GOLD);
	let fy = 480;
	let any = false;
	for (let i = 0z; i < NEP; i += 1) {
		if (!a.fav[i]) continue;
		any = true;
		star(win, 388, fy + 8, 6.0, GOLD);
		viper::text(win, 400, fy, fmt::bsprintf(b, "{} - {}", i + 1, TITLES[i])!, TEXT);
		fy += 22;
		if (fy > 650) break;
	};
	if (!any) viper::text(win, 380, 480, "Ingen endnu. Tryk Favorit på en episode.", DIM);
};

fn draw_settings(win: *viper::window, a: *app) void = {
	page_title(win, "Indstillinger", "Hvor ligger dine Blade & Soul-episoder?");
	panel(win, 214, 110, 872, 190);
	viper::text(win, 230, 126, "Video-mappe:", GOLD);
	if (viper::textbox(win, &a.folder, 230, 148, 700, "~/Videos/Blade & Soul")) {
		a.folder.focused = false;
		save(a);
		say(a, "Mappen er gemt.", GREEN);
	};
	if (btn(win, 940, 148, 130, 30, "Gem", false)) {
		a.folder.focused = false;
		save(a);
		say(a, "Mappen er gemt.", GREEN);
	};
	viper::text(win, 230, 196, "Afspil leder efter en fil med episodenummeret i navnet,", DIM);
	viper::text(win, 230, 216, "fx \"Blade & Soul E07.mkv\", \"Ep 7.mp4\" eller \"[Sub] Blade & Soul - 07.mkv\".", DIM);
	viper::text(win, 230, 236, "Filen åbnes i din normale videoafspiller.", DIM);
	viper::text(win, 230, 268, "Egne billeder: assets/bns/banner.png, portrait.png og ep-01.png ... ep-13.png", DIM);

	panel(win, 214, 316, 872, 110);
	viper::text(win, 230, 332, "Nulstil", GOLD);
	viper::text(win, 230, 354, "Sletter alle markeringer, favoritter og noter.", DIM);
	const lbl = if (a.confirm_t > 0.0) "Klik igen for at nulstille!" else "Nulstil alt";
	if (btn(win, 230, 380, 260, 32, lbl, a.confirm_t > 0.0)) {
		if (a.confirm_t > 0.0) {
			for (let i = 0z; i < NEP; i += 1) {
				a.status[i] = MISSING;
				a.fav[i] = false;
				a.seen_n[i] = 0;
				viper::textinput_clear(&a.notes[i]);
			};
			a.confirm_t = 0.0;
			save(a);
			say(a, "Alt er nulstillet.", RED);
		} else {
			a.confirm_t = 3.0;
		};
	};
	panel(win, 214, 442, 872, 120);
	viper::text(win, 230, 458, "MEGA sync", GOLD);
	switch (a.mega) {
	case 1 =>
		viper::text(win, 230, 482, "Synkroniseres med MEGA: /HPO/BnS-Tracker", GREEN);
	case 3 =>
		viper::text(win, 230, 482, "MEGAcmd er ikke installeret (mega.io/cmd).", RED);
	case =>
		viper::text(win, 230, 482, "Ikke sat op endnu. Du skal være logget ind i MEGAcmd.", DIM);
		if (btn(win, 230, 512, 260, 32, "Sync med MEGA", false)) mega_setup(a);
	};
	viper::text(win, 230, 580, "Data gemmes i ~/.local/share/bns-tracker/", DIM);
};

fn draw_message(win: *viper::window, a: *app) void = {
	if (a.msg_t <= 0.0) return;
	const tw = viper::text_width(a.msg, 1);
	const x = 200 + (890 - tw) / 2;
	viper::round_rect(win, x - 14, 112, tw + 28, 30, 10, a.msg_col);
	viper::round_rect(win, x - 12, 114, tw + 24, 26, 9, SIDE);
	viper::text(win, x, 119, a.msg, TEXT);
};
// Text from the clipboard (or the selection for a middle click):
// wl-paste on Wayland, xclip on X11, PowerShell in WSL.
fn clip_text(primary: bool) ([]u8 | void) = {
	const ps = "powershell.exe -NoProfile -Command \"[Console]::OutputEncoding=[Text.Encoding]::UTF8; Get-Clipboard\" 2>/dev/null | tr -d '\\r' | tr '\\n' ' '";
	const sh = if (primary)
		"wl-paste --no-newline --primary 2>/dev/null || xclip -o -selection primary 2>/dev/null"
		else "wl-paste --no-newline 2>/dev/null || xclip -o -selection clipboard 2>/dev/null";
	const full = strings::concat("(", sh, " || ", ps, ") > /tmp/bns-clip.txt")!;
	defer free(full);
	sh_ok(full, "", "");
	const f = match (os::open("/tmp/bns-clip.txt")) {
	case let f: io::file => yield f;
	case => return;
	};
	defer io::close(f)!;
	const data = match (io::drain(f)) {
	case let d: []u8 => yield d;
	case => return;
	};
	// Only real UTF-8 text may go into a text field.
	match (strings::fromutf8(data)) {
	case str => return data;
	case => {
		free(data);
		return;
	};
	};
};

// Adds the text at the end of the field; line breaks become spaces.
fn paste_into(tb: *viper::textinput, data: []u8) void = {
	for (let i = 0z; i < len(data) && tb.length < len(tb.buf); i += 1) {
		const c: u8 = if (data[i] == 10 || data[i] == 13 || data[i] == 9) 32 else data[i];
		tb.buf[tb.length] = c;
		tb.length += 1;
	};
};

// The text field under the mouse on this page, if any.
fn box_at(win: *viper::window, a: *app) nullable *viper::textinput = {
	switch (a.page) {
	case P_SETTINGS =>
		if (inside(win, 230, 148, 700, 30)) return &a.folder;
	case P_NOTES =>
		for (let i = 0z; i < NEP; i += 1) {
			if (inside(win, 400, 110 + i: int * 44, 680, 30)) return &a.notes[i];
		};
	case P_OVERVIEW =>
		if (inside(win, 742, 562, 336, 30)) return &a.notes[a.sel];
	case => void;
	};
	return null;
};

fn focused_box(a: *app) nullable *viper::textinput = {
	if (a.folder.focused) return &a.folder;
	for (let i = 0z; i < NEP; i += 1) {
		if (a.notes[i].focused) return &a.notes[i];
	};
	return null;
};

// Ctrl+V, or a right/middle click on a text field, pastes.
fn paste(win: *viper::window, a: *app) void = {
	const ctrl = win.keys[224] != 0 || win.keys[228] != 0;   // left/right Ctrl
	const ctrl_v = ctrl && viper::key_pressed(win, viper::key::V);
	const clicks = viper::mouse_clicks(win);
	const right = clicks & viper::RIGHT_BUTTON != 0;
	const middle = clicks & viper::MIDDLE_BUTTON != 0;
	if (!ctrl_v && !right && !middle) return;
	if (right || middle) {
	match (box_at(win, a)) {
	case null => return;
	case let t: *viper::textinput =>
			unfocus_all(a);
			t.focused = true;
		};
	};
	const tb = match (focused_box(a)) {
	case null => return;
	case let t: *viper::textinput => yield t;
	};
	const data = match (clip_text(middle && !ctrl_v)) {
	case let d: []u8 => yield d;
	case void => return;
	};
	defer free(data);
	paste_into(tb, data);
};
fn keys(win: *viper::window, a: *app) bool = {
	if (viper::key_pressed(win, viper::key::ESCAPE)) {
		if (!any_focused(a)) return false;
		unfocus_all(a);
		save(a);
	};
	if (any_focused(a) || a.page != P_OVERVIEW) return true;
	if (viper::key_pressed(win, viper::key::UP) && a.sel > 0) a.sel -= 1;
	if (viper::key_pressed(win, viper::key::DOWN) && a.sel + 1 < NEP) a.sel += 1;
	if (viper::key_pressed(win, viper::key::SPACE)) toggle_seen(a, a.sel);
	if (viper::key_pressed(win, viper::key::F)) toggle_fav(a, a.sel);
	if (viper::key_pressed(win, viper::key::RETURN)) play(a, a.sel);
	return true;
};

export fn main() void = {
	const win = match (viper::open("Blade & Soul: Anime Tracker", W, H)) {
	case let w: *viper::window =>
		yield w;
	case let e: viper::error =>
		fmt::fatal("viper:", viper::strerror(e));
	case nomem =>
		fmt::fatal("viper: out of memory");
	};
	defer viper::close(win);
    	match (viper::load_png("assets/bns/bns-icon-64.png")) {
	case let icon: viper::image =>
		let i = icon;
		viper::set_icon(win, &i);
		viper::image_free(&i);
	case viper::imgerror => void;
	};

	let a = app { ... };
	load(&a);
    check_mega(&a);
	load_pictures(&a);
	defer free_pictures(&a);
	// Start on the first episode you haven't seen.
	for (let i = 0z; i < NEP; i += 1) {
		if (a.status[i] != SEEN) {
			a.sel = i;
			break;
		};
	};

	for (viper::frame(win)) {
		let dt = viper::delta(win);
		if (dt > 0.1) dt = 0.1;
		a.t += dt;
		a.msg_t -= dt;
		a.confirm_t -= dt;
        // Changed on another PC (MEGA)? Read it again.
		a.check_t -= dt;
		if (a.check_t <= 0.0) {
			a.check_t = 2.0;
			let pb: [512]u8 = [0...];
			const m = file_mtime(save_path(pb));
		if (m != 0 && m != a.mtime && !any_focused(&a)) {
				reset(&a);
				load(&a);
				say(&a, "Opdateret fra MEGA.", GREEN);
			};
		};
        paste(win, &a);
		if (!keys(win, &a)) break;
		viper::clear(win, BG);
		switch (a.page) {
		case P_NOTES =>
			draw_notes(win, &a);
		case P_STATS =>
			draw_stats(win, &a);
		case P_SETTINGS =>
			draw_settings(win, &a);
		case =>
			draw_overview(win, &a);
		};
		draw_sidebar(win, &a);
		draw_message(win, &a);
		viper::present(win);
	};
	save(&a);
};
