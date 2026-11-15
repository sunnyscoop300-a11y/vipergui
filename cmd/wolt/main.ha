// Wolt Mini — find food near you and order it, with Hare + ViperGui.
//
// The little Python helper next to this file (wolt.py) fetches the
// restaurants near your address and their pictures. When you click one,
// it opens the restaurant's own Wolt page in a small browser window,
// where you put food in the basket, log in and pay as normal.
//
// Run it from the vipergui folder:  ./wolt-mini
use fmt;
use io;
use os;
use os::exec;
use strings;
use viper;

def W: int = 1100;
def H: int = 700;
def MAX: size = 60;

def BG: viper::color = 0xfff4f6f9;
def CARD: viper::color = 0xffffffff;
def LINE: viper::color = 0xffdde3ea;
def BLUE: viper::color = 0xff009de0;
def BLUE_D: viper::color = 0xff0080b8;
def BLUE_SOFT: viper::color = 0xffe3f4fc;
def INK: viper::color = 0xff202125;
def DIM: viper::color = 0xff6b7280;
def GREEN: viper::color = 0xff1f9d55;
def RED: viper::color = 0xffd93a3a;
def STAR: viper::color = 0xfff5a623;

// The grid of restaurants.
def GRID_Y: int = 128;
def GRID_H: int = 544;
def CARD_W: int = 336;
def CARD_H: int = 228;
def STEP_X: int = 352;
def STEP_Y: int = 244;

type place = struct {
	slug: str,
	name: str,
	desc: str,
	est: str,
	fee: str,
	rating: str,
	url: str,
	city: str,
	online: bool,
	pic: viper::image,
	pic_ok: bool,
};

