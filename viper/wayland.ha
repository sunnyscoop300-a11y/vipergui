// ViperGui — Wayland backend, written in pure Hare (no libwayland).
//
// Wayland is just binary messages over a Unix socket: every message is
// [object id: u32][size << 16 | opcode: u32][arguments...], little endian.
// Pixels travel through shared memory: we draw into a memfd that the
// compositor maps too, and tell it which part changed.
//
// Text input uses a built-in Danish keyboard layout for now; reading the
// compositor's XKB keymap is the next step.
use endian;
use fmt;
use io;
use net;
use net::unix;
use os;
use rt;
use strings;
use time;
use unix::poll;
use encoding::utf8;

def NBUF: size = 2;

// The title bar ViperGui draws itself when the compositor won't (WSLg,
// GNOME): its height, and the close button's width at its right end.
def TB: int = 28;
def TB_CLOSE: int = 44;

// Internal to ViperGui.
export type wl_backend = struct {
	sock: net::socket,
	out: [8192]u8,
	outlen: size,
	inbuf: [65536]u8,
	inlen: size,
	next_id: u32,
	width: int,
	height: int,

	// Globals from the registry: (name, version).
	g_compositor: (u32, u32),
	g_shm: (u32, u32),
	g_wm: (u32, u32),
	g_seat: (u32, u32),
	g_deco: (u32, u32),
	g_cursor: (u32, u32),

	// Object ids.
	registry: u32,
	compositor: u32,
	shm: u32,
	wm: u32,
	seat: u32,
	deco_mgr: u32,
	cursor_mgr: u32,
	surface: u32,
	xdg_surface: u32,
	toplevel: u32,
	decoration: u32,
	pointer: u32,
	keyboard: u32,
	cursor_dev: u32,
	ptr_serial: u32,  // of the last pointer enter, for setting the cursor
	pool: u32,
	sync_cb: u32,
	sync_done: bool,

	// Shared-memory frame buffers.
	map: nullable *[*]u32,
	mapsize: size,
	buffers: [NBUF]u32,
	busy: [NBUF]bool,

	configured: bool,
	closed: bool,
	failed: bool,

	// Pointer.
	axis_acc: i32,
	discrete_seen: bool,

	// Keyboard: modifiers and software key repeat.
	shift: bool,
	caps: bool,
	ctrl: bool,
	altgr: bool,
	repeat_key: u32,
	repeat_next: u64,
	repeat_rate: u32,
	repeat_delay: u32,
	debug: bool, // VIPER_WLDEBUG=1 logs protocol traffic to stderr

	// Our own title bar (client-side decoration): tb is its height (0 when
	// the compositor draws one), bar its pixels, title its text.
	tb: int,
	bar: []u32,
	bar_hot: int,      // the close button under the pointer: 1, else 0
	bar_drawn: int,    // what bar shows: -1 = not drawn yet
	title: str,
	on_bar: bool,      // the pointer is over the title bar
	bar_x: int,
};

// ---- Opening and closing ----

fn wl_open(title: str, width: int, height: int) (*wl_backend | error | nomem) = {
	const name = os::tryenv("WAYLAND_DISPLAY", "wayland-0");
	const path = if (strings::hasprefix(name, "/")) strings::dup(name)?
		else match (os::getenv("XDG_RUNTIME_DIR")) {
		case let dir: str => yield strings::concat(dir, "/", name)?;
		case void => return "XDG_RUNTIME_DIR is not set": error;
		};
	defer free(path);

	const sock = match (unix::connect(path)) {
	case let s: net::socket => yield s;
	case net::error => return "could not connect to the Wayland compositor": error;
	};

	let be = alloc(wl_backend {
		sock = sock,
		next_id = 2, // 1 is wl_display
		width = width,
		height = height,
		repeat_rate = 25,
		repeat_delay = 600,
		debug = os::getenv("VIPER_WLDEBUG") is str,
		bar_drawn = -1,
		...
	})?;
	be.title = strings::dup(title)?;

	match (wl_setup(be, title)) {
	case void =>
		return be;
	case let e: error =>
		wl_close(be);
		return e;
	};
};

