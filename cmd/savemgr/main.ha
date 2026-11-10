// HPO STEAM SAVE MANAGER — backs up, syncs and restores the save files of
// your Steam games. Hare + ViperGui; runs on Linux and in WSL (where C:\
// paths are read through /mnt/c).
//
// The layout follows Bossun's mockup (1672 x 941); every position below is
// in its pixels, and X/Y/L scale them to the window. With the mockup saved
// as ~/.local/share/hpo-saves/skin.png it is the background, and what
// changes is painted over it and drawn live.
//
// Keys: up/down pick a game, Enter starts it, B backs it up, F5 reads
// everything again,
// Tab the next page, Esc quits.
use fmt;
use fs;
use strconv;
use os;
use sort;
use strings;
use viper;

def W: int = 1280;
def H: int = 720;

fn X(v: int) int = v * 1280 / 1672;
fn Y(v: int) int = v * 1280 / 1672;
fn L(v: int) int = v * 1280 / 1672;

type page = enum { LIBRARY, BACKUP, RESTORE, SYNC, PATHS, SETTINGS, LOG, ABOUT };

// What we know about a game's saves and backups.
type info = struct {
	save_sz: u64,
	newest: i64,         // the newest save file's time
	readable: bool,      // every save folder could be read
	backups: []backup,   // newest first
};

type cover = struct {
	src: viper::image,
	card: viper::image,
	banner: viper::image,
};

type app = struct {
	pg: page,
	sel: size,               // the game, in GAMES
	view: []size,            // the games shown, sorted and filtered
	scroll: int,
	infos: []info,
	covers: []cover,
	skin: bool,
	bg: viper::image,
	search: viper::textinput,
	checked: [1024]bool,     // the backup page's choice
	rsel: size,              // the restore page's backup
	rscroll: int,
	verified: [256]u8,       // the restore page: 0 unknown, 1 ok, 2 broken
	pscroll: int,            // the list on Spil-stier
	armed: f64,              // a second press does it (restore, remove)
	armed_what: int,
	msg: [200]u8,
	mlen: size,
	msg_t: f64,
	msg_bad: bool,
	sync: [48]u8,
	slen: size,
	mail: [96]u8,
	maillen: size,
	store: [64]u8,
	storelen: size,
	store_f: f64,
	last_sync: i64,
	mega_in: int,            // frames until MEGA is asked
	cover_q: size,           // the next game to find covers for
	cover_now: bool,         // ... and it is found this frame
	tb_appid: viper::textinput,
	tb_name: viper::textinput,
	tb_dir: viper::textinput,
	tb_proc: viper::textinput,
	proc_for: size,          // tb_proc was filled for this game (+ 1)
	mail_tb: viper::textinput,
	pass_tb: viper::textinput,
	logs: []str,
	lscroll: int,
	quit: bool,
};

const NO_IMAGE: viper::image = viper::image { w = 0, h = 0, pixels = [] };

fn say(a: *app, s: str) void = {
	a.mlen = copy_utf8(a.msg, s);
	a.msg_t = 5.0;
	a.msg_bad = false;
};

fn complain(a: *app, s: str) void = {
	say(a, s);
	a.msg_bad = true;
};

export fn main() void = {
	const win = match (viper::open("HPO Steam Save Manager", W, H)) {
	case let w: *viper::window => yield w;
	case let e: viper::error => fmt::fatal("savemgr:", viper::strerror(e));
	case nomem => fmt::fatal("savemgr: out of memory");
	};
	defer viper::close(win);
	win.theme = viper::theme {
		bg = C_BG,
		panel = C_PANEL,
		border = C_CYAN_DIM,
		text = C_TEXT,
		text_dim = C_DIM,
		widget = C_FIELD,
		widget_hot = 0xff0c1a3a,
		accent = C_CYAN,
		accent_hot = 0xff7fe4ff,
		accent_active = C_CYAN_DIM,
	};
	match (viper::load_png("assets/savemgr/savemgr-icon-64.png")) {
	case let icon: viper::image =>
		viper::set_icon(win, &icon);
		viper::image_free(&icon);
	case viper::imgerror => void;
	};
	let a = app { bg = NO_IMAGE, mega_in = 3, ... };
	const skin = path("skin.png");
	match (viper::load_png(skin)) {
	case let img: viper::image =>
		a.bg = viper::resize(&img, W, H)!;
		viper::image_free(&img);
		a.skin = true;
	case viper::imgerror => void;
	};
	free(skin);
	a.last_sync = read_last_sync();
	reload(&a);

	for (viper::frame(win)) {
		const dt = viper::delta(win);
		if (a.msg_t > 0.0) a.msg_t -= dt;
		if (a.armed > 0.0) a.armed -= dt;
		if (keys(win, &a)) break;
		draw(win, &a);
		viper::present(win);
		if (a.quit) break;
		// MEGA is asked once the window is up (it can take a moment).
		if (a.mega_in > 0) {
			a.mega_in -= 1;
			if (a.mega_in == 0) check_mega(&a, false);
		} else {
			next_cover(&a);
		};
	};
};

// ---- Keeping track ----

// Reads games.txt, the backups, the covers and the log again.
fn reload(a: *app) void = {
	const old = if (a.sel < len(GAMES)) strings::dup(GAMES[a.sel].appid)! else "";
	defer free(old);
	load_games();
	load_settings();
	// New Steam games, from every library.
	const (added, with_dir) = import_steam();
	if (added > 0) {
		let m: [160]u8 = [0...];
		say(a, fmt::bsprintf(m, "{} Steam-spil fundet ({} med save-mappe). Tjek resten under Spil-stier.",
			added, with_dir)!);
	};
	for (let i .. a.infos) free_backups(i.backups);
	free(a.infos);
	a.infos = [];
	for (let i = 0z; i < len(GAMES); i += 1) append(a.infos, read_info(i))!;
	free_covers(a);
	for (let g .. GAMES) append(a.covers, load_cover(g.appid))!;
	a.cover_q = 0;
	a.cover_now = false;
	offline = false;
	strings::freeall(a.logs);
	a.logs = log_tail(300);
	a.sel = 0;
	match (find_game(old)) {
	case let i: size => a.sel = i;
	case void => void;
	};
	make_view(a);
};

fn refresh(a: *app, gi: size) void = {
	free_backups(a.infos[gi].backups);
	a.infos[gi] = read_info(gi);
	strings::freeall(a.logs);
	a.logs = log_tail(300);
	a.verified = [0...];
};

fn read_info(gi: size) info = {
	let inf = info { readable = len(GAMES[gi].dirs) > 0, ... };
	for (let d .. GAMES[gi].dirs) {
		const p = local_path(d);
		defer free(p);
		let list: []str = [];
		defer strings::freeall(list);
		match (walk(p, "", &list)) {
		case void => void;
		case => inf.readable = false;
		};
		for (let rel .. list) {
			const f = strings::concat(p, "/", rel)!;
			defer free(f);
			match (os::stat(f)) {
			case let st: fs::filestat =>
				inf.save_sz += st.sz;
				if (st.mtime.sec > inf.newest) inf.newest = st.mtime.sec;
			case => void;
			};
		};
	};
	inf.backups = list_backups(GAMES[gi].appid);
	return inf;
};

fn load_cover(appid: str) cover = {
	let c = cover { src = NO_IMAGE, card = NO_IMAGE, banner = NO_IMAGE };
	const p = fmt::asprintf("covers/{}.png", appid)!;
	defer free(p);
	const full = path(p);
	defer free(full);
	match (viper::load_png(full)) {
	case let img: viper::image => c.src = img;
	case viper::imgerror => void;
	};
	const b = fmt::asprintf("covers/{}-banner.png", appid)!;
	defer free(b);
	const fullb = path(b);
	defer free(fullb);
	match (viper::load_png(fullb)) {
	case let img: viper::image => c.banner = viper::resize(&img, L(449), L(170))!;
		viper::image_free(&img);
	case viper::imgerror => void;
	};
	return c;
};

// One game a frame: games without covers get them from Steam. The frame
// before says so, as it can take a moment.
fn next_cover(a: *app) void = {
	for (a.cover_q < len(GAMES)) {
		const gi = a.cover_q;
		const c = &a.covers[gi];
		if (c.src.w != 0 && c.banner.w != 0) {
			a.cover_q += 1;
			continue;
		};
		if (!a.cover_now) {
			let b: [200]u8 = [0...];
			say(a, fmt::bsprintf(b, "Henter cover: {}", GAMES[gi].name)!);
			a.cover_now = true;
			return;
		};
		a.cover_now = false;
		a.cover_q += 1;
		if (fetch_covers(GAMES[gi].appid)) {
			const n = load_cover(GAMES[gi].appid);
			if (c.src.w != 0) viper::image_free(&c.src);
			if (c.card.w != 0) viper::image_free(&c.card);
			if (c.banner.w != 0) viper::image_free(&c.banner);
			*c = n;
		};
		a.msg_t = 0.0;
		return;
	};
};