type app = struct {
	places: [MAX]place,
	n: size,
	data: []u8,            // list.tsv; the strings in places point into it
	wherebuf: [128]u8,
	where: str,
	addr: viper::textinput,
	search: viper::textinput,
	only_open: bool,
	loading: bool,
	poll_t: f64,
	scroll: int,
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
	fmt::bsprintf(buf, "{}/.local/share/wolt-mini/{}", home(), file)!;

fn helper() str = match (os::getenv("WOLT_PY")) {
case let p: str => yield p;
case void => yield "cmd/wolt/wolt.py";
};

fn say(a: *app, col: viper::color, f: str, args: fmt::field...) void = {
	a.msg = fmt::bsprintf(a.msgbuf, f, args...)!;
	a.msg_col = col;
	a.msg_t = 6.0;
};

fn set_input(tb: *viper::textinput, s: str) void = {
	const b = strings::toutf8(s);
	const n = if (len(b) > len(tb.buf)) len(tb.buf) else len(b);
	tb.buf[..n] = b[..n];
	tb.length = n;
};

fn clicked(win: *viper::window) bool =
	(viper::mouse_clicks(win) & viper::LEFT_BUTTON) != 0;

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
fn sh_bg(script: str, a1: str, a2: str, a3: str, a4: str) bool = {
	let cmd = match (exec::cmd("sh", "-c", script, "wolt", a1, a2, a3, a4)) {
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

// --- the list of places ---

fn free_places(a: *app) void = {
	for (let i = 0z; i < a.n; i += 1) {
		if (a.places[i].pic_ok) viper::image_free(&a.places[i].pic);
	};
	a.n = 0;
	free(a.data);
	a.data = [];
};

// Reads list.tsv, written by wolt.py. Returns false while it is not there.
fn load_list(a: *app) bool = {
	let pb: [512]u8 = [0...];
	const f = match (os::open(data_path(pb, "list.tsv"))) {
	case let f: io::file => yield f;
	case => return false;
	};
	defer io::close(f)!;
	const data = match (io::drain(f)) {
	case let d: []u8 => yield d;
	case => return false;
	};
	free_places(a);
	a.data = data;

	let fl: [10]str = [""...];
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
			if (nf > 1) {
				a.where = fmt::bsprintf(a.wherebuf, "{}", fl[1])!;
			};
			continue;
		};
		if (nf < 10 || a.n >= MAX) continue;
		let p = &a.places[a.n];
		p.slug = fl[0];
		p.name = fl[1];
		p.desc = fl[2];
		p.est = fl[3];
		p.fee = fl[4];
		p.rating = fl[5];
		p.online = fl[6] == "1";
		p.url = fl[8];
		p.city = fl[9];
		p.pic_ok = false;
		if (len(fl[7]) > 0) {
			match (viper::load_png(fl[7])) {
			case let im: viper::image =>
				p.pic = im;
				p.pic_ok = true;
			case viper::imgerror => void;
			};
		};
		a.n += 1;
	};
	return true;
};

// Asks wolt.py for fresh places near the address in the box.
fn refresh(a: *app) void = {
	if (!os::exists(helper())) {
		say(a, RED, "Kan ikke finde {} - start appen fra vipergui-mappen.", helper());
		return;
	};
	let pb: [512]u8 = [0...];
	match (os::remove(data_path(pb, "list.tsv"))) {
	case => void;
	};
	const addr = strings::trim(viper::textinput_str(&a.addr));
	if (!sh_bg("python3 \"$1\" list \"$2\" >/dev/null 2>&1 &", helper(), addr, "", "")) {
		say(a, RED, "Kunne ikke starte python3.");
		return;
	};
	a.loading = true;
	a.poll_t = 0.0;
	a.scroll = 0;
	say(a, BLUE, "Henter restauranter nær {}...", if (len(addr) > 0) addr else "Rødekro");
};

fn open_place(a: *app, p: *place) void = {
	if (sh_bg("python3 \"$1\" open \"$2\" \"$3\" \"$4\" >/dev/null 2>&1 &",
			helper(), p.slug, p.url, p.city)) {
		say(a, GREEN, "Åbner {} - bestil og betal i Wolt-vinduet.", p.name);
	} else {
		say(a, RED, "Kunne ikke starte python3.");
	};
};

// The places that pass the search and the "open now" filter.
fn visible(a: *app, out: []size) size = {
	const q = strings::trim(viper::textinput_str(&a.search));
	let n = 0z;
	for (let i = 0z; i < a.n; i += 1) {
		const p = &a.places[i];
		if (a.only_open && !p.online) continue;
		if (!contains(p.name, q) && !contains(p.desc, q)) continue;
		out[n] = i;
		n += 1;
	};
	return n;
};

// --- drawing ---

fn chip(win: *viper::window, x: int, y: int, w: int, s: str, on: bool) bool = {
	const over = inside(win, x, y, w, 28);
	const bg: viper::color = if (on) BLUE else if (over) BLUE_SOFT else CARD;
	const fg: viper::color = if (on) CARD else BLUE_D;
	viper::round_rect(win, x, y, w, 28, 14, if (on) BLUE else LINE);
	viper::round_rect(win, x + 1, y + 1, w - 2, 26, 13, bg);
	viper::text(win, x + (w - viper::text_width(s, 1)) / 2, y + 6, s, fg);
	return over && clicked(win);
};

fn button(win: *viper::window, x: int, y: int, w: int, h: int, s: str) bool = {
	const over = inside(win, x, y, w, h);
	viper::round_rect(win, x, y, w, h, 8, if (over) BLUE_D else BLUE);
	viper::text(win, x + (w - viper::text_width(s, 1)) / 2, y + (h - 16) / 2, s, CARD);
	return over && clicked(win);
};

fn spinner(win: *viper::window, cx: int, cy: int, t: f64) void = {
	const lead = (t * 10.0): int % 8;
	const dx: [8]int = [0, 7, 10, 7, 0, -7, -10, -7];
	const dy: [8]int = [-10, -7, 0, 7, 10, 7, 0, -7];
	for (let i = 0; i < 8; i += 1) {
		const age = (lead - i + 8) % 8;
		const col = viper::mix(BLUE, BG, age: f64 / 8.0);
		viper::circle(win, cx + dx[i: size], cy + dy[i: size], 3, col);
	};
};

fn star(win: *viper::window, cx: int, cy: int) void = {
	const pts: [10](f64, f64) = [
		(0.0, -6.0), (1.8, -2.0), (6.0, -1.8), (2.8, 1.0), (3.7, 5.5),
		(0.0, 3.0), (-3.7, 5.5), (-2.8, 1.0), (-6.0, -1.8), (-1.8, -2.0),
	];
	let p: [10](f64, f64) = [(0.0, 0.0)...];
	for (let i = 0z; i < 10; i += 1) {
		p[i] = (pts[i].0 + cx: f64, pts[i].1 + cy: f64);
	};
	viper::polygon(win, p, STAR);
};

fn draw_card(win: *viper::window, a: *app, p: *place, x: int, y: int) bool = {
	const over = inside(win, x, y, CARD_W, CARD_H)
		&& win.mouse_y >= GRID_Y && win.mouse_y < GRID_Y + GRID_H;
	viper::round_rect(win, x - 1, y - 1, CARD_W + 2, CARD_H + 2, 13, if (over) BLUE else LINE);
	viper::round_rect(win, x, y, CARD_W, CARD_H, 12, CARD);

	if (p.pic_ok) {
		viper::draw_image(win, &p.pic, x, y);
	} else {
		viper::rect(win, x, y + 10, CARD_W, 140, BLUE_SOFT);
		viper::round_rect(win, x, y, CARD_W, 30, 12, BLUE_SOFT);
		if (len(p.name) > 0) {
			const one = strings::sub(p.name, 0, 1);
			viper::text_scaled(win, x + CARD_W / 2 - 16, y + 50, one, BLUE, 4);
		};
	};
	if (!p.online) {
		viper::round_rect(win, x + 10, y + 112, 150, 28, 14, 0xff2a2a2a);
		viper::text(win, x + 24, y + 118, "Lukket lige nu", CARD);
	};

	let b1: [160]u8 = [0...], b2: [160]u8 = [0...];
	viper::text(win, x + 14, y + 158, fit(p.name, 38, b1), if (p.online) INK else DIM);
	viper::text(win, x + 14, y + 180, fit(p.desc, 38, b2), DIM);

	// Time, delivery price and rating.
	let cx = x + 14;
	if (len(p.est) > 0) {
		viper::text(win, cx, y + 202, p.est, if (p.online) GREEN else DIM);
		cx += viper::text_width(p.est, 1) + 16;
	};
	if (len(p.fee) > 0) {
		viper::text(win, cx, y + 202, p.fee, DIM);
		cx += viper::text_width(p.fee, 1) + 16;
	};
	if (len(p.rating) > 0 && cx < x + CARD_W - 40) {
		star(win, cx + 6, y + 209);
		viper::text(win, cx + 16, y + 202, p.rating, INK);
	};
	return over && clicked(win);
};

fn draw(win: *viper::window, a: *app) void = {
	viper::clear(win, BG);

	// Header.
	viper::rect(win, 0, 0, W, 120, CARD);
	viper::rect(win, 0, 120, W, 1, LINE);
	viper::text_scaled(win, 24, 16, "Wolt Mini", BLUE, 3);
	viper::text(win, 26, 68, "Hare + ViperGui", DIM);

	viper::text(win, 300, 16, "Lever til", DIM);
	if (viper::textbox(win, &a.addr, 300, 36, 380, "Adresse, fx Rødekro")) {
		a.addr.focused = false;
		refresh(a);
	};
	if (button(win, 692, 36, 124, 30, "Find mad")) refresh(a);
	viper::text(win, 840, 16, "Søg", DIM);
	if (viper::textbox(win, &a.search, 840, 36, 236, "Pizza, sushi, burger...")) {
		a.search.focused = false;
	};

	if (chip(win, 24, 86, 70, "Alle", !a.only_open)) a.only_open = false;
	if (chip(win, 102, 86, 100, "Åbne nu", a.only_open)) a.only_open = true;

	let vis: [MAX]size = [0...];
	const nv = visible(a, vis);
	let cb: [192]u8 = [0...];
	if (a.n > 0) {
		viper::text(win, 220, 92, fmt::bsprintf(cb, "{} steder nær {}", nv, a.where)!, INK);
	};
	if (a.loading) spinner(win, 1060, 100, a.t);

	// The grid.
	const rows = ((nv + 2) / 3): int;
	let maxs = rows * STEP_Y + 12 - GRID_H;
	if (maxs < 0) maxs = 0;
	if (a.scroll > maxs) a.scroll = maxs;
	if (a.scroll < 0) a.scroll = 0;

	viper::clip(win, 0, GRID_Y, W, GRID_H);
	let picked: (size | void) = void;
	for (let k = 0z; k < nv; k += 1) {
		const x = 24 + (k % 3): int * STEP_X;
		const y = GRID_Y + 12 + (k / 3): int * STEP_Y - a.scroll;
		if (y + CARD_H < GRID_Y || y > GRID_Y + GRID_H) continue;
		if (draw_card(win, a, &a.places[vis[k]], x, y)) picked = vis[k];
	};
	if (nv == 0 && !a.loading) {
		const s = if (a.n == 0) "Skriv din adresse og tryk Find mad."
			else "Ingen steder passer til din søgning.";
		viper::text(win, (W - viper::text_width(s, 1)) / 2, GRID_Y + 200, s, DIM);
	};
	viper::noclip(win);
	match (picked) {
	case let i: size => open_place(a, &a.places[i]);
	case void => void;
	};

	// Scrollbar.
	if (maxs > 0) {
		const bh = GRID_H * GRID_H / (GRID_H + maxs);
		const by = GRID_Y + (GRID_H - bh) * a.scroll / maxs;
		viper::round_rect(win, W - 10, by, 6, bh, 3, LINE);
	};

	// Footer.
	viper::rect(win, 0, H - 28, W, 28, CARD);
	viper::rect(win, 0, H - 28, W, 1, LINE);
	if (a.msg_t > 0.0) {
		viper::text(win, 24, H - 22, a.msg, a.msg_col);
	} else {
		viper::text(win, 24, H - 22,
			"Klik på et sted for at bestille. Betaling sker på Wolts egen side.", DIM);
	};
};

export fn main() void = {
	const win = match (viper::open("Wolt Mini", W, H)) {
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
		text = INK,
		text_dim = DIM,
		widget = 0xfff0f3f6,
		widget_hot = 0xffe6ecf2,
		accent = BLUE,
		accent_hot = 0xff1aabeb,
		accent_active = BLUE_D,
		...
	};

	let a = app { ... };
	a.where = "Rødekro";

	// The last address, and the last list while the new one loads.
	let pb: [512]u8 = [0...];
	match (os::open(data_path(pb, "address.txt"))) {
	case let f: io::file =>
		match (io::drain(f)) {
		case let d: []u8 =>
			match (strings::fromutf8(d)) {
			case let s: str => set_input(&a.addr, strings::trim(s));
			case => void;
			};
			free(d);
		case => void;
		};
		io::close(f)!;
	case => set_input(&a.addr, "Rødekro");
	};
	load_list(&a);
	refresh(&a);

	for (viper::frame(win)) {
		let dt = viper::delta(win);
		if (dt > 0.1) dt = 0.1;
		a.t += dt;
		if (a.msg_t > 0.0 && !a.loading) a.msg_t -= dt;
		a.scroll -= viper::wheel(win) * 60;
		if (a.loading) {
			a.poll_t += dt;
			if (a.poll_t >= 0.3) {
				a.poll_t = 0.0;
				if (load_list(&a)) {
					a.loading = false;
					if (a.n > 0) say(&a, GREEN, "{} steder fundet.", a.n);
				};
			};
		};
		draw(win, &a);
		if (viper::key_pressed(win, viper::key::ESCAPE)) break;
		viper::present(win);
	};
	free_places(&a);
};