fn wl_setup(be: *wl_backend, title: str) (void | error) = {
	// wl_display.get_registry, then a roundtrip to collect the globals.
	be.registry = newid(be);
	let m = begin(be, 1, 1);
	put_u32(be, be.registry);
	end(be, m);
	roundtrip(be)?;

	if (be.g_compositor.0 == 0) return "compositor has no wl_compositor": error;
	if (be.g_shm.0 == 0) return "compositor has no wl_shm": error;
	if (be.g_wm.0 == 0) return "compositor has no xdg_wm_base (xdg-shell)": error;

	be.compositor = bind(be, be.g_compositor, "wl_compositor", 4);
	be.shm = bind(be, be.g_shm, "wl_shm", 1);
	be.wm = bind(be, be.g_wm, "xdg_wm_base", 1);
	if (be.g_seat.0 != 0) be.seat = bind(be, be.g_seat, "wl_seat", 5);
	if (be.debug) {
		fmt::errorfln("viper-wl: seat global {} v{} -> id {}; deco {}; cursor-shape {}",
			be.g_seat.0, be.g_seat.1, be.seat, be.g_deco.0, be.g_cursor.0)!;
	};
	if (be.g_deco.0 != 0) {
		be.deco_mgr = bind(be, be.g_deco, "zxdg_decoration_manager_v1", 1);
	};
	if (be.g_cursor.0 != 0) {
		be.cursor_mgr = bind(be, be.g_cursor, "wp_cursor_shape_manager_v1", 1);
	};

	// wl_compositor.create_surface
	be.surface = newid(be);
	m = begin(be, be.compositor, 0);
	put_u32(be, be.surface);
	end(be, m);
	// xdg_wm_base.get_xdg_surface
	be.xdg_surface = newid(be);
	m = begin(be, be.wm, 2);
	put_u32(be, be.xdg_surface);
	put_u32(be, be.surface);
	end(be, m);
	// xdg_surface.get_toplevel
	be.toplevel = newid(be);
	m = begin(be, be.xdg_surface, 1);
	put_u32(be, be.toplevel);
	end(be, m);
	// xdg_toplevel.set_title / set_app_id
	m = begin(be, be.toplevel, 2);
	put_str(be, title);
	end(be, m);
	m = begin(be, be.toplevel, 3);
	put_str(be, app_id());
	end(be, m);
	// No decoration manager (WSLg, GNOME): no title bar from the
	// compositor, so we draw our own. VIPER_CSD=1 forces it.
	if (be.deco_mgr == 0 || os::getenv("VIPER_CSD") is str) be.tb = TB;
	size_hints(be);
	// Ask for a title bar drawn by the compositor (KDE supports this).
	if (be.deco_mgr != 0 && be.tb == 0) {
		be.decoration = newid(be);
		m = begin(be, be.deco_mgr, 1);
		put_u32(be, be.decoration);
		put_u32(be, be.toplevel);
		end(be, m);
		m = begin(be, be.decoration, 1); // set_mode(server_side)
		put_u32(be, 2);
		end(be, m);
	};
	// Initial commit without a buffer; the compositor answers with configure.
	m = begin(be, be.surface, 6);
	end(be, m);

	for (let i = 0; i < 20 && !be.configured; i += 1) {
		roundtrip(be)?;
	};
	if (!be.configured) return "compositor never configured the window": error;
	// The compositor may have said it won't draw the title bar after all.
	if (be.tb > 0) {
		size_hints(be);
		be.bar = match (alloc([0u32...], (be.width * be.tb): size)) {
		case let b: []u32 => yield b;
		case nomem => return "out of memory": error;
		};
	};
	create_buffers(be)?;
};

// Fixed size: set_min_size and set_max_size to the same value (with our
// own title bar, if any).
fn size_hints(be: *wl_backend) void = {
	for (let op = 7u16; op <= 8; op += 1) {
		const m = begin(be, be.toplevel, op);
		put_u32(be, be.width: u32);
		put_u32(be, (be.height + be.tb): u32);
		end(be, m);
	};
};

// The app id tells the compositor which .desktop file (and so which icon
// and name) belongs to this window. It is the program's file name, e.g.
// "flappy-crane", unless VIPER_APP_ID is set.
fn app_id() str = {
	match (os::getenv("VIPER_APP_ID")) {
	case let s: str => return s;
	case void => void;
	};
	if (len(os::args) == 0) return "vipergui";
	const (_, name) = strings::rcut(os::args[0], "/");
	return if (len(name) == 0) os::args[0] else name;
};

fn wl_close(be: *wl_backend) void = {
	match (be.map) {
	case let p: *[*]u32 =>
		match (rt::munmap(p: *opaque, be.mapsize)) { case => void; };
	case null => void;
	};
	match (net::close(be.sock)) { case => void; };
	free(be.bar);
	free(be.title);
	free(be);
};