fn free_covers(a: *app) void = {
	for (let c .. a.covers) {
		if (c.src.w != 0) viper::image_free(&c.src);
		if (c.card.w != 0) viper::image_free(&c.card);
		if (c.banner.w != 0) viper::image_free(&c.banner);
	};
	free(a.covers);
	a.covers = [];
};

// The games shown: favourites first, then by name, matching the search.
fn make_view(a: *app) void = {
	free(a.view);
	a.view = [];
	const q = ascii_lower(viper::textinput_str(&a.search));
	defer free(q);
	for (let i = 0z; i < len(GAMES); i += 1) {
		const n = ascii_lower(GAMES[i].name);
		defer free(n);
		if (len(q) == 0 || strings::contains(n, q) || strings::contains(GAMES[i].appid, q)) {
			append(a.view, i)!;
		};
	};
	sort::sort(a.view, size(size), &by_star_name)!;
	if (a.scroll > len(a.view): int - 5) a.scroll = len(a.view): int - 5;
	if (a.scroll < 0) a.scroll = 0;
};

fn by_star_name(x: const *opaque, y: const *opaque) int = {
	const i = *(x: const *size), j = *(y: const *size);
	if (GAMES[i].star != GAMES[j].star) return if (GAMES[i].star) -1 else 1;
	const a = ascii_lower(GAMES[i].name), b = ascii_lower(GAMES[j].name);
	defer free(a);
	defer free(b);
	return strings::compare(a, b);
};

fn ascii_lower(s: str) str = {
	let b = alloc(strings::toutf8(s)...)!;
	for (let i = 0z; i < len(b); i += 1) {
		if (b[i] >= 'A' && b[i] <= 'Z') b[i] += 32;
	};
	return strings::fromutf8_unsafe(b);
};

// Asks MEGA how things are; `loud` says so on screen.
fn check_mega(a: *app, loud: bool) void = {
	let out: [48]u8 = [0...];
	const st = mega_status(out);
	a.slen = copy_utf8(a.sync, st);
	if (st == "Synced") {
		a.last_sync = now();
		write_last_sync(a.last_sync);
	};
	let m: [96]u8 = [0...];
	a.maillen = copy_utf8(a.mail, mega_whoami(m));
	let s: [64]u8 = [0...];
	const (text, f) = mega_storage(s);
	a.storelen = copy_utf8(a.store, text);
	a.store_f = f;
	if (loud) {
		let b: [96]u8 = [0...];
		say(a, fmt::bsprintf(b, "MEGA.nz: {}", st)!);
	};
	if (loud && st == "Synced") log("Synkronisering gennemført");
};

fn sync_status(a: *app) str = strings::fromutf8_unsafe(a.sync[..a.slen]);

fn synced(a: *app) bool = {
	const s = sync_status(a);
	return s == "Synced" || s == "Pending" || s == "Syncing";
};

fn read_last_sync() i64 = {
	const p = path("sync.txt");
	defer free(p);
	match (read_text(p)) {
	case let s: str =>
		defer free(s);
		match (strconv::stoi64(strings::trim(s))) {
		case let t: i64 => return t;
		case => return 0;
		};
	case void => return 0;
	};
};

fn write_last_sync(t: i64) void = {
	const p = path("sync.txt");
	defer free(p);
	let b: [32]u8 = [0...];
	match (write_file(p, fmt::bsprintf(b, "{}\n", t)!)) {
	case => void;
	};
};

// ---- Doing things ----

fn do_backup(a: *app, gi: size) bool = {
	match (backup_game(gi, "")) {
	case let s: str =>
		free(s);
		prune(GAMES[gi].appid, KEEP);
		refresh(a, gi);
		const b = a.infos[gi].backups;
		let m: [160]u8 = [0...], z: [32]u8 = [0...];
		say(a, fmt::bsprintf(m, "Backup af {} er klar ({}).", GAMES[gi].name,
			size_text(z, if (len(b) > 0) b[0].sz else 0))!);
		return true;
	case let e: failure =>
		let m: [256]u8 = [0...];
		const n = copy_utf8(m, e);
		log(strings::fromutf8_unsafe(m[..n]));
		complain(a, strings::fromutf8_unsafe(m[..n]));
		return false;
	};
};

fn do_restore(a: *app) void = {
	const gi = a.sel;
	const bs = a.infos[gi].backups;
	if (a.rsel >= len(bs)) return;
	const stamp = strings::dup(bs[a.rsel].stamp)!;
	defer free(stamp);
	match (restore(gi, stamp)) {
	case let before: str =>
		free(before);
		prune(GAMES[gi].appid, KEEP);
		refresh(a, gi);
		a.rsel = 0;
		let m: [200]u8 = [0...];
		say(a, fmt::bsprintf(m, "{} er gendannet. De saves, der var der, ligger i en ny backup.",
			GAMES[gi].name)!);
	case void =>
		refresh(a, gi);
		say(a, "Gendannet.");
	case let e: failure =>
		let m: [256]u8 = [0...];
		const n = copy_utf8(m, e);
		log(strings::fromutf8_unsafe(m[..n]));
		complain(a, strings::fromutf8_unsafe(m[..n]));
		refresh(a, gi);
	};
};

fn do_start(a: *app, gi: size) void = {
	const g = GAMES[gi];
	let m: [200]u8 = [0...];
	if (running(g.proc)) {
		say(a, fmt::bsprintf(m, "{} kører allerede.", g.name)!);
		return;
	};
	if (start_game(g.appid)) {
		log(fmt::bsprintf(m, "Spil startet: {}", g.name)!);
		say(a, fmt::bsprintf(m, "Starter {} i Steam ...", g.name)!);
	} else {
		complain(a, "Kunne ikke starte Steam (steam / xdg-open mangler).");
	};
};

// The chosen backup on the restore page, pressed twice.
fn do_delete(a: *app) void = {
	const gi = a.sel;
	const bs = a.infos[gi].backups;
	if (a.rsel >= len(bs)) return;
	let m: [200]u8 = [0...], t: [32]u8 = [0...];
	if (!(a.armed > 0.0 && a.armed_what == 3)) {
		a.armed = 5.0;
		a.armed_what = 3;
		say(a, fmt::bsprintf(m, "Tryk Slet igen for at slette backuppen fra {}.",
			stamp_text(t, bs[a.rsel].when))!);
		return;
	};
	a.armed = 0.0;
	const when = bs[a.rsel].when;
	match (delete_backup(GAMES[gi].appid, bs[a.rsel].stamp)) {
	case void =>
		refresh(a, gi);
		if (a.rsel > 0 && a.rsel >= len(a.infos[gi].backups)) a.rsel -= 1;
		say(a, fmt::bsprintf(m, "Backuppen fra {} er slettet.", stamp_text(t, when))!);
	case let e: failure =>
		let c: [256]u8 = [0...];
		const n = copy_utf8(c, e);
		complain(a, strings::fromutf8_unsafe(c[..n]));
	};
};

// Opens a folder (or a web page) in Windows' Explorer or the Linux desktop.
fn open_thing(p: str) void = {
	const b = strings::toutf8(p);
	const windows = len(b) >= 3 && b[1] == ':' || strings::hasprefix(p, "http");
	if (windows) {
		match (run("explorer.exe", p)) {
		case let r: ([]u8, bool) =>
			free(r.0);
			return;
		case void => void;
		};
	};
	const l = local_path(p);
	defer free(l);
	match (run("xdg-open", l)) {
	case let r: ([]u8, bool) => free(r.0);
	case void => void;
	};
};

fn typing(a: *app) bool = a.search.focused || a.tb_appid.focused || a.tb_name.focused
	|| a.tb_dir.focused || a.tb_proc.focused || a.mail_tb.focused || a.pass_tb.focused;

// Returns true to quit.
fn keys(win: *viper::window, a: *app) bool = {
	if (typing(a)) {
		if (viper::key_pressed(win, viper::key::ESCAPE)) {
			a.search.focused = false;
			a.tb_appid.focused = false;
			a.tb_name.focused = false;
			a.tb_dir.focused = false;
			a.tb_proc.focused = false;
			a.mail_tb.focused = false;
			a.pass_tb.focused = false;
		};
		return false;
	};
	if (viper::key_pressed(win, viper::key::ESCAPE)) return true;
	if (viper::key_pressed(win, viper::key::TAB)) {
		a.pg = ((a.pg: int + 1) % (page::ABOUT: int + 1)): page;
	};
	if (viper::key_pressed(win, 62: viper::key)) {
		reload(a);
		check_mega(a, true);
	};
	if (len(a.view) == 0) return false;
	let at = 0z;
	for (let i = 0z; i < len(a.view); i += 1) if (a.view[i] == a.sel) at = i;
	if (viper::key_pressed(win, viper::key::DOWN) && at + 1 < len(a.view)) pick(a, a.view[at + 1]);
	if (viper::key_pressed(win, viper::key::UP) && at > 0) pick(a, a.view[at - 1]);
	if (viper::key_pressed(win, viper::key::B) && a.sel < len(GAMES)) do_backup(a, a.sel);
	if (viper::key_pressed(win, viper::key::RETURN) && a.sel < len(GAMES)) do_start(a, a.sel);
	return false;
};

