// VERUCA v2 — edit mode: change only the part of a picture you paint over.
//
// Paint a selection with the brush, describe the change and press
// GENERÉR. The picture, a copy with the selection marked in red and any
// reference pictures go to the image model (helpers/veruca-edit.py). What
// comes back is pasted into the original ONLY inside the selection, with a
// soft edge, so everything else stays exactly as it was.
//
// Every step is kept in ~/Pictures/veruca/edits/<time>/: the original,
// each step's picture, mask and prompt.
use fmt;
use io;
use math;
use os;
use os::exec;
use strings;
use time;
use viper;

def CANVAS_X: int = 170;
def CANVAS_Y: int = 72;
def CANVAS_W: int = 472;
def CANVAS_H: int = 536;
def MAXUNDO: size = 20;
def EDIT_LOG: str = "/tmp/veruca-edit.log";
def SEL_COL: u32 = 0xffff3070;     // the colour of the selection overlay

type editor = struct {
	path: viper::textinput,      // the picture to open
	prompt: viper::textinput,    // what should change
	refs: viper::textinput,      // reference pictures, separated by ;
	outname: viper::textinput,   // export file name
	orig: viper::image,          // the picture as it was opened
	orig_ok: bool,
	cur: viper::image,           // the picture with all accepted edits
	cur_ok: bool,
	res: viper::image,           // a new edit, waiting for accept/reject
	res_ok: bool,
	mask: []u8,                  // the selection: 0..255 per pixel of cur
	undo: [MAXUNDO][]u8,
	nundo: size,
	redo: [MAXUNDO][]u8,
	nredo: size,
	view: viper::image,          // what the canvas shows
	view_ok: bool,
	dirty: bool,                 // the canvas must be drawn again
	zoom: f64,                   // screen pixels per picture pixel
	ox: f64,                     // the picture pixel at the canvas' corner
	oy: f64,
	brush: f64,                  // brush size in screen pixels
	erase: bool,
	painting: bool,
	lx: f64,                     // last brush position (picture pixels)
	ly: f64,
	panning: bool,
	pmx: int,
	pmy: int,
	strength: f64,               // 0..1
	drag_strength: bool,
	drag_brush: bool,
	before: bool,                // show the picture before the new edit
	upscale: bool,
	running: bool,
	proc: exec::process,
	run_t: f64,
	poll_t: f64,
	status: sbuf,
	status_col: viper::color,
	project: sbuf,               // folder with this picture's steps
	step: int,                   // edits sent to the AI
	accepted: int,               // edits accepted (step-N.png files)
	result_path: sbuf,
    whole: bool,                 // no selection: the whole picture is edited
};

fn ed_init(e: *editor) void = {
	e.brush = 30.0;
	e.strength = 0.5;
	e.zoom = 1.0;
	ed_status(e, "Åbn et billede (PNG, JPG eller WEBP) for at begynde.", 0xff9a8cb8);
};

fn ed_status(e: *editor, s: str, col: viper::color) void = {
	sset(&e.status, s);
	e.status_col = col;
};

fn clampf(x: f64, lo: f64, hi: f64) f64 = if (x < lo) lo else if (x > hi) hi else x;

fn copy_image(src: *viper::image) viper::image = {
	let px: []u32 = alloc([0u32...], len(src.pixels))!;
	px[..] = src.pixels[..];
	return viper::image { w = src.w, h = src.h, pixels = px };
};