fn newid(be: *wl_backend) u32 = {
	const id = be.next_id;
	be.next_id += 1;
	return id;
};

// wl_registry.bind with an untyped new_id.
fn bind(be: *wl_backend, g: (u32, u32), iface: str, maxver: u32) u32 = {
	const id = newid(be);
	const ver = if (g.1 < maxver) g.1 else maxver;
	const m = begin(be, be.registry, 0);
	put_u32(be, g.0);
	put_str(be, iface);
	put_u32(be, ver);
	put_u32(be, id);
	end(be, m);
	return id;
};

// Two XRGB8888 buffers in one shared-memory pool.
fn create_buffers(be: *wl_backend) (void | error) = {
	const stride = be.width: size * 4;
	const bufsize = stride * (be.height + be.tb): size;
	be.mapsize = bufsize * NBUF;

	const fd = match (rt::memfd_create("viper-framebuffer", rt::MFD_CLOEXEC)) {
	case let fd: int => yield fd;
	case rt::errno => return "memfd_create failed": error;
	};
	defer match (io::close(fd: io::file)) { case => void; };
	match (rt::ftruncate(fd, be.mapsize: rt::off_t)) {
	case void => void;
	case rt::errno => return "ftruncate failed": error;
	};
	be.map = match (rt::mmap(null, be.mapsize, rt::PROT_READ | rt::PROT_WRITE,
			rt::MAP_SHARED, fd, 0)) {
	case let p: *opaque => yield p: *[*]u32;
	case rt::errno =>
		be.mapsize = 0;
		return "mmap failed": error;
	};

	// wl_shm.create_pool(id, fd, size): the fd travels as ancillary data.
	be.pool = newid(be);
	flush(be, void)?;
	let m = begin(be, be.shm, 0);
	put_u32(be, be.pool);
	put_u32(be, be.mapsize: u32);
	end(be, m);
	flush(be, fd: io::file)?;

	for (let i = 0z; i < NBUF; i += 1) {
		be.buffers[i] = newid(be);
		m = begin(be, be.pool, 0); // create_buffer
		put_u32(be, be.buffers[i]);
		put_u32(be, (i * bufsize): u32);
		put_u32(be, be.width: u32);
		put_u32(be, (be.height + be.tb): u32);
		put_u32(be, stride: u32);
		put_u32(be, 1); // WL_SHM_FORMAT_XRGB8888
		end(be, m);
	};
};

// ---- Per frame ----

fn wl_poll(win: *window, be: *wl_backend) bool = {
	match (read_events(win, be, poll::NONBLOCK)) {
	case void => void;
	case error => return false;
	};
	key_repeat(win, be);
	match (flush(be, void)) {
	case void => void;
	case error => return false;
	};
	return !be.closed && !be.failed;
};

fn wl_present(win: *window, be: *wl_backend) void = {
	if (!be.configured || be.failed) return;
	// Use a buffer the compositor isn't reading; if both are busy, wait
	// briefly for one to be released rather than tearing.
	let idx = NBUF;
	for (let tries = 0; idx == NBUF && tries < 10; tries += 1) {
		for (let i = 0z; i < NBUF; i += 1) {
			if (!be.busy[i]) {
				idx = i;
				break;
			};
		};
		if (idx == NBUF) {
			match (read_events(win, be, 2 * time::MILLISECOND)) {
			case void => void;
			case error => return;
			};
		};
	};
	if (idx == NBUF) return; // drop this frame

	const map = match (be.map) {
	case let p: *[*]u32 => yield p;
	case null => return;
	};
	const n = len(win.pixels);
	const nb = len(be.bar);
	const at = idx * (n + nb);
	if (nb > 0) {
		if (be.bar_drawn != be.bar_hot) draw_bar(win, be);
		map[at..at + nb] = be.bar;
	};
	map[at + nb..at + nb + n] = win.pixels;
	be.busy[idx] = true;

	let m = begin(be, be.surface, 1); // attach(buffer, 0, 0)
	put_u32(be, be.buffers[idx]);
	put_u32(be, 0);
	put_u32(be, 0);
	end(be, m);
	m = begin(be, be.surface, 2); // damage(0, 0, w, h)
	put_u32(be, 0);
	put_u32(be, 0);
	put_u32(be, be.width: u32);
	put_u32(be, (be.height + be.tb): u32);
	end(be, m);
	m = begin(be, be.surface, 6); // commit
	end(be, m);
	match (flush(be, void)) { case => void; };
};

