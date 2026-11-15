// KATCHA BOOTYLOADER — a gothic USB format utility, with Hare + ViperGui.
//
//   FORMAT QUEEN   formats a USB stick as exFAT, FAT32 or ext4
//   BOOTY ISO      writes a bootable ISO to a USB stick
//
// Only USB sticks are ever shown. Before anything is erased you must type
// the stick's name (like sdb). Then this same program is started again as
// root (via pkexec, see root.ha), checks once more that it is a USB stick
// and not a system disk, and does the work. No Python needed.
//
// Run it from the vipergui folder:  ./katcha
use fmt;
use io;
use math;
use math::random;
use os;
use os::exec;
use strings;
use viper;

def W: int = 1100;
def H: int = 700;
def MAXDEV: size = 16;

def BG: viper::color = 0xff120a1c;
def PANEL: viper::color = 0xff1d1030;
def PANEL_HOT: viper::color = 0xff2a1745;
def EDGE: viper::color = 0xff4a2a72;
def PURPLE: viper::color = 0xff9a4ae0;
def PURPLE_D: viper::color = 0xff6a2aa8;
def LILAC: viper::color = 0xffd6b4ff;
def TEXT: viper::color = 0xfff4ecff;
def DIM: viper::color = 0xff9a88b8;
def RED: viper::color = 0xffe03040;
def RED_D: viper::color = 0xffa01c2a;
def GOLD: viper::color = 0xffffd060;
def GREEN: viper::color = 0xff50e070;

type kind = enum { FORMAT, ISO };
type stage = enum { PICK, CONFIRM, WORK, RESULT };

type app = struct {
	drives: [MAXDEV]drive,
	n: size,
	data: []u8,            // lsblk's output; the strings above point into it
	sel: (size | void),
	selname: [16]u8,       // the chosen stick's name, kept across rescans
	sellen: size,
	tab: kind,
	fs: int,               // 0 exFAT, 1 FAT32, 2 ext4
	label: viper::textinput,
	iso: viper::textinput,
	confirm: viper::textinput,
	st: stage,
	scan_t: f64,
	pick_iso: bool,        // waiting for the file dialog
	pct: int,
	status: str,
	statusbuf: [256]u8,
	ok: bool,
	poll_t: f64,
	flash: f64,            // lightning
	bolt_x: int,
	t: f64,
	rng: random::random,
	sfx: int,
};

const FS_NAMES: [3]str = ["exFAT", "FAT32", "ext4"];
const FS_ARGS: [3]str = ["exfat", "fat32", "ext4"];

// --- small helpers ---

fn home() str = match (os::getenv("HOME")) {
case let h: str => yield h;
case void => yield ".";
};

fn data_path(buf: []u8, file: str) str =
	fmt::bsprintf(buf, "{}/.local/share/katcha/{}", home(), file)!;

// This program's own path, so pkexec can start it again as root.
fn self_path(buf: []u8) str = match (os::readlink("/proc/self/exe")) {
case let p: str => yield fmt::bsprintf(buf, "{}", p)!;
case => yield fmt::bsprintf(buf, "{}/katcha", os::getcwd())!;
};

fn clicked(win: *viper::window) bool =
	(viper::mouse_clicks(win) & viper::LEFT_BUTTON) != 0;

fn inside(win: *viper::window, x: int, y: int, w: int, h: int) bool =
	win.mouse_x >= x && win.mouse_x < x + w && win.mouse_y >= y && win.mouse_y < y + h;

fn set_input(tb: *viper::textinput, s: str) void = {
	const b = strings::toutf8(s);
	const n = if (len(b) > len(tb.buf)) len(tb.buf) else len(b);
	tb.buf[..n] = b[..n];
	tb.length = n;
};

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