fn pick(a: *app, gi: size) void = {
	if (a.sel != gi) {
		a.rsel = 0;
		a.rscroll = 0;
		a.verified = [0...];
	};
	a.sel = gi;
	let at = 0;
	for (let i = 0z; i < len(a.view); i += 1) if (a.view[i] == gi) at = i: int;
	if (at < a.scroll) a.scroll = at;
	if (at >= a.scroll + 5) a.scroll = at - 4;
};

// ---- Drawing helpers ----

fn hit(win: *viper::window, x: int, y: int, w: int, h: int) bool = {
	const (mx, my) = viper::mouse(win);
	return mx >= x && mx < x + w && my >= y && my < y + h;
};

fn clicked(win: *viper::window, x: int, y: int, w: int, h: int) bool =
	viper::mouse_pressed(win) && hit(win, x, y, w, h);

// Over the mockup: paints a box (mockup pixels) row by row with the
// mockup's colour at column sx.
fn paint(win: *viper::window, a: *app, x: int, y: int, w: int, h: int, sx: int) void = {
	if (!a.skin) return;
	const px = X(sx);
	for (let r = Y(y); r < Y(y + h) && r < H; r += 1) {
		viper::rect(win, X(x), r, L(w), 1, a.bg.pixels[r * W + px]);
	};
};

// Over the mockup: paints a box with a gradient between two of its points.
fn paint_grad(win: *viper::window, a: *app, x: int, y: int, w: int, h: int,
		tx: int, ty: int, bx: int, by: int) void = {
	if (!a.skin) return;
	vgrad(win, X(x), Y(y), L(w), L(h), a.bg.pixels[Y(ty) * W + X(tx)],
		a.bg.pixels[Y(by) * W + X(bx)]);
};

type style = enum { PLAIN, GREEN, CYAN, YELLOW, RED };

// A button; true when clicked. Over the mockup with `fixed` only a glow is
// drawn: the button is in the picture.
fn btn(win: *viper::window, a: *app, x: int, y: int, w: int, h: int, label: str,
		ic: (icon | void), st: style, fixed: bool) bool = {
	const bx = X(x), by = Y(y), bw = L(w), bh = L(h);
	const over = hit(win, bx, by, bw, bh);
	if (a.skin && fixed) {
		if (over) {
			viper::outline(win, bx - 2, by - 2, bw + 4, bh + 4, C_YEL_HI);
			viper::outline(win, bx - 3, by - 3, bw + 6, bh + 6, C_YELLOW);
		};
		return over && viper::mouse_pressed(win);
	};
	const (rim, fill): (u32, u32) = switch (st) {
	case style::GREEN => yield (C_GREEN, 0xff0d3a1f);
	case style::CYAN => yield (C_CYAN, 0xff0a2a4a);
	case style::YELLOW => yield (C_YELLOW, 0xff2a2608);
	case style::RED => yield (C_RED, 0xff3a0d14);
	case style::PLAIN => yield (C_CYAN_DIM, C_FIELD);
	};
	neon(win, bx, by, bw, bh, 8, if (over) mix(rim, 0xffffffff, 0.4) else rim,
		if (over) mix(fill, rim, 0.25) else fill);
	const iw = match (ic) { case icon => yield 26; case void => yield 0; };
	const tw = viper::text_width(label, 1) + iw;
	const tx = bx + (bw - tw) / 2, cy = by + bh / 2;
	match (ic) {
	case let i: icon => draw_icon(win, i, tx + 10, cy, C_TEXT);
	case void => void;
	};
	bold(win, tx + iw, cy - 8, label, C_TEXT);
	return over && viper::mouse_pressed(win);
};

// Text cut to w pixels.
fn text_clip(win: *viper::window, x: int, y: int, w: int, s: str, col: u32, b: bool) void = {
	viper::clip(win, x, y - 2, w, 22);
	if (b) bold(win, x, y, s, col) else viper::text(win, x, y, s, col);
	viper::noclip(win);
};

// ---- Drawing ----

fn draw(win: *viper::window, a: *app) void = {
	if (a.skin) {
		viper::draw_image(win, &a.bg, 0, 0);
	} else {
		draw_frame(win, a);
	};
	draw_side(win, a);
	switch (a.pg) {
	case page::LIBRARY, page::BACKUP => draw_library(win, a);
	case page::RESTORE => draw_restore(win, a);
	case page::SYNC => draw_sync(win, a);
	case page::PATHS => draw_paths(win, a);
	case page::SETTINGS => draw_settings(win, a);
	case page::LOG => draw_log(win, a);
	case page::ABOUT => draw_about(win, a);
	};
	draw_details(win, a);
	draw_footer(win, a);
	draw_message(win, a);
	// The mockup's close button, top right.
	if (a.skin && clicked(win, X(1615), Y(15), L(40), L(40))) a.quit = true;
};

// What the mockup has painted in already.
fn draw_frame(win: *viper::window, a: *app) void = {
	vgrad(win, 0, 0, W, H, 0xff07112c, 0xff03081a);
	// The top bar.
	vgrad(win, 0, 0, W, Y(92), 0xff0b1840, 0xff060d26);
	viper::rect(win, 0, Y(92), W, 2, C_CYAN_DIM);
	bolt(win, X(40), Y(8), L(70), L(76), C_YELLOW);
	bold2(win, X(130), Y(22), "HPO", C_TEXT);
	viper::text_scaled(win, X(316), Y(14), "Steam Save Manager", C_YELLOW, 2);
	viper::text_scaled(win, X(316) + 1, Y(14), "Steam Save Manager", C_YELLOW, 2);
	viper::text(win, X(316) + viper::text_width("Steam Save Manager", 2) + 12, Y(24), "v0.1.0", C_TEXT);
	viper::text(win, X(316), Y(56), "Hare + ViperGui  |  Steam Saves  |  MEGA.nz Sync", C_DIM);
	for (let i = 0; i < 4; i += 1) {
		const x = X(860) + i * 14;
		viper::line(win, x, Y(80), x + 18, Y(14), C_YELLOW);
		viper::line(win, x + 1, Y(80), x + 19, Y(14), C_YELLOW);
	};
	draw_icon(win, icon::DISC, X(1057), Y(42), C_CYAN);
	bold2(win, X(1092), Y(28), "STEAM", C_TEXT);
	viper::rect(win, X(1230), Y(22), 2, L(40), C_DIM);
	viper::circle(win, X(1292), Y(42), 13, 0xffd9272e);
	bold(win, X(1292) - 4, Y(42) - 8, "M", C_TEXT);
	bold2(win, X(1328), Y(28), "MEGA.nz", C_TEXT);
	// The left: a big lightning bolt where the mockup has its art.
	bolt(win, X(20), Y(220), L(210), L(420), mix(C_YELLOW, C_BG, 0.55));
	// Panels.
	neon(win, X(250), Y(105), L(205), L(717), 10, C_CYAN_DIM, C_PANEL);
	neon(win, X(462), Y(105), L(715), L(717), 10, C_CYAN_DIM, C_PANEL);
	neon(win, X(1186), Y(108), L(474), L(712), 10, C_CYAN, C_PANEL);
	neon(win, X(180), Y(846), L(1475), L(80), 10, C_CYAN, C_PANEL);
	bold2(win, X(262), Y(735), "ViperGui", C_TEXT);
	viper::text(win, X(272), Y(790), "Powered by Hare", C_DIM);
};

const MENU: [8](str, icon, page) = [
	("Bibliotek", icon::GAMEPAD, page::LIBRARY),
	("Backup", icon::CLOUD_UP, page::BACKUP),
	("Gendan", icon::RESTORE, page::RESTORE),
	("Synkronisering", icon::SYNC, page::SYNC),
	("Spil-stier", icon::FOLDER, page::PATHS),
	("Indstillinger", icon::COG, page::SETTINGS),
	("Log", icon::LOG, page::LOG),
	("Om", icon::INFO, page::ABOUT),
];

const MENU_Y: [8]int = [159, 223, 288, 352, 417, 481, 546, 610];