// Draws our title bar: the window's title, and a close button that turns
// red under the pointer. It is drawn with ViperGui's own text and shapes,
// by pointing the window at the bar's pixels for a moment.
fn draw_bar(win: *window, be: *wl_backend) void = {
	const pixels = win.pixels, height = win.height;
	const cx0 = win.clip_x0, cy0 = win.clip_y0, cx1 = win.clip_x1, cy1 = win.clip_y1;
	win.pixels = be.bar;
	win.height = be.tb;
	clip(win, 0, 0, win.width, be.tb);
	const w = win.width;
	rect(win, 0, 0, w, be.tb, 0xff26262c);
	rect(win, 0, be.tb - 1, w, 1, 0xff121216);
	// The title, centred, shortened if it doesn't fit.
	let t = be.title;
	for (text_width(t, 1) > w - 2 * TB_CLOSE - 8 && len(t) > 0) {
		t = strings::sub(t, 0, runes(t): size - 1);
	};
	text(win, (w - text_width(t, 1)) / 2, (be.tb - FONT_H) / 2, t, 0xffe8e8ec);
	// Close.
	const bx = w - TB_CLOSE;
	if (be.bar_hot == 1) rect(win, bx, 0, TB_CLOSE, be.tb - 1, 0xffc42b1c);
	const cx = bx + TB_CLOSE / 2, cy = be.tb / 2;
	for (let d = -1; d <= 1; d += 1) {
		line(win, cx - 5 + d, cy - 5, cx + 5 + d, cy + 5, 0xfff0f0f0);
		line(win, cx - 5 + d, cy + 5, cx + 5 + d, cy - 5, 0xfff0f0f0);
	};
	win.pixels = pixels;
	win.height = height;
	win.clip_x0 = cx0;
	win.clip_y0 = cy0;
	win.clip_x1 = cx1;
	win.clip_y1 = cy1;
	be.bar_drawn = be.bar_hot;
};

// The pointer at surface position (x, y): over our title bar, or over the
// window's own pixels (which start below the bar).
fn pointer_at(win: *window, be: *wl_backend, x: int, y: int) void = {
	be.on_bar = y < be.tb;
	be.bar_x = x;
	be.bar_hot = if (be.on_bar && x >= be.width - TB_CLOSE) 1 else 0;
	if (be.on_bar) {
		win.mouse_x = -1;
		win.mouse_y = -1;
	} else {
		win.mouse_x = x;
		win.mouse_y = y - be.tb;
	};
};

// ---- Wire protocol: writing ----

fn begin(be: *wl_backend, obj: u32, op: u16) size = {
	if (be.outlen + 512 > len(be.out)) {
		match (flush(be, void)) { case => void; };
	};
	const start = be.outlen;
	put_u32(be, obj);
	put_u32(be, op: u32); // size is filled in by end()
	return start;
};

fn end(be: *wl_backend, start: size) void = {
	const sz = (be.outlen - start): u32;
	const word = endian::legetu32(be.out[start + 4..start + 8]);
	endian::leputu32(be.out[start + 4..start + 8], (sz << 16) | (word & 0xffff));
};

fn put_u32(be: *wl_backend, v: u32) void = {
	endian::leputu32(be.out[be.outlen..be.outlen + 4], v);
	be.outlen += 4;
};

fn put_str(be: *wl_backend, s: str) void = {
	const b = strings::toutf8(s);
	put_u32(be, (len(b) + 1): u32); // length includes the NUL
	be.out[be.outlen..be.outlen + len(b)] = b;
	be.outlen += len(b);
	be.out[be.outlen] = 0;
	be.outlen += 1;
	for (be.outlen % 4 != 0) {
		be.out[be.outlen] = 0;
		be.outlen += 1;
	};
};

// Sends everything queued; fd (if given) is attached to this batch.
fn flush(be: *wl_backend, fd: (io::file | void)) (void | error) = {
	if (be.outlen == 0) return;
	let msg = net::newmsg();
	defer net::finish(&msg);
	net::addvector(&msg, be.out[..be.outlen])!;
	match (fd) {
	case let f: io::file => unix::addfiles(&msg, f)!;
	case void => void;
	};
	match (net::sendmsg(be.sock, &msg)) {
	case size =>
		be.outlen = 0;
	case net::error =>
		be.failed = true;
		return "lost connection to the Wayland compositor": error;
	};
};

// ---- Wire protocol: reading ----