// Runs a shell line and waits for it.
fn sh(script: str, a1: str, a2: str, a3: str, a4: str, a5: str) bool = {
	let cmd = match (exec::cmd("sh", "-c", script, "katcha", a1, a2, a3, a4, a5)) {
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

// "128 GB", "15.6 GB", "512 MB"
fn human(buf: []u8, b: u64) str = {
	const gb = b: f64 / 1000000000.0;
	if (gb >= 100.0) return fmt::bsprintf(buf, "{} GB", (gb + 0.5): u64)!;
	if (gb >= 1.0) {
		const tenths = (gb * 10.0 + 0.5): u64;
		return fmt::bsprintf(buf, "{}.{} GB", tenths / 10, tenths % 10)!;
	};
	return fmt::bsprintf(buf, "{} MB", b / 1000000)!;
};

fn clamp1(x: f64) f64 = if (x > 1.0) 1.0 else if (x < 0.0) 0.0 else x;

fn sel_drive(a: *app) nullable *drive = match (a.sel) {
case let i: size => yield &a.drives[i];
case void => yield null;
};

// --- finding USB sticks ---

fn scan(a: *app) void = {
	let pb: [512]u8 = [0...];
	const out = data_path(pb, "lsblk.txt");
	quiet("mkdir -p \"$(dirname \"$1\")\"", out, "", "", "", "");
	if (!sh(LSBLK, out, "", "", "", "")) return;
	const data = match (read_file(out)) {
	case let d: []u8 => yield d;
	case void => return;
	};
	free(a.data);
	a.data = data;
	a.n = usb_drives(data, a.drives[..]);
	// Keep the same stick chosen after a rescan.
	a.sel = void;
	for (let i = 0z; i < a.n; i += 1) {
		if (a.sellen > 0 && a.drives[i].name == strings::fromutf8_unsafe(a.selname[..a.sellen])) {
			a.sel = i;
		};
	};
	if (a.sel is void) a.sellen = 0;
};

fn choose(a: *app, i: size) void = {
	a.sel = i;
	const b = strings::toutf8(a.drives[i].name);
	const n = if (len(b) > len(a.selname)) len(a.selname) else len(b);
	a.selname[..n] = b[..n];
	a.sellen = n;
};

// --- picking an ISO with the desktop's own file dialog ---

fn pick_iso(a: *app) void = {
	let pb: [512]u8 = [0...];
	const out = data_path(pb, "iso.txt");
	match (os::remove(out)) {
	case => void;
	};
	if (!sh("( if command -v kdialog >/dev/null; then kdialog --getopenfilename \"$HOME\" "
		"'*.iso *.img|ISO-filer'; "
		"elif command -v zenity >/dev/null; then zenity --file-selection "
		"--file-filter='*.iso *.img'; fi > \"$1.tmp\"; mv \"$1.tmp\" \"$1\" ) &",
		out, "", "", "", "")) {
		return;
	};
	a.pick_iso = true;
};

fn poll_iso(a: *app) void = {
	let pb: [512]u8 = [0...];
	match (read_file(data_path(pb, "iso.txt"))) {
	case let d: []u8 =>
		let n = len(d);
		for (n > 0 && (d[n - 1] == 10 || d[n - 1] == 13)) n -= 1;
		if (n > 0) set_input(&a.iso, strings::fromutf8_unsafe(d[..n]));
		free(d);
		a.pick_iso = false;
	case void => void;
	};
};

// --- the dangerous part ---

fn start_job(a: *app) void = {
	const d = match (sel_drive(a)) {
	case let d: *drive => yield d;
	case null => return;
	};
	let pb: [512]u8 = [0...], hb: [512]u8 = [0...];
	const status = data_path(pb, "status.txt");
	const me = self_path(hb);
	match (os::remove(status)) {
	case => void;
	};
	// If you close the password box, pkexec gives up without a word:
	// then we write the error ourselves.
	const tail = "|| [ -s \"$ST\" ] || printf 'ERR\\t0\\tGodkendelsen blev afbrudt. Intet er slettet.\\n' > \"$ST\" ) &";
	let ok = false;
	if (a.tab == kind::FORMAT) {
		let label = strings::trim(viper::textinput_str(&a.label));
		if (len(label) == 0) label = "KATCHA";
		let sb: [512]u8 = [0...];
		const script = fmt::bsprintf(sb, "( ST=\"$5\"; pkexec \"$1\" --format \"$2\" \"$3\" \"$4\" \"$5\" {}", tail)!;
		ok = sh(script, me, d.path, FS_ARGS[a.fs], label, status);
	} else {
		const iso = strings::trim(viper::textinput_str(&a.iso));
		let sb: [512]u8 = [0...];
		const script = fmt::bsprintf(sb, "( ST=\"$4\"; pkexec \"$1\" --iso \"$2\" \"$3\" \"$4\" {}", tail)!;
		ok = sh(script, me, d.path, iso, status, "");
	};
	a.st = stage::WORK;
	a.pct = 0;
	a.status = fmt::bsprintf(a.statusbuf, "Venter på din adgangskode...")!;
	a.poll_t = 0.0;
	if (!ok) {
		a.st = stage::RESULT;
		a.ok = false;
		a.status = fmt::bsprintf(a.statusbuf, "Kunne ikke starte pkexec.")!;
	};
	a.sfx = 1;
};

fn poll_job(a: *app) void = {
	let pb: [512]u8 = [0...];
	const d = match (read_file(data_path(pb, "status.txt"))) {
	case let d: []u8 => yield d;
	case void => return;
	};
	defer free(d);
	let n = len(d);
	for (n > 0 && d[n - 1] == 10) n -= 1;
	let fl: [3]str = [""...];
	if (fields(d[..n], fl) < 3) return;
	a.pct = to_int(fl[1]): int;
	a.status = fmt::bsprintf(a.statusbuf, "{}", fl[2])!;
	if (fl[0] == "DONE") {
		a.st = stage::RESULT;
		a.ok = true;
		a.sfx = 2;
	} else if (fl[0] == "ERR") {
		a.st = stage::RESULT;
		a.ok = false;
		a.sfx = 3;
	};
};

// --- drawing ---

fn button(win: *viper::window, x: int, y: int, w: int, h: int, s: str,
		col: viper::color, on: bool) bool = {
	const over = on && inside(win, x, y, w, h);
	const bg = if (!on) 0xff2a2238: viper::color else if (over) viper::mix(col, 0xffffffff, 0.15) else col;
	viper::round_rect(win, x, y, w, h, 10, bg);
	viper::text(win, x + (w - viper::text_width(s, 1)) / 2, y + (h - 16) / 2, s,
		if (on) TEXT else DIM);
	return over && clicked(win);
};

fn chip(win: *viper::window, x: int, y: int, w: int, s: str, on: bool) bool = {
	const over = inside(win, x, y, w, 30);
	viper::round_rect(win, x, y, w, 30, 15, if (on) PURPLE else EDGE);
	viper::round_rect(win, x + 2, y + 2, w - 4, 26, 13, if (on) PURPLE_D else if (over) PANEL_HOT else PANEL);
	viper::text(win, x + (w - viper::text_width(s, 1)) / 2, y + 7, s, if (on) TEXT else LILAC);
	return over && clicked(win);
};

fn outlined(win: *viper::window, x: int, y: int, s: str, col: viper::color, sc: int) void = {
	viper::text_scaled(win, x + 2, y + 2, s, 0xff000000, sc);
	viper::text_scaled(win, x, y, s, col, sc);
};

// A zig-zag lightning bolt from the top down.
fn bolt(win: *viper::window, g: *app, x0: int, y0: int, y1: int, col: viper::color) void = {
	let x = x0, y = y0;
	let r = random::init(g.bolt_x: u64);
	for (y < y1) {
		const nx = x + random::u32n(&r, 41): int - 20;
		const ny = y + 18 + random::u32n(&r, 20): int;
		for (let w = -2; w <= 2; w += 1) viper::line(win, x + w, y, nx + w, ny, col);
		x = nx;
		y = ny;
	};
};

fn draw_side(win: *viper::window, a: *app, pic: *viper::image) void = {
	viper::rect(win, 0, 0, 340, H, 0xff0b0610);
	viper::draw_image(win, pic, 10, 10);
	if (a.flash > 0.0) {
		bolt(win, a, a.bolt_x, 10, 300, viper::mix(LILAC, 0xffffffff, clamp1(a.flash * 4.0)));
	};
	outlined(win, 20, 312, "KATCHA", PURPLE, 4);
	outlined(win, 20, 380, "BOOTYLOADER", LILAC, 2);
	viper::text(win, 22, 420, "v0.1.1  -  GOTHIC USB FORMAT UTILITY", DIM);
	viper::rect(win, 20, 448, 300, 1, EDGE);
	viper::text(win, 22, 462, "Kun USB-stik bliver vist.", DIM);
	viper::text(win, 22, 482, "Systemdiske bliver aldrig rørt.", DIM);
	viper::text(win, 22, 502, "Du skriver selv drevets navn,", DIM);
	viper::text(win, 22, 522, "før noget bliver slettet.", DIM);
	viper::text(win, 22, H - 30, "Hare + ViperGui", PURPLE);
};

fn draw_pick(win: *viper::window, a: *app) void = {
	const x0 = 364;
	viper::text_scaled(win, x0, 20, "USB-stik", TEXT, 2);
	if (button(win, W - 150, 18, 126, 30, "Søg igen", PURPLE_D, true)) scan(a);

	if (a.n == 0) {
		viper::round_rect(win, x0, 64, W - x0 - 24, 90, 12, PANEL);
		viper::text(win, x0 + 20, 92, "Ingen USB-stik fundet. Sæt et i - KATCHA leder hvert 3. sekund.", DIM);
	};
	let b: [64]u8 = [0...];
	for (let i = 0z; i < a.n; i += 1) {
		const d = &a.drives[i];
		const y = 64 + i: int * 70;
		if (y > 300) break;
		const on = match (a.sel) {
		case let s: size => yield s == i;
		case void => yield false;
		};
		const over = inside(win, x0, y, W - x0 - 24, 62);
		viper::round_rect(win, x0, y, W - x0 - 24, 62, 12, if (on) PURPLE else EDGE);
		viper::round_rect(win, x0 + 2, y + 2, W - x0 - 28, 58, 11, if (over) PANEL_HOT else PANEL);
		viper::text_scaled(win, x0 + 16, y + 10, d.model, TEXT, 1);
		viper::text(win, x0 + 16, y + 34, fmt::bsprintf(b, "{}   {}", d.path, d.parts)!, DIM);
		const sz = human(b, d.bytes);
		viper::text_scaled(win, W - 40 - viper::text_width(sz, 2), y + 16, sz, GOLD, 2);
		if (over && clicked(win)) choose(a, i);
	};

	// What to do with it.
	const y = 330;
	if (chip(win, x0, y, 170, "FORMAT QUEEN", a.tab == kind::FORMAT)) a.tab = kind::FORMAT;
	if (chip(win, x0 + 180, y, 150, "BOOTY ISO", a.tab == kind::ISO)) a.tab = kind::ISO;
	viper::round_rect(win, x0, y + 44, W - x0 - 24, 180, 12, PANEL);
	if (a.tab == kind::FORMAT) {
		viper::text(win, x0 + 20, y + 62, "Filsystem", DIM);
		for (let k = 0; k < 3; k += 1) {
			if (chip(win, x0 + 20 + k * 110, y + 84, 100, FS_NAMES[k: size], a.fs == k)) a.fs = k;
		};
		const hints: [3]str = [
			"exFAT: virker på Windows, Mac, Linux og konsoller. Store filer.",
			"FAT32: virker overalt, men højst 4 GB pr. fil.",
			"ext4: til Linux. Hurtigt, men Windows kan ikke læse det.",
		];
		viper::text(win, x0 + 20, y + 126, hints[a.fs: size], LILAC);
		viper::text(win, x0 + 20, y + 158, "Navn", DIM);
		if (viper::textbox(win, &a.label, x0 + 70, y + 152, 260, "KATCHA")) a.label.focused = false;
	} else {
		viper::text(win, x0 + 20, y + 62, "ISO-fil", DIM);
		if (viper::textbox(win, &a.iso, x0 + 20, y + 84, 520, "/home/tux/Downloads/linux.iso")) {
			a.iso.focused = false;
		};
		if (button(win, x0 + 554, y + 84, 150, 30, if (a.pick_iso) "Vælger..." else "Vælg ISO...",
				PURPLE_D, !a.pick_iso)) {
			pick_iso(a);
		};
		viper::text(win, x0 + 20, y + 130, "ISO'en skrives byte for byte, så stikket kan boote.", LILAC);
		viper::text(win, x0 + 20, y + 150, "Alt andet på stikket forsvinder.", LILAC);
	};

	// The big button.
	const ready = match (sel_drive(a)) {
	case *drive => yield a.tab == kind::FORMAT
		|| len(strings::trim(viper::textinput_str(&a.iso))) > 0;
	case null => yield false;
	};
	const big = if (a.tab == kind::FORMAT) "ULTIMATE ULTRA FORMAT QUEEN" else "SKRIV BOOTY ISO";
	if (button(win, x0, H - 100, W - x0 - 24, 64, big, RED_D, ready)) {
		viper::textinput_clear(&a.confirm);
		a.confirm.focused = true;
		a.st = stage::CONFIRM;
		a.sfx = 1;
	};
	if (!ready) {
		const s = if (a.sel is void) "Vælg et USB-stik først." else "Vælg en ISO-fil først.";
		viper::text(win, x0 + (W - x0 - 24 - viper::text_width(s, 1)) / 2, H - 28, s, DIM);
	};
};

fn draw_confirm(win: *viper::window, a: *app) void = {
	const d = match (sel_drive(a)) {
	case let d: *drive => yield d;
	case null =>
		a.st = stage::PICK;
		return;
	};
	const x = 380, y = 150, w = 700, h = 380;
	viper::round_rect(win, x - 4, y - 4, w + 8, h + 8, 18, RED);
	viper::round_rect(win, x, y, w, h, 14, 0xff1a0610);
	outlined(win, x + 30, y + 24, "SAFETY LOCK", RED, 3);
	let b: [160]u8 = [0...], sb: [32]u8 = [0...];
	viper::text_scaled(win, x + 30, y + 90, "ALT på dette drev bliver SLETTET:", TEXT, 1);
	viper::text_scaled(win, x + 30, y + 118, fmt::bsprintf(b, "{}  ({})", d.model, human(sb, d.bytes))!, GOLD, 2);
	viper::text(win, x + 30, y + 160, fmt::bsprintf(b, "{}   nu: {}", d.path, d.parts)!, DIM);
	const what = if (a.tab == kind::FORMAT)
		fmt::bsprintf(b, "Bliver til: {} med navnet {}", FS_NAMES[a.fs: size],
			if (a.label.length > 0) viper::textinput_str(&a.label) else "KATCHA")!
		else "Bliver til: et bootbart stik med ISO'en";
	viper::text(win, x + 30, y + 184, what, LILAC);

	viper::text(win, x + 30, y + 226, fmt::bsprintf(b, "Skriv {} for at bekræfte:", d.name)!, TEXT);
	const enter = viper::textbox(win, &a.confirm, x + 30, y + 250, 200, d.name);
	const typed = strings::trim(viper::textinput_str(&a.confirm));
	const match_ok = typed == d.name;
	if (match_ok) viper::text(win, x + 246, y + 256, "OK - tryk KØR", GREEN);
	if (button(win, x + 30, y + 306, 400, 48, "HAAAAHAHAHA!! KØR!", RED_D, match_ok)
			|| (enter && match_ok)) {
		start_job(a);
		return;
	};
	if (button(win, x + 450, y + 306, 220, 48, "Fortryd", PURPLE_D, true)) a.st = stage::PICK;
};

fn draw_work(win: *viper::window, a: *app) void = {
	const x = 380, y = 200, w = 690;
	const title = if (a.st == stage::WORK) "KATCHA ARBEJDER..."
		else if (a.ok) "HAAAAHAHAHA!!" else "NOGET GIK GALT";
	const col = if (a.st == stage::WORK) LILAC else if (a.ok) GOLD else RED;
	outlined(win, x, y, title, col, 4);
	viper::round_rect(win, x, y + 90, w, 34, 17, PANEL);
	if (a.pct > 0) {
		viper::round_rect(win, x, y + 90, w * a.pct / 100, 34, 17, if (a.ok || a.st == stage::WORK) PURPLE else RED);
	};
	let b: [16]u8 = [0...];
	const p = fmt::bsprintf(b, "{}%", a.pct)!;
	viper::text(win, x + (w - viper::text_width(p, 1)) / 2, y + 99, p, TEXT);
	viper::text(win, x, y + 146, a.status, if (a.st == stage::RESULT && !a.ok) RED else TEXT);
	if (a.st == stage::WORK) {
		viper::text(win, x, y + 180, "Træk IKKE stikket ud, før KATCHA er færdig!", GOLD);
	} else if (button(win, x, y + 200, 220, 44, "Tilbage", PURPLE_D, true)) {
		a.st = stage::PICK;
		scan(a);
	};
};

fn draw(win: *viper::window, a: *app, pic: *viper::image) void = {
	const bg = if (a.flash > 0.0) viper::mix(BG, 0xff5a3a88, clamp1(a.flash * 3.0)) else BG;
	viper::clear(win, bg);
	draw_side(win, a, pic);
	switch (a.st) {
	case stage::PICK => draw_pick(win, a);
	case stage::CONFIRM => draw_confirm(win, a);
	case stage::WORK, stage::RESULT => draw_work(win, a);
	};
};

export fn main() void = {
	// Started again as root by pkexec: do the work, no window.
	if (len(os::args) > 1 && strings::hasprefix(os::args[1], "--")) {
		root_main(os::args[1..]);
		return;
	};
	const win = match (viper::open("KATCHA BOOTYLOADER", W, H)) {
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
		panel = PANEL,
		border = EDGE,
		text = TEXT,
		text_dim = DIM,
		widget = 0xff241438,
		widget_hot = 0xff2e1a48,
		accent = PURPLE,
		accent_hot = LILAC,
		accent_active = PURPLE_D,
		...
	};
	match (viper::load_png("assets/katcha/katcha-icon-64.png")) {
	case let icon: viper::image =>
		viper::set_icon(win, &icon);
		viper::image_free(&icon);
	case viper::imgerror => void;
	};
	let pic = match (viper::load_png("assets/katcha/katcha.png")) {
	case let im: viper::image => yield im;
	case viper::imgerror => fmt::fatal("Mangler assets/katcha/katcha.png - kør fra vipergui-mappen");
	};
	defer viper::image_free(&pic);

	let a = app { rng = random::init(viper::ticks(): u64 + 35), sel = void, ... };
	set_input(&a.label, "KATCHA");
	scan(&a);

	const snd = viper::audio_open();
	defer viper::audio_close(snd);
	let s_thunder = viper::tone(viper::wave::NOISE, 220.0, 40.0, 1.2, 0.7, 0.01);
	const ha: [6]f64 = [523.3, 466.2, 415.3, 392.0, 349.2, 311.1];
	let s_laugh = viper::melody(viper::wave::SQUARE, ha, 0.11, 0.35);
	let s_click = viper::tone(viper::wave::TRIANGLE, 700.0, 500.0, 0.06, 0.3, 0.002);
	let s_fail = viper::tone(viper::wave::SQUARE, 200.0, 90.0, 0.5, 0.3, 0.01);
	defer viper::sound_free(&s_thunder);
	defer viper::sound_free(&s_laugh);
	defer viper::sound_free(&s_click);
	defer viper::sound_free(&s_fail);

	for (viper::frame(win)) {
		let dt = viper::delta(win);
		if (dt > 0.1) dt = 0.1;
		a.t += dt;
		if (a.flash > 0.0) a.flash -= dt;

		switch (a.st) {
		case stage::PICK =>
			a.scan_t += dt;
			if (a.scan_t >= 3.0) {
				a.scan_t = 0.0;
				scan(&a);
			};
			if (a.pick_iso) poll_iso(&a);
		case stage::WORK =>
			a.poll_t += dt;
			if (a.poll_t >= 0.2) {
				a.poll_t = 0.0;
				poll_job(&a);
			};
			// Thunder now and then while she works.
			if (a.flash <= 0.0 && random::u32n(&a.rng, 150) == 0) {
				a.flash = 0.2;
				a.bolt_x = 40 + random::u32n(&a.rng, 260): int;
				a.sfx = 4;
			};
		case => void;
		};

		draw(win, &a, &pic);
		if (viper::key_pressed(win, viper::key::ESCAPE)) {
			if (a.st == stage::CONFIRM) {
				a.st = stage::PICK;
			} else if (a.st != stage::WORK) {
				break;
			};
		};

		switch (a.sfx) {
		case 1 => viper::play(snd, &s_click, 0.5, 1.0);
		case 2 =>
			viper::play(snd, &s_thunder, 0.7, 1.0);
			viper::play(snd, &s_laugh, 0.6, 1.0);
			a.flash = 0.3;
			a.bolt_x = 170;
		case 3 => viper::play(snd, &s_fail, 0.6, 1.0);
		case 4 => viper::play(snd, &s_thunder, 0.4, 1.0);
		case => void;
		};
		a.sfx = 0;
		viper::audio_pump(snd);
		viper::present(win);
	};
	free(a.data);
};