fn draw_side(win: *viper::window, a: *app) void = {
	paint_grad(win, a, 252, 152, 202, 523, 350, 150, 350, 690);
	for (let i = 0z; i < len(MENU); i += 1) {
		const (name, ic, pg) = MENU[i];
		const y = MENU_Y[i];
		const on = a.pg == pg;
		const over = hit(win, X(252), Y(y), L(203), L(58));
		if (on) {
			vgrad(win, X(252), Y(y), L(203), L(58), C_YEL_HI, C_YELLOW);
		} else if (over) {
			viper::rect(win, X(252), Y(y), L(203), L(58), 0xff12224c);
		};
		if (i > 0 && !on && a.pg != MENU[i - 1].2) {
			viper::rect(win, X(262), Y(y) - 1, L(183), 1, 0xff1a2c5c);
		};
		const col = if (on) C_INK else C_TEXT;
		draw_icon(win, ic, X(289), Y(y + 29), if (on) C_INK else C_CYAN);
		bold(win, X(320), Y(y + 29) - 8, name, col);
		if (over && viper::mouse_pressed(win)) a.pg = pg;
	};
};

// ---- The library (and the backup page, with tick boxes) ----

def CARD_X: int = 472;
def CARD_W: int = 675;
def CARD_Y: int = 181;
def CARD_STEP: int = 125;
def CARD_H: int = 117;
def CARDS: int = 5;

fn draw_library(win: *viper::window, a: *app) void = {
	const backup_page = a.pg == page::BACKUP;
	// The header.
	paint(win, a, 470, 108, 488, 52, 467);
	draw_icon(win, icon::DISC, X(497), Y(132), C_TEXT);
	let b: [64]u8 = [0...];
	let nchk = 0;
	for (let i = 0z; i < len(GAMES) && i < len(a.checked); i += 1) if (a.checked[i]) nchk += 1;
	let title = if (backup_page) fmt::bsprintf(b, "Backup ({} valgt)", nchk)!
		else fmt::bsprintf(b, "Mine Steam-spil ({})", len(GAMES))!;
	if (viper::text_width(title, 2) > X(950) - X(534)) {
		title = if (backup_page) fmt::bsprintf(b, "Backup ({})", nchk)!
			else fmt::bsprintf(b, "Steam-spil ({})", len(GAMES))!;
	};
	bold2(win, X(534), Y(132) - 16, title, C_TEXT);
	// The search box, or on the backup page: tick all / none.
	paint(win, a, 958, 105, 214, 54, 958);
	if (backup_page) {
		const all = nchk == len(GAMES): int && nchk > 0;
		if (btn(win, a, 962, 110, 204, 45, if (all) "Fravælg alle" else "Vælg alle",
				icon::CHECK, style::CYAN, false)) {
			for (let i = 0z; i < len(GAMES) && i < len(a.checked); i += 1) a.checked[i] = !all;
		};
	} else {
		neon(win, X(962), Y(110), L(204), L(45), 8, C_CYAN_DIM, C_FIELD);
		draw_icon(win, icon::SEARCH, X(987), Y(132), C_TEXT);
		const before = len(viper::textinput_str(&a.search));
		viper::textbox(win, &a.search, X(1003), Y(132) - 15, L(157), "Søg spil...");
		if (len(viper::textinput_str(&a.search)) != before) make_view(a);
	};
	// The cards.
	paint_grad(win, a, 466, 166, 706, 650, 467, 170, 467, 810);
	if (hit(win, X(CARD_X), Y(CARD_Y), L(CARD_W), L(CARD_STEP * CARDS))) {
		a.scroll -= viper::wheel(win);
	};
	const maxs = if (len(a.view): int > CARDS) len(a.view): int - CARDS else 0;
	if (a.scroll > maxs) a.scroll = maxs;
	if (a.scroll < 0) a.scroll = 0;
	if (len(a.view) == 0) {
		const msg = if (len(GAMES) == 0) "Ingen spil endnu. Tilføj dem under Spil-stier."
			else "Ingen spil passer til søgningen.";
		viper::text(win, X(500), Y(220), msg, C_DIM);
	};
	for (let r = 0; r < CARDS && a.scroll + r < len(a.view): int; r += 1) {
		card(win, a, a.view[(a.scroll + r): size], CARD_Y + r * CARD_STEP, backup_page);
	};
	if (maxs > 0) {
		const th = L(CARD_STEP * CARDS - 10);
		const bh = th * CARDS / len(a.view): int;
		const by = Y(CARD_Y) + (th - bh) * a.scroll / maxs;
		viper::round_rect(win, X(1156), by, 5, bh, 2, C_CYAN);
	};
};

fn card(win: *viper::window, a: *app, gi: size, y: int, backup_page: bool) void = {
	const g = GAMES[gi], inf = a.infos[gi];
	const on = gi == a.sel;
	const x = X(CARD_X), cy = Y(y), w = L(CARD_W), h = L(CARD_H);
	neon(win, x, cy, w, h, 10, if (on) C_YELLOW else C_CYAN_DIM, if (on) C_CARD_HI else C_CARD);
	// The star (or the tick box).
	const sx = X(500), sy = Y(y + 60);
	if (backup_page) {
		viper::round_rect(win, sx - 10, sy - 10, 20, 20, 4, C_CYAN);
		viper::round_rect(win, sx - 8, sy - 8, 16, 16, 3, C_FIELD);
		if (gi < len(a.checked) && a.checked[gi]) draw_icon(win, icon::CHECK, sx, sy, C_CYAN);
	} else {
		draw_icon(win, if (g.star) icon::STAR_FULL else icon::STAR, sx, sy,
			if (g.star) C_YELLOW else C_DIM);
	};
	const star_hit = clicked(win, sx - 16, sy - 16, 32, 32);
	if (star_hit) {
		if (backup_page) {
			if (gi < len(a.checked)) a.checked[gi] = !a.checked[gi];
		} else {
			GAMES[gi].star = !GAMES[gi].star;
			save_games();
			make_view(a);
		};
	};
	// The cover.
	const cx = X(525), cw = L(130), chh = L(105);
	match (card_cover(a, gi, cw, chh)) {
	case let img: *viper::image =>
		viper::round_rect(win, cx - 1, cy + L(6), cw + 2, chh + 2, 6, C_CYAN_DIM);
		viper::draw_image(win, img, cx, cy + L(7));
	case null => draw_cover(win, cx, cy + L(7), cw, chh, g.name, gi);
	};
	// The name and the facts.
	const tx = X(670);
	text_clip(win, tx, cy + L(16), X(1135) - tx, g.name, C_YEL_HI, true);
	let b: [64]u8 = [0...], z: [32]u8 = [0...];
	draw_icon(win, icon::FOLDER, X(684), cy + L(62), C_DIM);
	viper::text(win, X(705), cy + L(62) - 8, if (!inf.readable && len(g.dirs) > 0) "Save: mangler"
		else if (len(g.dirs) == 0) "Save: ingen mappe"
		else fmt::bsprintf(b, "Save: {}", size_text(z, inf.save_sz))!,
		if (!inf.readable) C_RED else C_TEXT);
	draw_icon(win, icon::CALENDAR, X(684), cy + L(92), C_DIM);
	viper::text(win, X(705), cy + L(92) - 8, if (len(inf.backups) == 0) "Sidste backup: ingen endnu"
		else fmt::bsprintf(b, "Sidste backup: {}", stamp_text(z, inf.backups[0].when))!, C_TEXT);
	// The status, right.
	const changed = len(inf.backups) == 0 || inf.newest > inf.backups[0].when;
	const py = cy + L(43), ph = L(30);
	let do_it = false;
	if (!inf.readable) {
		pill(win, X(905), py, L(200), ph, "Tjek save-stien", C_RED, 0);
	} else if (changed) {
		const over = hit(win, X(905), py - 3, L(200), ph + 6);
		pill(win, X(905), py, L(200), ph, "Klar til backup", if (over) 0xff7fe4ff else C_CYAN, 30);
		draw_icon(win, icon::CLOUD_UP, X(905) + 17, py + ph / 2, C_CYAN);
		do_it = over && viper::mouse_pressed(win);
	} else {
		// The whole pill is the backup button; the icon sits inside it.
		const ok = synced(a);
		const over = hit(win, X(905), py - 3, L(200), ph + 6);
		const col = if (ok) C_GREEN else C_YELLOW;
		pill(win, X(905), py, L(200), ph, if (ok) "Synkroniseret" else "Ikke synk.",
			if (over) mix(col, 0xffffffff, 0.35) else col, 30);
		if (ok) {
			ok_badge(win, X(905) + 17, py + ph / 2, 8);
		} else {
			draw_icon(win, icon::CLOUD_UP, X(905) + 17, py + ph / 2, C_YELLOW);
		};
		do_it = over && viper::mouse_pressed(win);
	};
	if (do_it) {
		do_backup(a, gi);
	} else if (!star_hit && clicked(win, x, cy, w, h)) {
		pick(a, gi);
	};
};