// Waits up to `timeout` for events and dispatches all complete messages.
fn read_events(win: nullable *window, be: *wl_backend, wait: time::duration) (void | error) = {
	let timeout = wait;
	let pfd = [poll::pollfd { fd = be.sock: io::file, events = poll::event::POLLIN, ... }];
	for (true) {
		const n = match (poll::poll(pfd, timeout)) {
		case let n: uint => yield n;
		case => return "poll failed": error;
		};
		if (n == 0) break;
		if (pfd[0].revents & (poll::event::POLLHUP | poll::event::POLLERR): i16 != 0) {
			be.failed = true;
			return "Wayland connection closed": error;
		};
		match (io::read(be.sock: io::file, be.inbuf[be.inlen..])) {
		case let n: size =>
			be.inlen += n;
		case io::EOF =>
			be.failed = true;
			return "Wayland connection closed": error;
		case io::error =>
			be.failed = true;
			return "read from Wayland socket failed": error;
		};
		dispatch(win, be);
		timeout = poll::NONBLOCK; // drain whatever else is ready
	};
};

fn dispatch(win: nullable *window, be: *wl_backend) void = {
	let pos = 0z;
	for (be.inlen - pos >= 8) {
		const obj = endian::legetu32(be.inbuf[pos..pos + 4]);
		const word = endian::legetu32(be.inbuf[pos + 4..pos + 8]);
		const sz = (word >> 16): size;
		const op = (word & 0xffff): u16;
		if (sz < 8 || be.inlen - pos < sz) break;
		handle(win, be, obj, op, be.inbuf[pos + 8..pos + sz]);
		pos += sz;
	};
	// Keep any partial message for next time.
	const rest = be.inlen - pos;
	for (let i = 0z; i < rest; i += 1) be.inbuf[i] = be.inbuf[pos + i];
	be.inlen = rest;
};

type args = struct { d: []u8, i: size };

fn get_u32(a: *args) u32 = {
	if (a.i + 4 > len(a.d)) return 0;
	const v = endian::legetu32(a.d[a.i..a.i + 4]);
	a.i += 4;
	return v;
};

fn get_i32(a: *args) i32 = get_u32(a): i32;

fn get_str(a: *args) str = {
	const n = get_u32(a): size;
	if (n == 0 || a.i + n > len(a.d)) return "";
	const s = strings::fromutf8_unsafe(a.d[a.i..a.i + n - 1]);
	a.i += (n + 3) & ~3z;
	return s;
};

fn roundtrip(be: *wl_backend) (void | error) = {
	be.sync_cb = newid(be);
	be.sync_done = false;
	const m = begin(be, 1, 0); // wl_display.sync
	put_u32(be, be.sync_cb);
	end(be, m);
	flush(be, void)?;
	const deadline = now_ms() + 3000;
	for (!be.sync_done) {
		if (be.failed) return "Wayland protocol error": error;
		if (now_ms() > deadline) return "Wayland compositor did not respond": error;
		read_events(null, be, 100 * time::MILLISECOND)?;
	};
};

// ---- Events ----

fn objname(be: *wl_backend, obj: u32) str = {
	if (obj == 1) return "wl_display";
	if (obj == be.registry) return "wl_registry";
	if (obj == be.seat) return "wl_seat";
	if (obj == be.pointer) return "wl_pointer";
	if (obj == be.keyboard) return "wl_keyboard";
	if (obj == be.wm) return "xdg_wm_base";
	if (obj == be.xdg_surface) return "xdg_surface";
	if (obj == be.toplevel) return "xdg_toplevel";
	if (obj == be.surface) return "wl_surface";
	if (obj == be.decoration) return "zxdg_toplevel_decoration";
	for (let b .. be.buffers) if (obj == b) return "wl_buffer";
	if (obj == be.sync_cb) return "wl_callback";
	return "?";
};

