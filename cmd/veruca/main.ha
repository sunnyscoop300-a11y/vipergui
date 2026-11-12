// VERUCA v2 — a ViperGui window for hpo's image generator.
// Type a prompt (or load one from a .txt file), pick a format and let the
// dark mage weave. It runs ~/hpo/helpers/veruca-gen.py in the background,
// so the window stays alive while the picture is being made, shows the
// helper's messages (like OpenAI retries) and the finished picture, and
// keeps the last pictures as thumbnails. Esc quits.
use fmt;
use io;
use math;
use os;
use os::exec;
use strings;
use viper;

def W: int = 900;
def H: int = 620;
def PREV: int = 396;          // the preview area is PREV x PREV pixels
def THUMB: int = 64;
def NHIST: size = 6;
def LOG: str = "/tmp/veruca-v2.log";

def PURPLE: viper::color = 0xff9b5cff;
def GOLD: viper::color = 0xffffc83a;
def RED: viper::color = 0xffff5a6a;
def GREEN: viper::color = 0xff5cff9b;
def INK: viper::color = 0xff0e0a16;

const RATIOS: [5]str = ["1:1", "2:3", "3:2", "9:16", "16:9"];

// Veruca Dumont's colours: night purple with gold.
const DARK_MAGE: viper::theme = viper::theme {
	bg = 0xff0e0a16,
	panel = 0xff1a1326,
	border = 0xff4a3670,
	text = 0xffeee6ff,
	text_dim = 0xff9a8cb8,
	widget = 0xff241a36,
	widget_hot = 0xff2f2347,
	accent = 0xff9b5cff,
	accent_hot = 0xffb07dff,
	accent_active = 0xff7a3fe0,
};

// A string kept in a fixed buffer, so it outlives the data it came from.
type sbuf = struct {
	b: [512]u8,
	n: size,
};

fn sset(s: *sbuf, v: str) void = {
	const d = strings::toutf8(v);
	let n = if (len(d) > len(s.b)) len(s.b) else len(d);
	// never cut a UTF-8 character in half
	for (n > 0 && n < len(d) && (d[n] & 0xc0) == 0x80) n -= 1;
	s.b[..n] = d[..n];
	s.n = n;
};

fn sget(s: *sbuf) str = strings::fromutf8_unsafe(s.b[..s.n]);

type app = struct {
	prompt: viper::textinput,
	file: viper::textinput,
	ratio: size,
	running: bool,
	proc: exec::process,
	run_t: f64,
	poll_t: f64,
	status: sbuf,
	status_col: viper::color,
	last: sbuf,             // path of the picture shown in the preview
	preview: viper::image,
	preview_ok: bool,
	hist: [NHIST]viper::image,
	hist_ok: [NHIST]bool,
	hist_path: [NHIST]sbuf,
	t: f64,
    mode: int,       // 0 = TRYL, 1 = REDIGER
	ed: editor,
};

// --- helpers ---

fn minf(a: f64, b: f64) f64 = if (a < b) a else b;

fn home() str = match (os::getenv("HOME")) {
case let h: str => yield h;
case void => yield ".";
};

// "~/x.txt" -> "/home/tux/x.txt". The result must be freed.
fn expand(p: str) str = {
	if (strings::hasprefix(p, "~/")) {
		return strings::concat(home(), strings::trimprefix(p, "~"))!;
	};
	return strings::dup(p)!;
};