// A rounded label; `pad` leaves room for an icon at the left.
fn pill(win: *viper::window, x: int, y: int, w: int, h: int, label: str, col: u32, pad: int) void = {
	viper::round_rect(win, x, y, w, h, h / 2, col);
	viper::round_rect(win, x + 2, y + 2, w - 4, h - 4, h / 2 - 2, mix(col, C_INK, 0.82));
	const tw = viper::text_width(label, 1);
	viper::text(win, x + pad + (w - pad - tw) / 2, y + (h - 16) / 2, label, mix(col, 0xffffffff, 0.5));
};

fn card_cover(a: *app, gi: size, w: int, h: int) nullable *viper::image = {
	let c = &a.covers[gi];
	if (c.src.w == 0) return null;
	if (c.card.w != w || c.card.h != h) {
		if (c.card.w != 0) viper::image_free(&c.card);
		// Fill the box without stretching: cut the picture to its shape,
		// keeping the top (where a poster has its title).
		let cw = c.src.w, ch = c.src.w * h / w;
		if (ch > c.src.h) {
			ch = c.src.h;
			cw = c.src.h * w / h;
		};
		const cy = if (ch < c.src.h) (c.src.h - ch) / 4 else 0;
		let cut = viper::crop(&c.src, (c.src.w - cw) / 2, cy, cw, ch)!;
		c.card = viper::resize(&cut, w, h)!;
		viper::image_free(&cut);
	};
	return &c.card;
};

// ---- The right: the chosen game ----

fn draw_details(win: *viper::window, a: *app) void = {
	// Paint out the mockup's game.
	paint_grad(win, a, 1194, 112, 458, 590, 1192, 300, 1192, 700);
	if (len(GAMES) == 0 || a.sel >= len(GAMES)) {
		viper::text(win, X(1210), Y(300), "Tilføj et spil under Spil-stier.", C_DIM);
		return;
	};
	const g = GAMES[a.sel], inf = a.infos[a.sel];
	// The banner.
	const bx = X(1198), by = Y(115), bw = L(449), bh = L(170);
	const c = &a.covers[a.sel];
	if (c.banner.w != 0) {
		viper::draw_image(win, &c.banner, bx, by);
	} else {
		vgrad(win, bx, by, bw, bh, 0xff1c2f6e, 0xff070d24);
		match (card_cover(a, a.sel, L(130), L(105))) {
		case let img: *viper::image => viper::draw_image(win, img, bx + bw - L(150), by + L(32));
		case null => void;
		};
		// The name as big as it fits: scale 3 on two lines, else 2 on three.
		const room = bw - (if (c.src.w != 0) L(170) else L(30));
		let lines: [3]str = [""...];
		let scale = 3, n = wrap(g.name, room / 3, lines[..2]);
		if (n == 0 || !fits(g.name, lines[..n]) || longest(lines[..n], 3) > room) {
			scale = 2;
			n = wrap(g.name, room / 2, lines);
		};
		const lh = 16 * scale + 6;
		let yy = by + (bh - n: int * lh) / 2;
		for (let i = 0z; i < n; i += 1) {
			viper::clip(win, bx, by, bw, bh);
			bold_big(win, bx + L(20), yy, lines[i], scale);
			viper::noclip(win);
			yy += lh;
		};
	};
	viper::outline(win, bx, by, bw, bh, C_CYAN_DIM);
	// Start the game.
	if (btn(win, a, 1468, 236, 170, 40, "Start spil", icon::PLAY, style::GREEN, false)) {
		do_start(a, a.sel);
	};
	// The name.
	draw_icon(win, icon::DISC, X(1222), Y(317), C_TEXT);
	if (viper::text_width(g.name, 2) <= X(1645) - X(1256)) {
		bold2(win, X(1256), Y(317) - 16, g.name, C_TEXT);
	} else {
		text_clip(win, X(1256), Y(317) - 8, X(1645) - X(1256), g.name, C_TEXT, true);
	};
	// The save folder.
	let b: [128]u8 = [0...];
	draw_icon(win, icon::FOLDER, X(1218), Y(360), C_TEXT);
	bold(win, X(1245), Y(360) - 8, if (len(g.dirs) > 1) fmt::bsprintf(b, "Save-stier ({}):", len(g.dirs))!
		else "Save-sti:", C_TEXT);
	field(win, X(1240), Y(372), X(1597) - X(1240), L(28),
		if (len(g.dirs) > 0) g.dirs[0] else "(ingen – se Spil-stier)");
	if (btn(win, a, 1606, 366, 40, 38, "", icon::FOLDER, style::PLAIN, false) && len(g.dirs) > 0) {
		open_thing(g.dirs[0]);
	};
	// Its MEGA folder.
	cloud(win, X(1218), Y(428), C_TEXT);
	bold(win, X(1245), Y(428) - 8, "MEGA.nz-mappe:", C_TEXT);
	field(win, X(1240), Y(440), X(1597) - X(1240), L(28),
		fmt::bsprintf(b, "{}/Steam/{}/", MEGA_DIR, g.appid)!);
	if (btn(win, a, 1606, 433, 40, 38, "", icon::EXTERNAL, style::PLAIN, false)) {
		open_thing("https://mega.nz/fm");
	};
	// The last five backups.
	viper::rect(win, X(1203), Y(484), L(442), 1, C_CYAN_DIM);
	bold(win, X(1205), Y(508) - 8, "Backuphistorik (seneste 5)", C_TEXT);
	if (len(inf.backups) == 0) viper::text(win, X(1210), Y(545) - 8, "Ingen backups endnu.", C_DIM);
	let z: [32]u8 = [0...], t: [32]u8 = [0...];
	for (let i = 0z; i < 5 && i < len(inf.backups); i += 1) {
		const ry = Y(528 + i: int * 32);
		const bk = inf.backups[i];
		viper::round_rect(win, X(1203), ry, L(442), L(30), 5, 0xff0d1d44);
		ok_badge(win, X(1225), ry + L(15), 8);
		viper::text(win, X(1250), ry + L(15) - 8, stamp_text(t, bk.when), C_TEXT);
		viper::text(win, X(1445), ry + L(15) - 8, fmt::bsprintf(b, "({})", size_text(z, bk.sz))!, C_TEXT);
		if (len(bk.note) > 0) viper::text(win, X(1555), ry + L(15) - 8, "før", C_YELLOW);
		if (btn(win, a, 1604, 532 + i: int * 32, 36, 22, "", icon::DOTS, style::PLAIN, false)) {
			a.pg = page::RESTORE;
			a.rsel = i;
		};
	};
	// The two big buttons (the mockup has them).
	if (btn(win, a, 1203, 724, 213, 67, "Backup nu", icon::CLOUD_UP, style::GREEN, true)) {
		backup_button(a);
	};
	if (btn(win, a, 1434, 724, 214, 67, "Gendan...", icon::RESTORE, style::CYAN, true)) {
		restore_button(a);
	};
};

fn bold_big(win: *viper::window, x: int, y: int, s: str, scale: int) void = {
	for (let d = -1; d <= 1; d += 1) viper::text_scaled(win, x + d, y + 2, s, C_INK, scale);
	viper::text_scaled(win, x, y, s, C_YELLOW, scale);
	viper::text_scaled(win, x + 1, y, s, C_YELLOW, scale);
};

fn field(win: *viper::window, x: int, y: int, w: int, h: int, s: str) void = {
	viper::round_rect(win, x, y, w, h, 5, C_CYAN_DIM);
	viper::round_rect(win, x + 1, y + 1, w - 2, h - 2, 5, C_FIELD);
	text_clip(win, x + 8, y + (h - 16) / 2, w - 14, s, C_TEXT, false);
};

// "Backup nu": the ticked games on the backup page, else the chosen one.
fn backup_button(a: *app) void = {
	if (a.pg == page::BACKUP) {
		let n = 0, ok = 0;
		for (let i = 0z; i < len(GAMES) && i < len(a.checked); i += 1) {
			if (!a.checked[i]) continue;
			n += 1;
			if (do_backup(a, i)) ok += 1;
		};
		if (n > 0) {
			let m: [96]u8 = [0...];
			if (ok == n) say(a, fmt::bsprintf(m, "{} backups er klar.", ok)!)
			else complain(a, fmt::bsprintf(m, "{} af {} backups lykkedes – se Log.", ok, n)!);
			return;
		};
	};
	if (a.sel < len(GAMES)) do_backup(a, a.sel);
};