fn handle(win: nullable *window, be: *wl_backend, obj: u32, op: u16, data: []u8) void = {
	let a = args { d = data, ... };
	if (be.debug && objname(be, obj) != "wl_buffer" && objname(be, obj) != "wl_callback") {
		fmt::errorf("viper-wl: <- {}@{}.event{} ({} bytes){}\n",
			objname(be, obj), obj, op, len(data),
			if (win == null) " [setup]" else "")!;
		if (obj == be.registry && op == 0) {
			let b = a;
			get_u32(&b);
			fmt::errorfln("viper-wl:      global {}", get_str(&b))!;
		};
	};

	if (obj == 1) {
		if (op == 0) { // wl_display.error
			const o = get_u32(&a), code = get_u32(&a);
			fmt::errorfln("viper: Wayland error on object {}, code {}: {}",
				o, code, get_str(&a))!;
			be.failed = true;
		};
		return;
	};
	if (obj == be.registry) {
		if (op != 0) return; // global_remove: ignored
		const name = get_u32(&a);
		const iface = get_str(&a);
		const ver = get_u32(&a);
		switch (iface) {
		case "wl_compositor" => be.g_compositor = (name, ver);
		case "wl_shm" => be.g_shm = (name, ver);
		case "xdg_wm_base" => be.g_wm = (name, ver);
		case "wl_seat" =>
			if (be.g_seat.0 == 0) be.g_seat = (name, ver);
		case "zxdg_decoration_manager_v1" => be.g_deco = (name, ver);
		case "wp_cursor_shape_manager_v1" => be.g_cursor = (name, ver);
		case => void;
		};
		return;
	};
	if (obj == be.sync_cb && obj != 0) {
		be.sync_done = true;
		return;
	};
	if (obj == be.wm && op == 0) { // xdg_wm_base.ping -> pong
		const serial = get_u32(&a);
		const m = begin(be, be.wm, 3);
		put_u32(be, serial);
		end(be, m);
		return;
	};
	if (obj == be.xdg_surface && op == 0) { // configure -> ack_configure
		const serial = get_u32(&a);
		const m = begin(be, be.xdg_surface, 4);
		put_u32(be, serial);
		end(be, m);
		be.configured = true;
		return;
	};
	if (obj == be.toplevel) {
		if (op == 1) be.closed = true; // close button
		return;
	};
	if (obj == be.decoration && obj != 0) {
		// configure(mode): 1 = we must draw the title bar ourselves.
		if (op == 0 && get_u32(&a) == 1 && be.tb == 0 && len(be.bar) == 0) {
			be.tb = TB;
		};
		return;
	};
	for (let i = 0z; i < NBUF; i += 1) {
		if (obj == be.buffers[i] && op == 0) { // wl_buffer.release
			be.busy[i] = false;
			return;
		};
	};
	if (obj == be.seat && op == 0) { // capabilities
		const caps = get_u32(&a);
		if (caps & 1 != 0 && be.pointer == 0) {
			be.pointer = newid(be);
			let m = begin(be, be.seat, 0);
			put_u32(be, be.pointer);
			end(be, m);
			if (be.cursor_mgr != 0) {
				be.cursor_dev = newid(be);
				m = begin(be, be.cursor_mgr, 1);
				put_u32(be, be.cursor_dev);
				put_u32(be, be.pointer);
				end(be, m);
			};
		};
		if (caps & 2 != 0 && be.keyboard == 0) {
			be.keyboard = newid(be);
			const m = begin(be, be.seat, 1);
			put_u32(be, be.keyboard);
			end(be, m);
		};
		return;
	};

	const win = match (win) {
	case let w: *window => yield w;
	case null => return; // input during setup is ignored
	};
	if (obj == be.pointer && obj != 0) {
		pointer_event(win, be, op, &a);
	} else if (obj == be.keyboard && obj != 0) {
		keyboard_event(win, be, op, &a);
	};
};