// Runs a shell command with arguments $1, $2, ... and waits. True if it
// worked.
fn sh_wait(script: str, args: str...) bool = {
	let argv: [12]str = [""...];
	argv[0] = "-c";
	argv[1] = script;
	argv[2] = "veruca";
	let n = 3z;
	for (let a .. args) {
		if (n >= len(argv)) break;
		argv[n] = a;
		n += 1;
	};
	let cmd = match (exec::cmd("sh", argv[..n]...)) {
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

// Does s end with suf (suf in lower case), ignoring upper/lower case?
fn ends_with_ci(s: str, suf: str) bool = {
	const a = strings::toutf8(s), b = strings::toutf8(suf);
	if (len(b) > len(a)) return false;
	const o = len(a) - len(b);
	for (let i = 0z; i < len(b); i += 1) {
		let c = a[o + i];
		if (c >= 65 && c <= 90) c += 32;    // A-Z -> a-z
		if (c != b[i]) return false;
	};
	return true;
};

fn write_text(path: str, s: str) void = {
	match (os::create(path, 0o644)) {
	case let f: io::file =>
		match (io::writeall(f, strings::toutf8(s))) { case => void; };
		match (io::close(f)) { case => void; };
	case => void;
	};
};

// --- undo / redo of the selection ---

fn snapshot(e: *editor) []u8 = {
	let m: []u8 = alloc([0u8...], len(e.mask))!;
	m[..] = e.mask[..];
	return m;
};

fn free_stack(s: *[MAXUNDO][]u8, n: *size) void = {
	for (let i = 0z; i < *n; i += 1) free(s[i]);
	*n = 0;
};

fn push(s: *[MAXUNDO][]u8, n: *size, m: []u8) void = {
	if (*n == MAXUNDO) {
		free(s[0]);
		for (let i = 1z; i < MAXUNDO; i += 1) s[i - 1] = s[i];
		*n -= 1;
	};
	s[*n] = m;
	*n += 1;
};

fn save_undo(e: *editor) void = {
	push(&e.undo, &e.nundo, snapshot(e));
	free_stack(&e.redo, &e.nredo);
};

fn do_undo(e: *editor) void = {
	if (e.nundo == 0) return;
	push(&e.redo, &e.nredo, snapshot(e));
	e.nundo -= 1;
	e.mask[..] = e.undo[e.nundo][..];
	free(e.undo[e.nundo]);
	e.dirty = true;
};

fn do_redo(e: *editor) void = {
	if (e.nredo == 0) return;
	push(&e.undo, &e.nundo, snapshot(e));
	e.nredo -= 1;
	e.mask[..] = e.redo[e.nredo][..];
	free(e.redo[e.nredo]);
	e.dirty = true;
};

fn clear_mask(e: *editor) void = {
	for (let i = 0z; i < len(e.mask); i += 1) e.mask[i] = 0;
	e.dirty = true;
};

fn has_selection(e: *editor) bool = {
	for (let m .. e.mask) if (m != 0) return true;
	return false;
};

// --- opening a picture ---

fn fit_view(e: *editor) void = {
	e.zoom = minf(CANVAS_W: f64 / e.cur.w: f64, CANVAS_H: f64 / e.cur.h: f64);
	e.ox = -(CANVAS_W: f64 / e.zoom - e.cur.w: f64) / 2.0;
	e.oy = -(CANVAS_H: f64 / e.zoom - e.cur.h: f64) / 2.0;
	e.dirty = true;
};

fn forget_picture(e: *editor) void = {
	if (e.orig_ok) viper::image_free(&e.orig);
	if (e.cur_ok) viper::image_free(&e.cur);
	if (e.res_ok) viper::image_free(&e.res);
	e.orig_ok = false;
	e.cur_ok = false;
	e.res_ok = false;
	free(e.mask);
	e.mask = [];
	free_stack(&e.undo, &e.nundo);
	free_stack(&e.redo, &e.nredo);
};

fn open_picture(e: *editor) void = {
	const p = expand(strings::trim(viper::textinput_str(&e.path)));
	defer free(p);
	// ViperGui reads PNG; anything else is converted with ImageMagick first.
	let file = p;
	if (!ends_with_ci(p, ".png")) {
		const tmp = "/tmp/veruca-edit-in.png";
		if (!sh_wait("(magick \"$1\" \"$2\" || convert \"$1\" \"$2\") 2>/dev/null", p, tmp)) {
			ed_status(e, "Kunne ikke læse billedet (er ImageMagick installeret?).", RED);
			return;
		};
		file = tmp;
	};
	const img = match (viper::load_png(file)) {
	case let i: viper::image => yield i;
	case viper::imgerror =>
		ed_status(e, "Kunne ikke åbne billedet.", RED);
		return;
	};
	forget_picture(e);
	e.orig = img;
	e.orig_ok = true;
	e.cur = copy_image(&e.orig);
	e.cur_ok = true;
	e.mask = alloc([0u8...], (img.w * img.h): size)!;
	e.step = 0;
	e.accepted = 0;
	// A project folder for this picture's edits.
	let b: [256]u8 = [0...];
	const dir = fmt::bsprintf(b, "{}/Pictures/veruca/edits/edit-{}", home(),
		time::now(time::clock::REALTIME).sec)!;
	match (os::mkdirs(dir, 0o755)) { case => void; };
	sset(&e.project, dir);
	let b2: [300]u8 = [0...];
	match (viper::save_png(&e.orig, fmt::bsprintf(b2, "{}/original.png", dir)!)) { case => void; };
	fit_view(e);
	let m: [128]u8 = [0...];
	ed_status(e, fmt::bsprintf(m, "Åbnet ({} x {}). Mal over det, der skal ændres.",
		img.w, img.h)!, GREEN);
};

// --- painting the selection ---

fn to_image(e: *editor, sx: int, sy: int) (f64, f64) =
	(e.ox + (sx - CANVAS_X): f64 / e.zoom, e.oy + (sy - CANVAS_Y): f64 / e.zoom);

fn paint_dot(e: *editor, x: f64, y: f64) void = {
	const r = e.brush / 2.0 / e.zoom;
	const val: u8 = if (e.erase) 0 else 255;
	const x0 = (x - r): int, x1 = (x + r): int + 1;
	const y0 = (y - r): int, y1 = (y + r): int + 1;
	for (let iy = y0; iy <= y1; iy += 1) {
		if (iy < 0 || iy >= e.cur.h) continue;
		for (let ix = x0; ix <= x1; ix += 1) {
			if (ix < 0 || ix >= e.cur.w) continue;
			const dx = ix: f64 + 0.5 - x, dy = iy: f64 + 0.5 - y;
			if (dx * dx + dy * dy <= r * r) e.mask[(iy * e.cur.w + ix): size] = val;
		};
	};
};

// A brush stroke from the last position to (x, y), dot by dot.
fn paint_line(e: *editor, x: f64, y: f64) void = {
	const dx = x - e.lx, dy = y - e.ly;
	const dist = math::sqrtf64(dx * dx + dy * dy);
	const stepl = (e.brush / 4.0 / e.zoom) + 0.5;
	const n = (dist / stepl): int + 1;
	for (let i = 1; i <= n; i += 1) {
		const t = i: f64 / n: f64;
		paint_dot(e, e.lx + dx * t, e.ly + dy * t);
	};
	e.lx = x;
	e.ly = y;
	e.dirty = true;
};

fn canvas_input(win: *viper::window, e: *editor) void = {
	if (!e.cur_ok) return;
	const mx = win.mouse_x, my = win.mouse_y;
	const over = mx >= CANVAS_X && mx < CANVAS_X + CANVAS_W
		&& my >= CANVAS_Y && my < CANVAS_Y + CANVAS_H;
	// Mouse wheel: zoom around the mouse.
	const wh = viper::wheel(win);
	if (over && wh != 0) {
		const (ix, iy) = to_image(e, mx, my);
		const f = if (wh > 0) 1.25 else 0.8;
		e.zoom = clampf(e.zoom * f, 0.05, 16.0);
		e.ox = ix - (mx - CANVAS_X): f64 / e.zoom;
		e.oy = iy - (my - CANVAS_Y): f64 / e.zoom;
		e.dirty = true;
	};
	// Right mouse button: drag the picture around.
	const right = viper::mouse_buttons(win) & viper::RIGHT_BUTTON != 0;
	if (right && (over || e.panning)) {
		if (e.panning) {
			e.ox -= (mx - e.pmx): f64 / e.zoom;
			e.oy -= (my - e.pmy): f64 / e.zoom;
			e.dirty = true;
		};
		e.panning = true;
		e.pmx = mx;
		e.pmy = my;
	} else {
		e.panning = false;
	};
	// Left mouse button: paint (not while a result waits for an answer).
	if (e.res_ok || e.running) return;
	const left = viper::mouse_buttons(win) & viper::LEFT_BUTTON != 0;
	if (left && over && !e.painting) {
		save_undo(e);
		e.painting = true;
		const (ix, iy) = to_image(e, mx, my);
		e.lx = ix;
		e.ly = iy;
		paint_dot(e, ix, iy);
		e.dirty = true;
	} else if (left && e.painting) {
		const (ix, iy) = to_image(e, mx, my);
		paint_line(e, ix, iy);
	} else if (!left) {
		e.painting = false;
	};
};

// --- the AI edit ---

fn start_edit(e: *editor) void = {
	if (!e.cur_ok) return ed_status(e, "Åbn et billede først.", RED);
	e.whole = !has_selection(e);
	const prompt = strings::trim(viper::textinput_str(&e.prompt));
	if (len(prompt) == 0) return ed_status(e, "Beskriv ændringen først.", RED);
	e.step += 1;
	const dir = sget(&e.project);
	let b1: [300]u8 = [0...], b2: [300]u8 = [0...], b3: [300]u8 = [0...],
		b4: [300]u8 = [0...], b5: [300]u8 = [0...];
	const input = fmt::bsprintf(b1, "{}/step-{}-input.png", dir, e.step)!;
	const marked = fmt::bsprintf(b2, "{}/step-{}-marked.png", dir, e.step)!;
	const maskf = fmt::bsprintf(b3, "{}/step-{}-mask.png", dir, e.step)!;
	const out = fmt::bsprintf(b4, "{}/step-{}-ai.png", dir, e.step)!;
	const ptxt = fmt::bsprintf(b5, "{}/step-{}-prompt.txt", dir, e.step)!;

	// The picture, the picture with the selection marked in red, the mask.
	match (viper::save_png(&e.cur, input)) {
	case void => void;
	case => return ed_status(e, "Kunne ikke gemme billedet.", RED);
	};
	let mk = copy_image(&e.cur);
	defer viper::image_free(&mk);
	let ms = copy_image(&e.cur);
	defer viper::image_free(&ms);
	for (let i = 0z; i < len(e.mask); i += 1) {
		const on = e.mask[i] > 127;
		if (on) mk.pixels[i] = 0xffff0000;
		ms.pixels[i] = if (on) 0xffffffff else 0xff000000;
	};
	match (viper::save_png(&mk, marked)) { case => void; };
	match (viper::save_png(&ms, maskf)) { case => void; };
	write_text(ptxt, prompt);
	sset(&e.result_path, out);

	// Run the helper in the background.
	const script = strings::concat(home(), "/hpo/helpers/veruca-edit.py")!;
	defer free(script);
	let sb: [16]u8 = [0...];
	const strength = fmt::bsprintf(sb, "{}", (e.strength * 100.0): int)!;
	let argv: [16]str = [""...];
	argv[0] = "-c";
	argv[1] = "python3 \"$@\" > /tmp/veruca-edit.log 2>&1";
	argv[2] = "veruca";
	argv[3] = script;
	argv[4] = input;
	argv[5] = if (e.whole) "-" else marked;
	argv[6] = out;
	argv[7] = prompt;
	argv[8] = strength;
	let n = 9z;
	// Reference pictures, separated by ;
	let refs: [6]str = [""...];
	let nrefs = 0z;
	const rs = viper::textinput_str(&e.refs);
	let start = 0z;
	const rb = strings::toutf8(rs);
	for (let i = 0z; i <= len(rb); i += 1) {
		if (i < len(rb) && rb[i] != 59) continue;   // 59 = ;
		const one = strings::trim(strings::fromutf8_unsafe(rb[start..i]));
		start = i + 1;
		if (len(one) == 0 || nrefs >= len(refs)) continue;
		refs[nrefs] = expand(one);
		nrefs += 1;
	};
	defer for (let i = 0z; i < nrefs; i += 1) free(refs[i]);
	for (let i = 0z; i < nrefs && n < len(argv); i += 1) {
		argv[n] = refs[i];
		n += 1;
	};

	let cmd = match (exec::cmd("sh", argv[..n]...)) {
	case let c: exec::command => yield c;
	case => return ed_status(e, "Kunne ikke starte python3.", RED);
	};
	exec::nullstd(&cmd)!;
	match (exec::start(&cmd)) {
	case let p: exec::process =>
		e.proc = p;
		e.running = true;
		e.run_t = 0.0;
		e.poll_t = 0.0;
		ed_status(e, "Veruca redigerer det markerede område...", PURPLE);
	case exec::error =>
		ed_status(e, "Kunne ikke starte python3.", RED);
	};
};

// A soft copy of the selection: blurred so the edit fades in at the edge.
fn feathered(e: *editor) []u8 = {
	const w = e.cur.w: size, h = e.cur.h: size;
	let r = (if (w > h) w else h) / 250;
	if (r < 2) r = 2;
	let tmp: []u32 = alloc([0u32...], w * h)!;
	defer free(tmp);
	let out: []u8 = alloc([0u8...], w * h)!;
	// Horizontal box blur, then vertical.
	for (let y = 0z; y < h; y += 1) {
		for (let x = 0z; x < w; x += 1) {
			let s = 0u32, c = 0u32;
			const a = if (x >= r) x - r else 0z;
			const b = if (x + r < w) x + r else w - 1;
			for (let k = a; k <= b; k += 1) {
				s += e.mask[y * w + k]: u32;
				c += 1;
			};
			tmp[y * w + x] = s / c;
		};
	};
	for (let y = 0z; y < h; y += 1) {
		const a = if (y >= r) y - r else 0z;
		const b = if (y + r < h) y + r else h - 1;
		for (let x = 0z; x < w; x += 1) {
			let s = 0u32, c = 0u32;
			for (let k = a; k <= b; k += 1) {
				s += tmp[k * w + x];
				c += 1;
			};
			out[y * w + x] = (s / c): u8;
		};
	};
	return out;
};

// Pastes the AI's picture into the current one, only inside the selection.
fn apply_result(e: *editor, path: str) void = {
	const ai = match (viper::load_png(path)) {
	case let i: viper::image => yield i;
	case viper::imgerror =>
		return ed_status(e, "Kunne ikke læse svaret fra Veruca.", RED);
	};
	let big = ai;
	defer viper::image_free(&big);
	// The AI may answer in another size: scale it to the picture's size.
	let fit = match (viper::resize(&big, e.cur.w, e.cur.h)) {
	case let i: viper::image => yield i;
	case nomem => return ed_status(e, "Ikke nok hukommelse.", RED);
	};
	defer viper::image_free(&fit);
	const soft = feathered(e);
	defer free(soft);
	// Strength: how much of the new picture goes into the selection.
	const amount = 1.0;
	if (e.res_ok) viper::image_free(&e.res);
	e.res = copy_image(&e.cur);
	e.res_ok = true;
	for (let i = 0z; i < len(soft); i += 1) {
	const t = if (e.whole) 1.0 else soft[i]: f64 / 255.0 * amount;
		if (t <= 0.0) continue;
		e.res.pixels[i] = viper::mix(e.cur.pixels[i], fit.pixels[i], t) | 0xff000000;
	};
	e.dirty = true;
	ed_status(e, "Færdig! Hold FØR for at sammenligne, og acceptér eller afvis.", GREEN);
};

fn poll_edit(e: *editor, dt: f64) void = {
	e.run_t += dt;
	e.poll_t += dt;
	match (exec::peek(&e.proc)) {
	case void =>
		if (e.poll_t > 0.5) {
			e.poll_t = 0.0;
			read_edit_log(e, false);
		};
	case exec::status =>
		e.running = false;
		ed_status(e, "Veruca gav op uden besked.", RED);
		read_edit_log(e, true);
	case exec::error =>
		e.running = false;
		ed_status(e, "Fejl mens jeg ventede på Veruca.", RED);
	};
};

fn read_edit_log(e: *editor, finished: bool) void = {
	const data = match (read_all(EDIT_LOG)) {
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
			if (!finished) continue;
			apply_result(e, strings::trimprefix(line, "VERUCA_OK: saved "));
			return;
		} else if (strings::hasprefix(line, "VERUCA_ERROR: ")) {
			ed_status(e, strings::trimprefix(line, "VERUCA_ERROR: "), RED);
		} else if (!finished) {
			ed_status(e, strings::trimprefix(line, "[VERUCA] "), PURPLE);
		};
	};
};

fn step_file(e: *editor, buf: []u8, k: int) str =
	if (k == 0) fmt::bsprintf(buf, "{}/original.png", sget(&e.project))!
	else fmt::bsprintf(buf, "{}/step-{}.png", sget(&e.project), k)!;

fn accept(e: *editor) void = {
	if (!e.res_ok) return;
	viper::image_free(&e.cur);
	e.cur = e.res;
	e.res_ok = false;
	e.accepted += 1;
	let b: [300]u8 = [0...];
	match (viper::save_png(&e.cur, step_file(e, b, e.accepted))) { case => void; };
	let b2: [300]u8 = [0...];
	match (viper::save_png(&e.cur, fmt::bsprintf(b2, "{}/current.png", sget(&e.project))!)) {
	case => void;
	};
	clear_mask(e);
	free_stack(&e.undo, &e.nundo);
	free_stack(&e.redo, &e.nredo);
	ed_status(e, "Redigeringen er gemt. Mal en ny markering for næste trin.", GREEN);
};

fn reject(e: *editor) void = {
	if (!e.res_ok) return;
	viper::image_free(&e.res);
	e.res_ok = false;
	e.dirty = true;
	ed_status(e, "Afvist. Markeringen er der stadig, så du kan prøve igen.", 0xff9a8cb8);
};

// Goes back to the picture before the last accepted edit (or the original).
fn step_back(e: *editor) void = {
	if (!e.cur_ok || e.accepted == 0) return;
	let b: [300]u8 = [0...];
	match (viper::load_png(step_file(e, b, e.accepted - 1))) {
	case let i: viper::image =>
		viper::image_free(&e.cur);
		e.cur = i;
		e.accepted -= 1;
		if (e.res_ok) {
			viper::image_free(&e.res);
			e.res_ok = false;
		};
		e.dirty = true;
		ed_status(e, "Et trin tilbage.", 0xff9a8cb8);
	case viper::imgerror =>
		ed_status(e, "Fandt ikke det forrige trin.", RED);
	};
};

fn restore_original(e: *editor) void = {
	if (!e.orig_ok) return;
	viper::image_free(&e.cur);
	e.cur = copy_image(&e.orig);
	if (e.res_ok) {
		viper::image_free(&e.res);
		e.res_ok = false;
	};
	e.accepted = 0;
	e.dirty = true;
	ed_status(e, "Originalen er gendannet.", 0xff9a8cb8);
};

fn do_export(e: *editor) void = {
	if (!e.cur_ok) return;
	let name = strings::trim(viper::textinput_str(&e.outname));
	let b: [300]u8 = [0...];
	if (len(name) == 0) {
		name = fmt::bsprintf(b, "~/Pictures/veruca/edit-{}.png",
			time::now(time::clock::REALTIME).sec)!;
	};
	const out = expand(name);
	defer free(out);
	if (ends_with_ci(out, ".png") && !e.upscale) {
		match (viper::save_png(&e.cur, out)) {
		case void =>
			let m: [400]u8 = [0...];
			ed_status(e, fmt::bsprintf(m, "Gemt: {}", out)!, GREEN);
		case =>
			ed_status(e, "Kunne ikke gemme filen.", RED);
		};
		return;
	};
	// JPG / WEBP / upscale: through ImageMagick.
	const tmp = "/tmp/veruca-export.png";
	match (viper::save_png(&e.cur, tmp)) {
	case void => void;
	case => return ed_status(e, "Kunne ikke gemme filen.", RED);
	};
	const resize = if (e.upscale) "-resize 200%" else "";
	if (sh_wait("(magick \"$1\" $3 \"$2\" || convert \"$1\" $3 \"$2\") 2>/dev/null",
			tmp, out, resize)) {
		let m: [400]u8 = [0...];
		ed_status(e, fmt::bsprintf(m, "Gemt: {}", out)!, GREEN);
	} else {
		ed_status(e, "ImageMagick kunne ikke gemme filen (sudo apt install imagemagick).", RED);
	};
};

// --- drawing ---

// Draws the visible part of the picture, with the selection on top.
fn render_view(e: *editor) void = {
	if (!e.view_ok) {
		let px: []u32 = alloc([0u32...], (CANVAS_W * CANVAS_H): size)!;
		e.view = viper::image { w = CANVAS_W, h = CANVAS_H, pixels = px };
		e.view_ok = true;
	};
	const pic = if (e.res_ok && !e.before) &e.res else &e.cur;
	const overlay = !e.res_ok;
	for (let cy = 0; cy < CANVAS_H; cy += 1) {
		const iy = (e.oy + (cy: f64 + 0.5) / e.zoom): int;
		for (let cx = 0; cx < CANVAS_W; cx += 1) {
			const ix = (e.ox + (cx: f64 + 0.5) / e.zoom): int;
			const o = (cy * CANVAS_W + cx): size;
			if (ix < 0 || iy < 0 || ix >= pic.w || iy >= pic.h) {
				// a dark checker pattern outside the picture
				e.view.pixels[o] = if (((cx / 12) + (cy / 12)) % 2 == 0) 0xff141020 else 0xff1b1529;
				continue;
			};
			const i = (iy * pic.w + ix): size;
			let p = pic.pixels[i] | 0xff000000;
			if (overlay && e.mask[i] != 0) {
				p = viper::mix(p, SEL_COL, e.mask[i]: f64 / 255.0 * 0.5);
			};
			e.view.pixels[o] = p;
		};
	};
	e.dirty = false;
};

// A slider; returns true while it is being dragged.
fn slider(win: *viper::window, x: int, y: int, w: int, val: *f64, drag: *bool) void = {
	const over = win.mouse_x >= x - 4 && win.mouse_x < x + w + 4
		&& win.mouse_y >= y - 6 && win.mouse_y < y + 18;
	if (viper::mouse_pressed(win) && over) *drag = true;
	if (!win.mouse_down) *drag = false;
	if (*drag) *val = clampf((win.mouse_x - x): f64 / w: f64, 0.0, 1.0);
	viper::round_rect(win, x, y + 4, w, 6, 3, 0xff2f2347);
	viper::round_rect(win, x, y + 4, (*val * w: f64): int, 6, 3, PURPLE);
	viper::circle(win, x + (*val * w: f64): int, y + 7, 8, GOLD);
};

// Text over several lines, broken between words.
fn wrapped(win: *viper::window, x: int, y: int, w: int, s: str, col: viper::color, lines: int) void = {
	const b = strings::toutf8(s);
	let start = 0z, line = 0;
	for (start < len(b) && line < lines) {
		// As many whole words as fit.
		let end = start, last_space = 0z, found = false;
		for (end < len(b)) {
			let next = end + 1;
			for (next < len(b) && (b[next] & 0xc0) == 0x80) next += 1;
			if (viper::text_width(strings::fromutf8_unsafe(b[start..next]), 1) > w) break;
			if (b[end] == 32) {    // a space
				last_space = end;
				found = true;
			};
			end = next;
		};
		if (end < len(b) && found) end = last_space;
		if (end == start) end += 1;
		viper::text(win, x, y + line * 18, strings::fromutf8_unsafe(b[start..end]), col);
		start = end;
		for (start < len(b) && b[start] == 32) start += 1;
		line += 1;
	};
};

fn strength_label(s: f64) str = {
	const p = (s * 100.0): int;
	if (p <= 25) return "Detaljer og farver";
	if (p <= 50) return "Tøj, ting og små objekter";
	if (p <= 75) return "Større objekter";
	return "Stor forvandling";
};

fn edit_frame(win: *viper::window, e: *editor, dt: f64) void = {
	if (e.running) poll_edit(e, dt);
	canvas_input(win, e);
	// Ctrl+Z / Ctrl+Y
	const ctrl = win.keys[224] != 0 || win.keys[228] != 0;
	if (ctrl && viper::key_pressed(win, viper::key::Z)) do_undo(e);
	if (ctrl && viper::key_pressed(win, viper::key::Y)) do_redo(e);

	const dim: viper::color = 0xff9a8cb8;

	// --- left: picture and brush ---
	const lx = 10;
	viper::text(win, lx, 74, "Billede:", GOLD);
	if (viper::textbox(win, &e.path, lx, 92, 150, "~/billede.png")) open_picture(e);
	if (chip(win, lx, 128, 150, 28, "Åbn billede", false, 1)) open_picture(e);

	viper::text(win, lx, 170, "Værktøj:", GOLD);
	if (chip(win, lx, 188, 72, 28, "Pensel", !e.erase, 1)) e.erase = false;
	if (chip(win, lx + 78, 188, 72, 28, "Visk", e.erase, 1)) e.erase = true;
	let bb: [32]u8 = [0...];
	viper::text(win, lx, 228, fmt::bsprintf(bb, "Pensel: {} px", e.brush: int)!, dim);
	let bv = (e.brush - 4.0) / 156.0;
	slider(win, lx + 4, 248, 142, &bv, &e.drag_brush);
	e.brush = 4.0 + bv * 156.0;
	if (chip(win, lx, 274, 72, 26, "Fortryd", false, 1)) do_undo(e);
	if (chip(win, lx + 78, 274, 72, 26, "Gentag", false, 1)) do_redo(e);
	if (chip(win, lx, 306, 150, 26, "Ryd markering", false, 1) && e.cur_ok) {
		save_undo(e);
		clear_mask(e);
	};

	viper::text(win, lx, 346, "Referencer:", GOLD);
	viper::textbox(win, &e.refs, lx, 364, 150, "~/ref1.png; ~/ref2.png");
	viper::text(win, lx, 398, "adskil med ;", dim);

	let zb: [32]u8 = [0...];
	viper::text(win, lx, 430, fmt::bsprintf(zb, "Zoom: {}%", (e.zoom * 100.0): int)!, dim);
	if (chip(win, lx, 448, 150, 26, "Tilpas til vindue", false, 1) && e.cur_ok) fit_view(e);
	viper::text(win, lx, 492, "Hjul: zoom", dim);
	viper::text(win, lx, 510, "Højre træk: flyt", dim);
	viper::text(win, lx, 528, "Ctrl+Z / Ctrl+Y", dim);

	// --- center: the canvas ---
	viper::rect(win, CANVAS_X - 2, CANVAS_Y - 2, CANVAS_W + 4, CANVAS_H + 4, PURPLE);
	if (e.cur_ok) {
		if (e.dirty || !e.view_ok) render_view(e);
		viper::draw_image(win, &e.view, CANVAS_X, CANVAS_Y);
		// The brush outline under the mouse.
		const mx = win.mouse_x, my = win.mouse_y;
		if (!e.res_ok && mx >= CANVAS_X && mx < CANVAS_X + CANVAS_W
				&& my >= CANVAS_Y && my < CANVAS_Y + CANVAS_H) {
			const r = e.brush / 2.0;
			const ring: viper::color = if (e.erase) 0xffffffff else GOLD;
			for (let k = 0; k < 24; k += 1) {
				const a0 = k: f64 * math::PI / 12.0, a1 = (k + 1): f64 * math::PI / 12.0;
				viper::line(win, mx + (math::cosf64(a0) * r): int, my + (math::sinf64(a0) * r): int,
					mx + (math::cosf64(a1) * r): int, my + (math::sinf64(a1) * r): int, ring);
			};
		};
		if (e.res_ok) {
			viper::text(win, CANVAS_X + 8, CANVAS_Y + 8,
				if (e.before) "FØR" else "EFTER", GOLD);
		};
	} else {
		viper::rect(win, CANVAS_X, CANVAS_Y, CANVAS_W, CANVAS_H, 0xff141020);
		viper::text(win, CANVAS_X + 120, CANVAS_Y + CANVAS_H / 2, "Åbn et billede til venstre", dim);
	};

	// --- right: the edit ---
	const rx = 654, rw = 236;
	viper::text(win, rx, 74, "Hvad skal ændres?", GOLD);
	if (chip(win, rx + rw - 50, 70, 50, 20, "Ryd", false, 1)) viper::textinput_clear(&e.prompt);
	viper::textbox(win, &e.prompt, rx, 92, rw, "Fx: hvid fedora med guldbånd");
	let sb: [48]u8 = [0...];
	viper::text(win, rx, 134, fmt::bsprintf(sb, "Styrke: {}%", (e.strength * 100.0): int)!, GOLD);
	viper::text(win, rx, 152, strength_label(e.strength), dim);
	slider(win, rx + 4, 172, rw - 8, &e.strength, &e.drag_strength);
	const sel = e.cur_ok && has_selection(e);
	const pcol: viper::color = if (sel) GREEN else RED;
	viper::text(win, rx, 196, if (sel) "Resten af billedet beskyttes"
		else "Hele billedet kan ændre sig", pcol);

	const glabel = if (e.running) "VERUCA ARBEJDER..." else "GENERÉR REDIGERING";
	if (chip(win, rx, 218, rw, 40, glabel, e.running, 1) && !e.running && !e.res_ok) {
		start_edit(e);
	};
	if (e.res_ok) {
		if (chip(win, rx, 266, 74, 30, "ACCEPTÉR", false, 1)) accept(e);
		if (chip(win, rx + 81, 266, 74, 30, "PRØV IGEN", false, 1)) {
			reject(e);
			start_edit(e);
		};
		if (chip(win, rx + 162, 266, 74, 30, "AFVIS", false, 1)) reject(e);
		// Hold the button to see the picture before the edit.
		const over_before = win.mouse_x >= rx && win.mouse_x < rx + rw
			&& win.mouse_y >= 302 && win.mouse_y < 330;
		const show_before = over_before && win.mouse_down;
		chip(win, rx, 302, rw, 28, "Hold: se FØR", show_before, 1);
		if (show_before != e.before) {
			e.before = show_before;
			e.dirty = true;
		};
	};
	if (chip(win, rx, 340, 114, 28, "Et trin tilbage", false, 1)) step_back(e);
	if (chip(win, rx + 122, 340, 114, 28, "Gendan original", false, 1)) restore_original(e);

	viper::text(win, rx, 382, "Eksportér som:", GOLD);
	viper::textbox(win, &e.outname, rx, 400, rw, "~/Pictures/veruca/edit.png");
	if (chip(win, rx, 436, 114, 28, "Upscale 2x", e.upscale, 1)) e.upscale = !e.upscale;
	if (chip(win, rx + 122, 436, 114, 28, "EKSPORTÉR", false, 1)) do_export(e);
	viper::text(win, rx, 470, ".png  .jpg  .webp", dim);

	viper::rect(win, rx, 494, rw, 112, 0xff1a1326);
	viper::outline(win, rx, 494, rw, 112, 0xff4a3670);
	wrapped(win, rx + 8, 502, rw - 16, sget(&e.status), e.status_col, 4);
	if (e.running) {
		let tb: [32]u8 = [0...];
		viper::text(win, rx + 8, 584, fmt::bsprintf(tb, "{} sekunder", e.run_t: int)!, dim);
		spinner(win, rx + rw - 24, 588, e.run_t);
	};
};

fn edit_paste(win: *viper::window, e: *editor) void = {
	const ctrl = win.keys[224] != 0 || win.keys[228] != 0;
	if (!(ctrl && viper::key_pressed(win, viper::key::V))) return;
	const tb = if (e.prompt.focused) &e.prompt
		else if (e.path.focused) &e.path
		else if (e.refs.focused) &e.refs
		else if (e.outname.focused) &e.outname
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
		tb.buf[tb.length + i] = if (data[i] == 10 || data[i] == 13 || data[i] == 9) 32 else data[i];
	};
	tb.length += n;
};

fn edit_close(e: *editor) void = {
	if (e.running) {
		match (exec::kill(e.proc)) { case => void; };
		match (exec::wait(&e.proc)) { case => void; };
	};
	forget_picture(e);
	if (e.view_ok) viper::image_free(&e.view);
};

// --- the two modes ---

// The TRYL / REDIGER tabs in the header.
fn mode_tabs(win: *viper::window, a: *app) void = {
	if (chip(win, 660, 16, 110, 30, "TRYL", a.mode == 0, 1)) a.mode = 0;
	if (chip(win, 780, 16, 110, 30, "REDIGER", a.mode == 1, 1)) a.mode = 1;
};

// The whole window in edit mode.
fn edit_screen(win: *viper::window, a: *app, dt: f64) void = {
	viper::clear(win, INK);
	viper::rect(win, 0, 0, W, 60, 0xff1a1326);
	viper::rect(win, 0, 60, W, 2, PURPLE);
	viper::text_scaled(win, 22, 14, "VERUCA v2", GOLD, 2);
	viper::text(win, 190, 22, "Rediger kun det, du markerer", 0xff9a8cb8);
	mode_tabs(win, a);
	edit_frame(win, &a.ed, dt);
};