// "Gendan...": the restore page; there, pressed twice, it restores.
fn restore_button(a: *app) void = {
	if (a.pg != page::RESTORE) {
		a.pg = page::RESTORE;
		return;
	};
	if (a.sel >= len(GAMES) || a.rsel >= len(a.infos[a.sel].backups)) return;
	if (a.armed > 0.0 && a.armed_what == 1) {
		a.armed = 0.0;
		do_restore(a);
		return;
	};
	a.armed = 5.0;
	a.armed_what = 1;
	let m: [200]u8 = [0...], t: [32]u8 = [0...];
	say(a, fmt::bsprintf(m, "Tryk Gendan igen for at gendanne backuppen fra {}.",
		stamp_text(t, a.infos[a.sel].backups[a.rsel].when))!);
};

// ---- Restore ----

fn center_header(win: *viper::window, a: *app, title: str, ic: icon) void = {
	paint_grad(win, a, 466, 106, 706, 710, 467, 110, 467, 810);
	draw_icon(win, ic, X(497), Y(132), C_TEXT);
	text_clip(win, X(534), Y(132) - 16, X(1160) - X(534), "", C_TEXT, false);
	if (viper::text_width(title, 2) <= X(1160) - X(534)) {
		bold2(win, X(534), Y(132) - 16, title, C_TEXT);
	} else {
		text_clip(win, X(534), Y(132) - 8, X(1160) - X(534), title, C_TEXT, true);
	};
	if (!a.skin) return;
};

fn draw_restore(win: *viper::window, a: *app) void = {
	if (len(GAMES) == 0) {
		center_header(win, a, "Gendan", icon::RESTORE);
		return;
	};
	const g = GAMES[a.sel];
	let b: [160]u8 = [0...];
	center_header(win, a, fmt::bsprintf(b, "Gendan: {}", g.name)!, icon::RESTORE);
	const bs = a.infos[a.sel].backups;
	if (a.rsel >= len(bs)) a.rsel = 0;
	viper::text(win, X(480), Y(180), "Vælg en backup, og tryk Gendan... to gange.", C_DIM);
	if (len(bs) == 0) {
		viper::text(win, X(480), Y(220), "Ingen backups endnu.", C_DIM);
	};
	def ROWS: int = 9;
	const top = 206, step = 46;
	if (hit(win, X(472), Y(top), L(675), L(step * ROWS))) a.rscroll -= viper::wheel(win);
	const maxs = if (len(bs): int > ROWS) len(bs): int - ROWS else 0;
	if (a.rscroll > maxs) a.rscroll = maxs;
	if (a.rscroll < 0) a.rscroll = 0;
	let z: [32]u8 = [0...], t: [32]u8 = [0...];
	for (let r = 0; r < ROWS && a.rscroll + r < len(bs): int; r += 1) {
		const i = (a.rscroll + r): size;
		const bk = bs[i];
		const y = Y(top + r * step), x = X(472), w = L(675), h = L(40);
		const on = i == a.rsel;
		neon(win, x, y, w, h, 6, if (on) C_YELLOW else C_CYAN_DIM, if (on) C_CARD_HI else C_CARD);
		const v = if (i < len(a.verified)) a.verified[i] else 0;
		if (v == 1) ok_badge(win, x + 18, y + h / 2, 8)
		else if (v == 2) {
			viper::circle(win, x + 18, y + h / 2, 8, C_RED);
			bold(win, x + 15, y + h / 2 - 8, "!", C_TEXT);
		} else viper::circle(win, x + 18, y + h / 2, 7, C_CYAN_DIM);
		bold(win, x + 36, y + h / 2 - 8, fmt::bsprintf(b, "v{}", bk.version)!, C_YELLOW);
		viper::text(win, x + 80, y + h / 2 - 8, stamp_text(t, bk.when), C_TEXT);
		viper::text(win, x + 230, y + h / 2 - 8, size_text(z, bk.sz), C_TEXT);
		viper::text(win, x + 320, y + h / 2 - 8, fmt::bsprintf(b, "{} filer", bk.files)!, C_DIM);
		if (len(bk.note) > 0) viper::text(win, x + 410, y + h / 2 - 8, bk.note, C_YELLOW);
		if (clicked(win, x, y, w, h)) a.rsel = i;
	};
	// Check, and the Steam Cloud warning.
	const wy = 636;
	if (len(bs) > 0 && btn(win, a, 480, wy, 220, 44, "Kontrollér", icon::CHECK, style::CYAN, false)) {
		match (verify(g.appid, bs[a.rsel].stamp)) {
		case void =>
			if (a.rsel < len(a.verified)) a.verified[a.rsel] = 1;
			say(a, "Backuppen er hel: alle filer passer.");
		case let e: failure =>
			if (a.rsel < len(a.verified)) a.verified[a.rsel] = 2;
			let m: [256]u8 = [0...];
			const n = copy_utf8(m, e);
			complain(a, strings::fromutf8_unsafe(m[..n]));
		};
	};
	const del = a.armed > 0.0 && a.armed_what == 3;
	if (len(bs) > 0 && btn(win, a, 720, wy, 220, 44, if (del) "Tryk igen!" else "Slet backup",
			icon::TRASH, style::RED, false)) {
		do_delete(a);
	};
	neon(win, X(480), Y(696), L(660), L(112), 8, C_YELLOW, 0xff1c1a08);
	bold(win, X(496), Y(706), "Steam Cloud", C_YELLOW);
	viper::text(win, X(496), Y(706) + 20, "Bruger spillet Steam Cloud, kan Steam lægge sine", C_TEXT);
	viper::text(win, X(496), Y(706) + 38, "egne saves tilbage. Slå det fra for spillet først", C_TEXT);
	viper::text(win, X(496), Y(706) + 56, "(Egenskaber > Generelt).", C_TEXT);
};

// ---- Sync ----

fn draw_sync(win: *viper::window, a: *app) void = {
	center_header(win, a, "Synkronisering", icon::SYNC);
	const x = X(484);
	let b: [256]u8 = [0...];
	bold(win, x, Y(180), "Backups gemmes i denne mappe, og MEGA holder den i sync:", C_TEXT);
	const dir = saves_dir();
	defer free(dir);
	text_clip(win, x + 16, Y(180) + 24, X(1150) - x, dir, C_YELLOW, false);
	viper::text(win, x + 16, Y(180) + 44, fmt::bsprintf(b, "<->  MEGA.nz: {}", MEGA_DIR)!, C_YELLOW);
	const st = if (a.slen > 0) sync_status(a) else "ikke tjekket endnu";
	const good = st == "Synced";
	if (good) ok_badge(win, x + 10, Y(290) + 8, 10) else cloud(win, x + 10, Y(290) + 8, C_DIM);
	bold(win, x + 30, Y(290), fmt::bsprintf(b, "Status: {}", st)!, if (good) C_GREEN else C_TEXT);
	const y = Y(330);
	if (st == NO_MEGA) {
		viper::text(win, x, y, "Installér MEGAcmd først (.deb fra mega.io/cmd):", C_DIM);
		viper::text(win, x + 16, y + 22, "sudo apt install ./megacmd-*.deb", C_TEXT);
		if (btn(win, a, 484, 410, 240, 50, "Tjek igen", icon::SYNC, style::CYAN, false)) check_mega(a, true);
	} else if (st == NOT_LOGGED_IN) {
		bold(win, x, y, "Log ind på MEGA:", C_TEXT);
		viper::textbox(win, &a.mail_tb, x, y + 26, L(420), "Mail");
		const enter = password_box(win, &a.pass_tb, x, y + 64, L(420));
		if (btn(win, a, 484, 470, 240, 50, "Log ind", icon::CLOUD_UP, style::CYAN, false) || enter) {
			do_login(a);
		};
		viper::text(win, x + L(440), y + 33, "Adgangskoden gemmes ikke;", C_DIM);
		viper::text(win, x + L(440), y + 53, "MEGAcmd husker selv login.", C_DIM);
	} else if (st == NOT_SYNCED) {
		viper::text(win, x, y, "Mappen er ikke sat op hos MEGA endnu. Så laves /HPO/Saves", C_DIM);
		viper::text(win, x, y + 20, "på MEGA, og mappen her holdes i sync med den.", C_DIM);
		if (btn(win, a, 484, 410, 320, 50, "Opsæt synkronisering", icon::SYNC, style::GREEN, false)) {
			let out: [120]u8 = [0...];
			match (mega_setup(out)) {
			case void =>
				log("Synkronisering sat op med MEGA.nz");
				check_mega(a, true);
			case let e: str =>
				let m: [160]u8 = [0...];
				complain(a, fmt::bsprintf(m, "MEGA: {}", e)!);
			};
		};
	} else {
		viper::text(win, x, y, "MEGA holder mappen i sync i baggrunden, også når programmet", C_DIM);
		viper::text(win, x, y + 20, "er lukket – så længe MEGAcmd kører.", C_DIM);
		if (btn(win, a, 484, 410, 240, 50, "Tjek nu", icon::SYNC, style::CYAN, false)) check_mega(a, true);
	};
	if (a.storelen > 0) {
		viper::text(win, x, Y(560), fmt::bsprintf(b, "Lagerplads: {}",
			strings::fromutf8_unsafe(a.store[..a.storelen]))!, C_TEXT);
	};
	viper::text(win, x, Y(620), "På en anden maskine: installér MEGAcmd, log ind her, og tryk", C_DIM);
	viper::text(win, x, Y(620) + 20, "Opsæt synkronisering – så kommer backupsene ned dertil.", C_DIM);
};