fn pointer_event(win: *window, be: *wl_backend, op: u16, a: *args) void = {
	switch (op) {
	case 0 => // enter(serial, surface, x, y)
		be.ptr_serial = get_u32(a);
		get_u32(a);
		const x = get_i32(a) / 256;
		pointer_at(win, be, x, get_i32(a) / 256);
		wl_cursor(win, be);
	case 1 => // leave
		win.mouse_x = -1;
		win.mouse_y = -1;
		be.on_bar = false;
		be.bar_hot = 0;
	case 2 => // motion(time, x, y)
		get_u32(a);
		const x = get_i32(a) / 256;
		pointer_at(win, be, x, get_i32(a) / 256);
	case 3 => // button(serial, time, button, state)
		const serial = get_u32(a);
		get_u32(a);
		const button = get_u32(a), state = get_u32(a);
		if (be.on_bar && state == 1) {
			// Our title bar: the close button, or drag to move. (Releases
			// still go to the window, which may have a button held.)
			if (button == 0x110) {
				if (be.bar_hot == 1) {
					be.closed = true;
				} else if (be.seat != 0) {
					const m = begin(be, be.toplevel, 5); // move(seat, serial)
					put_u32(be, be.seat);
					put_u32(be, serial);
					end(be, m);
				};
			};
			return;
		};
		const bit: u8 = switch (button) {
		case 0x110 => yield LEFT_BUTTON;   // BTN_LEFT
		case 0x111 => yield RIGHT_BUTTON;  // BTN_RIGHT
		case 0x112 => yield MIDDLE_BUTTON; // BTN_MIDDLE
		case => yield 0;
		};
		if (state == 1) {
			win.buttons |= bit;
			win.pend.clicks |= bit;
		} else {
			win.buttons &= ~bit;
		};
		if (button == 0x110) { // BTN_LEFT
			if (state == 1) {
				win.pend.mouse_pressed = true;
				win.mouse_down = true;
			} else {
				win.pend.mouse_released = true;
				win.mouse_down = false;
			};
		};
	case 4 => // axis(time, axis, value) — smooth scrolling
		get_u32(a);
		const axis = get_u32(a), v = get_i32(a);
		if (axis != 0 || be.discrete_seen) return;
		be.axis_acc += v;
		for (be.axis_acc >= 2560) { win.pend.wheel -= 1; be.axis_acc -= 2560; };
		for (be.axis_acc <= -2560) { win.pend.wheel += 1; be.axis_acc += 2560; };
	case 5 => // frame
		be.discrete_seen = false;
	case 8 => // axis_discrete(axis, steps) — mouse wheel clicks
		const axis = get_u32(a), steps = get_i32(a);
		if (axis == 0) {
			win.pend.wheel -= steps;
			be.discrete_seen = true;
		};
	case => void;
	};
};

// Sets the pointer over the window: the normal arrow, or none.
fn wl_cursor(win: *window, be: *wl_backend) void = {
	if (be.pointer == 0 || be.ptr_serial == 0) return;
	if (win.cursor_hidden && be.cursor_dev != 0) {
		// wl_pointer.set_cursor(serial, no surface, 0, 0)
		const m = begin(be, be.pointer, 0);
		put_u32(be, be.ptr_serial);
		put_u32(be, 0);
		put_u32(be, 0);
		put_u32(be, 0);
		end(be, m);
	} else if (be.cursor_dev != 0) {
		const m = begin(be, be.cursor_dev, 1);
		put_u32(be, be.ptr_serial);
		put_u32(be, 1); // shape: default
		end(be, m);
	};
};

fn keyboard_event(win: *window, be: *wl_backend, op: u16, a: *args) void = {
	switch (op) {
	case 2 => // leave: forget held keys
		win.keys = [0...];
		be.repeat_key = 0;
	case 3 => // key(serial, time, key, state)
		get_u32(a);
		get_u32(a);
		const code = get_u32(a), state = get_u32(a);
		const hid = evdev_to_hid(code);
		if (state == 1) {
			if (hid != 0) {
				win.keys[hid] = 1;
				win.pend.keys_pressed[hid] = true;
				win.pend.keys_typed[hid] = true;
			};
			const r = type_key(win, be, code);
			add_keyevent(win, keyevent {
				hid = hid: u16,
				down = true,
				text = match (r) { case let r: rune => yield r; case void => yield '\0'; },
				...
			});
			if (repeats(code)) {
				be.repeat_key = code;
				be.repeat_next = now_ms() + be.repeat_delay;
			};
		} else {
			if (hid != 0) win.keys[hid] = 0;
			if (be.repeat_key == code) be.repeat_key = 0;
			add_keyevent(win, keyevent { hid = hid: u16, ... });
		};
	case 4 => // modifiers(serial, depressed, latched, locked, group)
		get_u32(a);
		const dep = get_u32(a), lat = get_u32(a), lock = get_u32(a);
		const m = dep | lat;
		be.shift = m & 1 != 0;
		be.caps = lock & 2 != 0;
		be.ctrl = m & 4 != 0;
		be.altgr = m & 0x80 != 0; // Mod5 = ISO_Level3_Shift
	case 5 => // repeat_info(rate, delay)
		be.repeat_rate = get_u32(a);
		be.repeat_delay = get_u32(a);
	case => void; // keymap, enter
	};
};

// Wayland leaves key repeat to the client.
fn key_repeat(win: *window, be: *wl_backend) void = {
	if (be.repeat_key == 0 || be.repeat_rate == 0) return;
	const now = now_ms();
	for (now >= be.repeat_next) {
		const hid = evdev_to_hid(be.repeat_key);
		if (hid != 0) win.pend.keys_typed[hid] = true;
		const r = type_key(win, be, be.repeat_key);
		add_keyevent(win, keyevent {
			hid = hid: u16,
			down = true,
			repeat = true,
			text = match (r) { case let r: rune => yield r; case void => yield '\0'; },
		});
		be.repeat_next += 1000 / be.repeat_rate;
	};
};