fn read_all(path: str) ([]u8 | void) = {
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

// Cuts s so it is at most maxw pixels wide in scale 1.
fn fit_text(s: str, maxw: int) str = {
	let n = len(s);
	for (n > 0 && viper::text_width(strings::fromutf8_unsafe(strings::toutf8(s)[..n]), 1) > maxw) {
		n -= 1;
		for (n > 0 && (strings::toutf8(s)[n] & 0xc0) == 0x80) n -= 1;
	};
	return strings::fromutf8_unsafe(strings::toutf8(s)[..n]);
};

// Scales a picture so it fits inside maxw x maxh, keeping its shape.
fn fit_image(img: *viper::image, maxw: int, maxh: int) (viper::image | nomem) = {
	const s = minf(maxw: f64 / img.w: f64, maxh: f64 / img.h: f64);
	let w = (img.w: f64 * s): int, h = (img.h: f64 * s): int;
	if (w < 1) w = 1;
	if (h < 1) h = 1;
	return viper::resize(img, w, h);
};

fn set_status(a: *app, s: str, col: viper::color) void = {
	sset(&a.status, s);
	a.status_col = col;
};

// --- loading pictures ---

fn show(a: *app, path: str) void = {
	match (viper::load_png(path)) {
	case let loaded: viper::image =>
		let big = loaded;
		defer viper::image_free(&big);
		match (fit_image(&big, PREV, PREV)) {
		case let small: viper::image =>
			if (a.preview_ok) viper::image_free(&a.preview);
			a.preview = small;
			a.preview_ok = true;
			sset(&a.last, path);
		case nomem => void;
		};
	case viper::imgerror =>
		set_status(a, "Kunne ikke åbne billedet.", RED);
	};
};

// Puts a new picture first in the row of thumbnails.
fn remember(a: *app, path: str) void = {
	const thumb = match (viper::load_png(path)) {
	case let loaded: viper::image =>
		let big = loaded;
		defer viper::image_free(&big);
		yield match (fit_image(&big, THUMB, THUMB)) {
		case let small: viper::image => yield small;
		case nomem => return;
		};
	case viper::imgerror =>
		return;
	};
	if (a.hist_ok[NHIST - 1]) viper::image_free(&a.hist[NHIST - 1]);
	for (let i = NHIST - 1; i > 0; i -= 1) {
		a.hist[i] = a.hist[i - 1];
		a.hist_ok[i] = a.hist_ok[i - 1];
		a.hist_path[i] = a.hist_path[i - 1];
	};
	a.hist[0] = thumb;
	a.hist_ok[0] = true;
	sset(&a.hist_path[0], path);
};

// Loads a prompt from a text file into the prompt field. Line breaks
// become spaces, because the field is one line.
fn load_prompt(a: *app) void = {
	const p = expand(viper::textinput_str(&a.file));
	defer free(p);
	const data = match (read_all(p)) {
	case let d: []u8 => yield d;
	case void =>
		set_status(a, "Fandt ikke filen.", RED);
		return;
	};
	defer free(data);
	let n = if (len(data) > len(a.prompt.buf)) len(a.prompt.buf) else len(data);
	for (n > 0 && n < len(data) && (data[n] & 0xc0) == 0x80) n -= 1;
	for (let i = 0z; i < n; i += 1) {
		// newline, carriage return and tab become a space
		a.prompt.buf[i] = if (data[i] == 10 || data[i] == 13 || data[i] == 9) 32 else data[i];
	};
	a.prompt.length = n;
	let msg: [128]u8 = [0...];
	set_status(a, fmt::bsprintf(msg, "Prompt hentet ({} tegn).", n)!, GREEN);
};

// --- running the generator ---

fn start(a: *app) void = {
	const prompt = strings::trim(viper::textinput_str(&a.prompt));
	if (len(prompt) == 0) {
		set_status(a, "Skriv en prompt først.", RED);
		return;
	};
	const full = strings::concat(prompt, " ", RATIOS[a.ratio])!;
	defer free(full);
	const script = strings::concat(home(), "/hpo/helpers/veruca-gen.py")!;
	defer free(script);
	// sh only passes the arguments on, so quotes in the prompt are safe.
	let cmd = match (exec::cmd("sh", "-c", "python3 \"$1\" \"$2\" > \"$3\" 2>&1",
			"veruca", script, full, LOG)) {
	case let c: exec::command => yield c;
	case =>
		set_status(a, "Kunne ikke starte python3.", RED);
		return;
	};
	exec::nullstd(&cmd)!;
	match (exec::start(&cmd)) {
	case let p: exec::process =>
		a.proc = p;
		a.running = true;
		a.run_t = 0.0;
		a.poll_t = 0.0;
		set_status(a, "Veruca væver dit billede...", PURPLE);
	case exec::error =>
		set_status(a, "Kunne ikke starte python3.", RED);
	};
};

// Reads the helper's log: the last line becomes the status, and when the
// helper is done, a VERUCA_OK line gives us the finished picture.
fn read_log(a: *app, finished: bool) void = {
	const data = match (read_all(LOG)) {
	case let d: []u8 => yield d;
	case void => return;
	};
	defer free(data);
	let start = 0z;
	for (let i = 0z; i <= len(data); i += 1) {
		if (i < len(data) && data[i] != 10) continue;   // 10 = newline
		const line = strings::trim(strings::fromutf8_unsafe(data[start..i]));
		start = i + 1;
		if (len(line) == 0) continue;
		if (strings::hasprefix(line, "VERUCA_OK: saved ")) {
			// Only when the helper has really finished.
			if (!finished) continue;
			const path = strings::trimprefix(line, "VERUCA_OK: saved ");
			show(a, path);
			remember(a, path);
			set_status(a, "Færdig! Billedet er gemt.", GREEN);
			return;
		} else if (strings::hasprefix(line, "VERUCA_ERROR: ")) {
			set_status(a, strings::trimprefix(line, "VERUCA_ERROR: "), RED);
		} else if (!finished) {
			set_status(a, strings::trimprefix(line, "[VERUCA] "), PURPLE);
		};
	};
};

fn poll(a: *app, dt: f64) void = {
	a.run_t += dt;
	a.poll_t += dt;
	match (exec::peek(&a.proc)) {
	case void =>
		// Still working: show its newest message twice a second.
		if (a.poll_t > 0.5) {
			a.poll_t = 0.0;
			read_log(a, false);
		};
	case exec::status =>
		a.running = false;
		set_status(a, "Veruca gav op uden besked.", RED);
		read_log(a, true);
	case exec::error =>
		a.running = false;
		set_status(a, "Fejl mens jeg ventede på Veruca.", RED);
	};
};

// Opens a file or folder in the desktop's own program.
fn xdg_open(path: str) void = {
	let cmd = match (exec::cmd("sh", "-c", "xdg-open \"$1\" >/dev/null 2>&1 &", "open", path)) {
	case let c: exec::command => yield c;
	case => return;
	};
	exec::nullstd(&cmd)!;
	match (exec::start(&cmd)) {
	case let p: exec::process =>
		match (exec::wait(&p)) { case => void; };
	case => void;
	};
};
// Text from the clipboard (Ctrl+V) or the selection (middle click),
// fetched with wl-paste on Wayland or xclip on X11.
fn clip_text(primary: bool) ([]u8 | void) = {
	const sh = if (primary)
		"wl-paste --no-newline --primary 2>/dev/null || xclip -o -selection primary 2>/dev/null > /tmp/veruca-v2-clip.txt"
		else "wl-paste --no-newline 2>/dev/null || xclip -o -selection clipboard 2>/dev/null";
	const full = strings::concat("(", sh, ") > /tmp/veruca-v2-clip.txt")!;
	defer free(full);
	let cmd = match (exec::cmd("sh", "-c", full)) {
	case let c: exec::command => yield c;
	case => return;
	};
	exec::nullstd(&cmd)!;
	match (exec::start(&cmd)) {
	case let p: exec::process =>
		match (exec::wait(&p)) { case => void; };
	case => return;
	};
	return read_all("/tmp/veruca-v2-clip.txt");
};

// Ctrl+V pastes into the field that has focus; a middle click pastes the
// selection into the field under the mouse.
fn paste(win: *viper::window, a: *app) void = {
	const ctrl = win.keys[224] != 0 || win.keys[228] != 0;   // left/right Ctrl
	const ctrl_v = ctrl && viper::key_pressed(win, viper::key::V);
		const middle = viper::mouse_clicks(win) & (viper::RIGHT_BUTTON | viper::MIDDLE_BUTTON) != 0;
	if (!ctrl_v && !middle) return;
	if (middle) {
		const over_prompt = win.mouse_y >= 98 && win.mouse_y < 128;
		const over_file = win.mouse_y >= 164 && win.mouse_y < 194;
		if (win.mouse_x < 450 || (!over_prompt && !over_file)) return;
		a.prompt.focused = over_prompt;
		a.file.focused = over_file;
	};
	const tb = if (a.prompt.focused) &a.prompt
		else if (a.file.focused) &a.file
		else return;
	const data = match (clip_text(false)) {
	case let d: []u8 => yield d;
	case void => return;
	};
	defer free(data);
	let n = len(data);
	if (tb.length + n > len(tb.buf)) n = len(tb.buf) - tb.length;
	for (n > 0 && n < len(data) && (data[n] & 0xc0) == 0x80) n -= 1;
	for (let i = 0z; i < n; i += 1) {
		// newline, carriage return and tab become a space
		tb.buf[tb.length + i] = if (data[i] == 10 || data[i] == 13 || data[i] == 9) 32 else data[i];
	};
	tb.length += n;
};
// --- drawing ---

// A clickable chip. Returns true when clicked.
fn chip(win: *viper::window, x: int, y: int, w: int, h: int, s: str,
		on: bool, sc: int) bool = {
	const over = win.mouse_x >= x && win.mouse_x < x + w
		&& win.mouse_y >= y && win.mouse_y < y + h;
	const bg: viper::color = if (on) PURPLE else if (over) 0xff2f2347 else 0xff241a36;
	const edge: viper::color = if (on || over) GOLD else 0xff4a3670;
	viper::round_rect(win, x, y, w, h, 8, edge);               // the rounded edge
	viper::round_rect(win, x + 1, y + 1, w - 2, h - 2, 7, bg); // the button on top
	const tw = viper::text_width(s, sc);
	const fg: viper::color = if (on) INK else 0xffeee6ff;
	viper::text_scaled(win, x + (w - tw) / 2, y + (h - viper::FONT_H * sc) / 2, s, fg, sc);
	return over && viper::mouse_pressed(win);
};
fn spinner(win: *viper::window, cx: int, cy: int, t: f64) void = {
	for (let k = 0; k < 8; k += 1) {
		const a = t * 4.0 + k: f64 * math::PI / 4.0;
		const col = viper::mix(PURPLE, GOLD, k: f64 / 8.0);
		viper::circle(win, cx + (math::cosf64(a) * 14.0): int,
			cy + (math::sinf64(a) * 14.0): int, 2 + k / 3, col);
	};
};

fn draw(win: *viper::window, a: *app) void = {
	viper::clear(win, INK);
	// Header.
	viper::rect(win, 0, 0, W, 60, 0xff1a1326);
	viper::rect(win, 0, 60, W, 2, PURPLE);
	viper::text_scaled(win, 22, 14, "VERUCA v2", GOLD, 2);
	viper::text(win, 190, 22, "Den mørke magiker væver en højere kunst", 0xff9a8cb8);
	mode_tabs(win, a);

	// Preview.
	const px = 20, py = 80;
	viper::rect(win, px, py, PREV + 8, PREV + 8, 0xff1a1326);
	viper::outline(win, px, py, PREV + 8, PREV + 8, PURPLE);
	if (a.preview_ok) {
		viper::draw_image(win, &a.preview, px + 4 + (PREV - a.preview.w) / 2,
			py + 4 + (PREV - a.preview.h) / 2);
	} else {
		viper::text(win, px + 120, py + PREV / 2, "Intet billede endnu", 0xff9a8cb8);
	};
	if (a.running) spinner(win, px + PREV - 20, py + 28, a.t);

	// Prompt.
	const rx = 450;
	viper::text(win, rx, 80, "Prompt:", GOLD);
    if (chip(win, rx + 360, 74, 70, 22, "Ryd", false, 1)) viper::textinput_clear(&a.prompt);
	if (viper::textbox(win, &a.prompt, rx, 98, 430, "Beskriv dit billede...") && !a.running) {
		start(a);
	};
	viper::text(win, rx, 146, "...eller hent prompt fra en fil:", 0xff9a8cb8);
	viper::textbox(win, &a.file, rx, 164, 330, "~/jarbi.txt");
	if (chip(win, rx + 340, 164, 90, 30, "Hent", false, 1)) load_prompt(a);

	// Format.
	viper::text(win, rx, 214, "Format:", GOLD);
	for (let i = 0z; i < len(RATIOS); i += 1) {
	if (chip(win, rx + i: int * 87, 232, 80, 34, RATIOS[i], i == a.ratio, 1)) {
			a.ratio = i;
		};
	};

	// The big button.
	const label = if (a.running) "VERUCA ARBEJDER..." else "TRYL BILLEDET FREM";
	if (chip(win, rx, 290, 430, 44, label, a.running, 1) && !a.running) start(a);

	// Status.
	viper::rect(win, rx, 360, 430, 64, 0xff1a1326);
	viper::outline(win, rx, 360, 430, 64, 0xff4a3670);
	viper::text(win, rx + 10, 372, fit_text(sget(&a.status), 410), a.status_col);
	if (a.running) {
		let b: [48]u8 = [0...];
		viper::text(win, rx + 10, 398, fmt::bsprintf(b, "{} sekunder", a.run_t: int)!, 0xff9a8cb8);
	};

	// Open the picture / the folder.
	if (a.last.n > 0 && chip(win, rx, 436, 210, 32, "Åbn billede", false, 1)) {
		xdg_open(sget(&a.last));
	};
	if (chip(win, rx + 220, 436, 210, 32, "Åbn mappe", false, 1)) {
		const dir = strings::concat(home(), "/Pictures/veruca")!;
		defer free(dir);
		xdg_open(dir);
	};

	// The last pictures: click one to see it again.
	viper::text(win, 20, 498, "Seneste billeder:", GOLD);
	for (let i = 0z; i < NHIST; i += 1) {
		const x = 20 + i: int * (THUMB + 14), y = 516;
		viper::rect(win, x, y, THUMB + 6, THUMB + 6, 0xff1a1326);
		viper::outline(win, x, y, THUMB + 6, THUMB + 6, 0xff4a3670);
		if (!a.hist_ok[i]) continue;
		const im = &a.hist[i];
		viper::draw_image(win, im, x + 3 + (THUMB - im.w) / 2, y + 3 + (THUMB - im.h) / 2);
		const over = win.mouse_x >= x && win.mouse_x < x + THUMB + 6
			&& win.mouse_y >= y && win.mouse_y < y + THUMB + 6;
		if (over) viper::outline(win, x, y, THUMB + 6, THUMB + 6, GOLD);
		if (over && viper::mouse_pressed(win)) show(a, sget(&a.hist_path[i]));
	};
};

export fn main() void = {
	const win = match (viper::open("Veruca v2", W, H)) {
	case let w: *viper::window =>
		yield w;
	case let e: viper::error =>
		fmt::fatal("viper:", viper::strerror(e));
	case nomem =>
		fmt::fatal("viper: out of memory");
	};
	defer viper::close(win);
	win.theme = DARK_MAGE;
    match (viper::load_png("assets/veruca/veruca-v2-64.png")) {
	case let icon: viper::image =>
		let i = icon;
		viper::set_icon(win, &i);
		viper::image_free(&i);
	case viper::imgerror => void;
	};

	let a = app { ... };
	ed_init(&a.ed);
	a.ratio = 1;    // 2:3, the format OpenAI likes for tall pictures
	set_status(&a, "Klar. Skriv en prompt og tryl.", 0xff9a8cb8);
    match (viper::load_png("assets/veruca/veruca-v2-logo.png")) {
	case let logo: viper::image =>
		a.preview = logo;
		a.preview_ok = true;
	case viper::imgerror => void;
	};

	for (viper::frame(win)) {
		if (viper::key_pressed(win, viper::key::ESCAPE)) break;
		const dt = viper::delta(win);
		a.t += dt;
		if (a.running) poll(&a, dt);
		if (a.mode == 1) {
			edit_paste(win, &a.ed);
			edit_screen(win, &a, dt);
		} else {
			paste(win, &a);
			draw(win, &a);
		};
		viper::present(win);
	};

	if (a.running) {
		match (exec::kill(a.proc)) { case => void; };
		match (exec::wait(&a.proc)) { case => void; };
	};
	if (a.preview_ok) viper::image_free(&a.preview);
	for (let i = 0z; i < NHIST; i += 1) {
		if (a.hist_ok[i]) viper::image_free(&a.hist[i]);
	};
    edit_close(&a.ed);
};