fn do_login(a: *app) void = {
	const mail = strings::trim(viper::textinput_str(&a.mail_tb));
	const pass = viper::textinput_str(&a.pass_tb);
	if (len(mail) == 0 || len(pass) == 0) {
		complain(a, "Skriv både mail og adgangskode.");
		return;
	};
	let out: [120]u8 = [0...];
	const r = mega_login(out, mail, pass);
	a.pass_tb.buf = [0...];
	a.pass_tb.length = 0;
	a.pass_tb.focused = false;
	match (r) {
	case void =>
		log("Logget ind på MEGA.nz");
		check_mega(a, true);
	case let e: str =>
		let m: [160]u8 = [0...];
		complain(a, fmt::bsprintf(m, "MEGA: {}", e)!);
	};
};

// A text field that shows dots.
fn password_box(win: *viper::window, tb: *viper::textinput, x: int, y: int, w: int) bool = {
	const enter = viper::textbox(win, tb, x, y, w, "Adgangskode");
	if (tb.length == 0) return enter;
	viper::rect(win, x + 1, y + 1, w - 2, 28, win.theme.widget_hot);
	let n = 0;
	for (let c .. tb.buf[..tb.length]) if (c & 0xC0 != 0x80) n += 1;
	for (let i = 0; i < n && 8 + i * 10 < w - 16; i += 1) viper::circle(win, x + 12 + i * 10, y + 15, 3, C_TEXT);
	return enter;
};

// ---- Games and their save folders ----

fn draw_paths(win: *viper::window, a: *app) void = {
	center_header(win, a, "Spil-stier", icon::FOLDER);
	const x = X(484);
	// Add a game.
	bold(win, x, Y(178), "Steam-spil findes selv (F5). Tilføj andre med AppID:", C_TEXT);
	viper::textbox(win, &a.tb_appid, x, Y(178) + 24, L(150), "AppID");
	viper::textbox(win, &a.tb_name, x + L(160), Y(178) + 24, L(300), "Navn");
	if (btn(win, a, 960, 202, 190, 42, "Tilføj spil", icon::GAMEPAD, style::GREEN, false)) {
		match (add_game(viper::textinput_str(&a.tb_appid), viper::textinput_str(&a.tb_name))) {
		case void =>
			let m: [160]u8 = [0...];
			log(fmt::bsprintf(m, "Spil tilføjet: {}", viper::textinput_str(&a.tb_name))!);
			a.tb_appid.length = 0;
			a.tb_name.length = 0;
			const id = strings::dup(GAMES[len(GAMES) - 1].appid)!;
			defer free(id);
			reload(a);
			match (find_game(id)) {
			case let i: size => pick(a, i);
			case void => void;
			};
			say(a, "Spillet er tilføjet. Giv det en save-mappe herunder.");
		case let e: str => complain(a, e);
		};
	};
	viper::rect(win, x, Y(262), X(1150) - x, 1, C_CYAN_DIM);
	if (len(GAMES) == 0) return;
	// The games, left; the chosen one's folders, right.
	const lx = x, ly = Y(276), lw = L(220);
	def PROWS: int = 10;
	if (hit(win, lx, ly, lw, L(44) * PROWS)) a.pscroll -= viper::wheel(win);
	const pmax = if (len(a.view): int > PROWS) len(a.view): int - PROWS else 0;
	if (a.pscroll > pmax) a.pscroll = pmax;
	if (a.pscroll < 0) a.pscroll = 0;
	for (let r = 0z; r < PROWS: size && a.pscroll: size + r < len(a.view); r += 1) {
		const gi = a.view[a.pscroll: size + r];
		const y = ly + r: int * L(44);
		const on = gi == a.sel;
		viper::round_rect(win, lx, y, lw, L(38), 6, if (on) C_YELLOW else 0xff0d1d44);
		viper::round_rect(win, lx + 2, y + 2, lw - 4, L(38) - 4, 5, if (on) C_CARD_HI else C_CARD);
		text_clip(win, lx + 10, y + (L(38) - 16) / 2, lw - 16, GAMES[gi].name, C_TEXT, on);
		if (clicked(win, lx, y, lw, L(38))) pick(a, gi);
	};
	const g = GAMES[a.sel];
	const rx = X(484) + L(240), rw = X(1150) - rx;
	let b: [160]u8 = [0...];
	text_clip(win, rx, Y(278), rw, fmt::bsprintf(b, "{} (AppID {})", g.name, g.appid)!, C_YELLOW, true);
	viper::text(win, rx, Y(278) + 22, "Save-mapper (C:\\... virker i WSL):", C_DIM);
	let y = Y(278) + 46;
	let remove: (size | void) = void;
	for (let i = 0z; i < len(g.dirs); i += 1) {
		field(win, rx, y, rw - L(90), 26, g.dirs[i]);
		if (btn(win, a, 1080, (y * 1672 / 1280), 70, 34, "Fjern", void, style::RED, false)) remove = i;
		y += 34;
	};
	match (remove) {
	case let i: size =>
		let m: [256]u8 = [0...];
		log(fmt::bsprintf(m, "Save-mappe fjernet fra {}: {}", g.name, g.dirs[i])!);
		free(GAMES[a.sel].dirs[i]);
		delete(GAMES[a.sel].dirs[i]);
		save_games();
		refresh(a, a.sel);
	case void => void;
	};
	if (viper::textbox(win, &a.tb_dir, rx, y, rw - L(90), "Ny save-mappe")
			|| btn(win, a, 1080, y * 1672 / 1280, 70, 34, "Tilføj", void, style::GREEN, false)) {
		const d = strings::trim(viper::textinput_str(&a.tb_dir));
		if (len(d) > 0) {
			append(GAMES[a.sel].dirs, strings::dup(d)!)!;
			save_games();
			let m: [256]u8 = [0...];
			log(fmt::bsprintf(m, "Save-mappe tilføjet til {}: {}", g.name, d)!);
			a.tb_dir.length = 0;
			a.tb_dir.focused = false;
			refresh(a, a.sel);
			if (!a.infos[a.sel].readable) complain(a, "Mappen kan ikke læses herfra – tjek stien.")
			else say(a, "Save-mappen er tilføjet.");
		};
	};
	y += 50;
	// The game's program.
	if (a.proc_for != a.sel + 1) {
		a.tb_proc.length = copy_utf8(a.tb_proc.buf, g.proc);
		a.proc_for = a.sel + 1;
	};
	viper::text(win, rx, y, "Spillets program (.exe), så backup", C_DIM);
	viper::text(win, rx, y + 18, "og gendan venter, til det er lukket:", C_DIM);
	y += 18;
	if (viper::textbox(win, &a.tb_proc, rx, y + 22, rw - L(90), "f.eks. DeathsDoor.exe")
			|| btn(win, a, 1080, (y + 22) * 1672 / 1280, 70, 34, "Gem", void, style::CYAN, false)) {
		free(GAMES[a.sel].proc);
		GAMES[a.sel].proc = strings::dup(strings::trim(viper::textinput_str(&a.tb_proc)))!;
		save_games();
		a.tb_proc.focused = false;
		say(a, "Programnavnet er gemt.");
	};
	// Remove the game (pressed twice); its backups stay.
	const armed = a.armed > 0.0 && a.armed_what == 2;
	if (btn(win, a, 960, 760, 190, 42, if (armed) "Tryk igen!" else "Fjern spillet", void,
			style::RED, false)) {
		if (armed) {
			let m: [160]u8 = [0...];
			log(fmt::bsprintf(m, "Spil fjernet: {} (backups beholdt)", g.name)!);
			remove_game(a.sel);
			a.armed = 0.0;
			a.sel = 0;
			reload(a);
			say(a, "Spillet er fjernet (og findes ikke igen). Dets backups er der stadig.");
		} else {
			a.armed = 4.0;
			a.armed_what = 2;
		};
	};
	// Games removed by hand can come back.
	if (len(HIDDEN) > 0) {
		let hb: [48]u8 = [0...];
		if (btn(win, a, 720, 760, 230, 42, fmt::bsprintf(hb, "Vis fjernede ({})", len(HIDDEN))!,
				void, style::CYAN, false)) {
			strings::freeall(HIDDEN);
			HIDDEN = [];
			save_settings();
			reload(a);
		};
	};
};

// ---- Settings, log, about ----