fn repeats(code: u32) bool = switch (code) {
case 29, 42, 54, 56, 97, 100, 58, 125, 126, 1 => yield false; // modifiers, Esc
case => yield true;
};

// ---- Keys ----

// Linux evdev key codes -> USB HID scancodes (layout independent).
fn evdev_to_hid(code: u32) size = {
	if (code >= len(evdev_hid)) return 0;
	return evdev_hid[code]: size;
};

const evdev_hid: [128]u8 = [
	0, 41, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 45, 46, 42, 43,       // 0-15
	20, 26, 8, 21, 23, 28, 24, 12, 18, 19, 47, 48, 40, 224, 4, 22,      // 16-31
	7, 9, 10, 11, 13, 14, 15, 51, 52, 53, 225, 49, 29, 27, 6, 25,        // 32-47
	5, 17, 16, 54, 55, 56, 229, 85, 226, 44, 57, 58, 59, 60, 61, 62,     // 48-63
	63, 64, 65, 66, 67, 83, 71, 95, 96, 97, 86, 92, 93, 94, 87, 89,      // 64-79
	90, 91, 98, 99, 0, 0, 100, 68, 69, 0, 0, 0, 0, 0, 0, 0,              // 80-95
	88, 228, 84, 70, 230, 0, 74, 82, 75, 80, 79, 77, 81, 78, 73, 76,     // 96-111
	0, 0, 0, 0, 0, 0, 0, 72, 0, 0, 0, 0, 0, 227, 231, 101,               // 112-127
];

// Danish keyboard layout (evdev code -> normal / shift / AltGr). This is a
// stand-in until the compositor's XKB keymap is parsed. Dead keys
// (´ ¨ ^ ~) are left out.
fn layout_dk(code: u32, shift: bool, altgr: bool) (rune | void) = {
	if (altgr) return switch (code) {
	case 3 => yield '@';
	case 4 => yield '£';
	case 5 => yield '$';
	case 6 => yield '€';
	case 8 => yield '{';
	case 9 => yield '[';
	case 10 => yield ']';
	case 11 => yield '}';
	case 13 => yield '|';
	case 18 => yield '€';
	case 86 => yield '\\';
	case 50 => yield 'µ';
	case => yield void;
	};
	const pair: (rune, rune) = switch (code) {
	case 2 => yield ('1', '!');
	case 3 => yield ('2', '"');
	case 4 => yield ('3', '#');
	case 5 => yield ('4', '¤');
	case 6 => yield ('5', '%');
	case 7 => yield ('6', '&');
	case 8 => yield ('7', '/');
	case 9 => yield ('8', '(');
	case 10 => yield ('9', ')');
	case 11 => yield ('0', '=');
	case 12 => yield ('+', '?');
	case 41 => yield ('½', '§');
	case 26 => yield ('å', 'Å');
	case 39 => yield ('æ', 'Æ');
	case 40 => yield ('ø', 'Ø');
	case 43 => yield ('\'', '*');
	case 86 => yield ('<', '>');
	case 51 => yield (',', ';');
	case 52 => yield ('.', ':');
	case 53 => yield ('-', '_');
	case 57 => yield (' ', ' ');
	case => return letter_dk(code, shift);
	};
	return if (shift) pair.1 else pair.0;
};

fn letter_dk(code: u32, shift: bool) (rune | void) = {
	const letters = strings::toutf8("qwertyuiop    asdfghjkl     zxcvbnm");
	if (code < 16 || code > 50) return;
	const c = letters[code - 16];
	if (c == ' ') return;
	return if (shift) (c - 32): rune else c: rune;
};

fn type_key(win: *window, be: *wl_backend, code: u32) (rune | void) = {
	if (be.ctrl) return;
	// Caps Lock works on letters (including æøå), like Shift.
	const letter = (code >= 16 && code <= 26) || (code >= 30 && code <= 40)
		|| (code >= 44 && code <= 50);
	const shift = if (letter && be.caps) !be.shift else be.shift;
	match (layout_dk(code, shift, be.altgr)) {
	case let r: rune =>
		add_typed(win, utf8::encoderune(r));
		return r;
	case void => return;
	};
};