fn draw_settings(win: *viper::window, a: *app) void = {
	center_header(win, a, "Indstillinger", icon::COG);
	const x = X(484);
	let y = Y(180);
	const rows: [6](str, str) = [
		("Data", data_dir()),
		("Spil", "games.txt"),
		("Backups", "Saves/Steam/<AppID>/"),
		("Log", "log.txt"),
		("Skin", if (a.skin) "skin.png (i brug)" else "skin.png (læg dit mockup her)"),
		("Covers", "covers/<AppID>.png og <AppID>-banner.png"),
	];
	for (let r .. rows) {
		bold(win, x, y, r.0, C_YELLOW);
		text_clip(win, x + 90, y, X(1150) - x - 90, r.1, C_TEXT, false);
		y += 28;
	};
	y += 16;
	const tips = [
		"Covers hentes selv fra Steams cache eller server",
		"og laves til PNG med ImageMagick eller ffmpeg.",
		"Egne PNG'er i covers/ bruges i stedet.",
	];
	for (let t .. tips) {
		text_clip(win, x, y, X(1150) - x, t, C_DIM, false);
		y += 22;
	};
	// How many backups to keep.
	y += 20;
	bold(win, x, y + 10, "Behold backups pr. spil:", C_YELLOW);
	let kb: [32]u8 = [0...];
	const ks = if (KEEP == 0) "alle" else fmt::bsprintf(kb, "{} nyeste", KEEP)!;
	const ky = y * 1672 / 1280;
	let at = 0z;
	for (let i = 0z; i < len(KEEP_CHOICES); i += 1) if (KEEP_CHOICES[i] == KEEP) at = i;
	if (btn(win, a, 820, ky, 40, 36, "-", void, style::PLAIN, false) && at > 0) {
		KEEP = KEEP_CHOICES[at - 1];
		save_settings();
	};
	field(win, X(870), Y(ky), L(150), L(36), ks);
	if (btn(win, a, 1030, ky, 40, 36, "+", void, style::PLAIN, false) && at + 1 < len(KEEP_CHOICES)) {
		KEEP = KEEP_CHOICES[at + 1];
		save_settings();
	};
	viper::text(win, x, y + L(48), "Ældre slettes efter hver backup. \"alle\" sletter intet.", C_DIM);
	viper::text(win, x, y + L(48) + 20, "En enkelt backup slettes under Gendan.", C_DIM);
	if (btn(win, a, 484, 700, 260, 46, "Læs alt igen (F5)", icon::SYNC, style::CYAN, false)) {
		reload(a);
		check_mega(a, true);
	};
};

fn draw_log(win: *viper::window, a: *app) void = {
	center_header(win, a, "Log", icon::LOG);
	const x = X(484), top = Y(180), rows = (Y(800) - top) / 22;
	if (hit(win, x, top, X(1150) - x, rows * 22)) a.lscroll -= viper::wheel(win) * 3;
	const maxs = if (len(a.logs): int > rows) len(a.logs): int - rows else 0;
	if (a.lscroll > maxs) a.lscroll = maxs;
	if (a.lscroll < 0) a.lscroll = 0;
	if (len(a.logs) == 0) viper::text(win, x, top, "Intet i loggen endnu.", C_DIM);
	for (let r = 0; r < rows && a.lscroll + r < len(a.logs): int; r += 1) {
		const l = a.logs[(a.lscroll + r): size];
		const bad = strings::contains(l, "kunne ikke") || strings::contains(l, "kører")
			|| strings::contains(l, "ikke i orden") || strings::contains(l, "ingen save");
		text_clip(win, x, top + r * 22, X(1150) - x, l, if (bad) C_RED else C_TEXT, false);
	};
};

fn draw_about(win: *viper::window, a: *app) void = {
	center_header(win, a, "Om", icon::INFO);
	const x = X(484);
	bold2(win, x, Y(190), "HPO Steam Save Manager", C_YELLOW);
	const lines = [
		"Version 0.1.0  ·  Hare + ViperGui  ·  MEGA.nz via MEGAcmd",
		"",
		"Tager backup af save-filerne fra dine Steam-spil, gemmer flere",
		"versioner med en SHA-256 af hver fil, synkroniserer dem med MEGA.nz",
		"og lægger dem tilbage, når du vil.",
		"",
		"Før en gendannelse tjekkes, at spillet ikke kører og at backuppen er",
		"hel, og de saves, der er der, gemmes først i en backup af sig selv.",
		"",
		"Taster: op/ned vælger spil  ·  B tager backup  ·  F5 læser alt igen",
		"Tab: næste side  ·  Esc: luk",
		"",
		"Your games. Your saves. Your cloud.",
	];
	for (let i = 0z; i < len(lines); i += 1) {
		viper::text(win, x, Y(250) + i: int * 22, lines[i], if (i == len(lines) - 1) C_CYAN else C_TEXT);
	};
};

// ---- The bottom bar ----

fn draw_footer(win: *viper::window, a: *app) void = {
	let b: [128]u8 = [0...];
	// MEGA, left.
	paint(win, a, 278, 852, 380, 70, 275);
	const online = a.maillen > 0;
	if (online) ok_badge(win, X(297), Y(883), 11) else {
		viper::circle(win, X(297), Y(883), 11, if (a.slen > 0) C_RED else C_DIM);
		bold(win, X(297) - 3, Y(883) - 8, "!", C_TEXT);
	};
	bold(win, X(333), Y(874) - 8, "MEGA.nz:", C_TEXT);
	bold(win, X(333) + viper::text_width("MEGA.nz: ", 1), Y(874) - 8,
		if (online) "Forbundet" else if (a.slen == 0) "tjekker ..." else "Ikke forbundet",
		if (online) C_GREEN else C_DIM);
	if (online) viper::text(win, X(333), Y(899) - 8, strings::fromutf8_unsafe(a.mail[..a.maillen]), C_TEXT);
	// The last sync, middle.
	paint(win, a, 700, 852, 470, 70, 690);
	draw_icon(win, icon::SYNC, X(730), Y(883), C_TEXT);
	let t: [32]u8 = [0...];
	viper::text(win, X(762), Y(883) - 8, if (a.last_sync == 0) "Sidste synkronisering: aldrig"
		else fmt::bsprintf(b, "Sidste synkronisering: {}", stamp_text(t, a.last_sync))!, C_TEXT);
	// Storage, right.
	paint(win, a, 1205, 850, 445, 68, 1200);
	viper::text(win, X(1222), Y(868) - 8, if (a.storelen > 0)
		fmt::bsprintf(b, "MEGA.nz plads: {}", strings::fromutf8_unsafe(a.store[..a.storelen]))!
		else "MEGA.nz plads: ukendt", C_TEXT);
	const bx = X(1222), by = Y(889), bw = L(405), bh = L(17);
	viper::round_rect(win, bx, by, bw, bh, bh / 2, 0xff1a2440);
	const fw = (bw: f64 * a.store_f): int;
	if (fw > 0) viper::round_rect(win, bx, by, if (fw < bh) bh else fw, bh, bh / 2, C_GREEN);
};

fn draw_message(win: *viper::window, a: *app) void = {
	if (a.msg_t <= 0.0) return;
	const m = strings::fromutf8_unsafe(a.msg[..a.mlen]);
	const w = viper::text_width(m, 1) + 34;
	const x = (W - w) / 2, y = Y(96);
	const col = if (a.msg_bad) C_RED else C_CYAN;
	neon(win, x, y, w, 32, 8, col, C_INK);
	viper::text(win, x + 17, y + 8, m, if (a.msg_bad) 0xffffb3ba else C_TEXT);
};

// Splits s into at most len(out) lines no wider than w pixels (scale 1).
fn wrap(s: str, w: int, out: []str) size = {
	const b = strings::toutf8(s);
	const maxc = w / 8;
	let n = 0z, start = 0z;
	for (n < len(out)) {
		for (start < len(b) && b[start] == ' ') start += 1;
		if (start >= len(b)) break;
		let end = start, runes = 0, j = start;
		for (j < len(b)) {
			let k = j;
			for (k < len(b) && b[k] != ' ') k += 1;
			let wr = 0;
			for (let c .. b[j..k]) if (c & 0xC0 != 0x80) wr += 1;
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

// Did the lines take all of s?
fn fits(s: str, lines: []str) bool = {
	let n = 0z;
	for (let l .. lines) n += len(l);
	let words = 0z;
	for (let c .. strings::toutf8(s)) if (c != ' ') words += 1;
	let got = 0z;
	for (let l .. lines) for (let c .. strings::toutf8(l)) if (c != ' ') got += 1;
	return got == words;
};

fn longest(lines: []str, scale: int) int = {
	let m = 0;
	for (let l .. lines) {
		const w = viper::text_width(l, scale);
		if (w > m) m = w;
	};
	return m;
};
