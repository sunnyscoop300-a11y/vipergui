// Mastodon — a ViperGui chat app. Chat with Mastodon (an AI on OpenRouter)
// while his portrait reacts: idle, thinking, talking and blinking.
//
// Environment:
//   OPENROUTER_API_KEY   your OpenRouter key (required)
//   MASTODON_MODEL       model id (default google/gemini-4-argon)
//   MASTODON_DIR         sprite/persona folder (default assets/mastodon)
//   MASTODON_API_URL     endpoint (default OpenRouter chat completions)
use fmt;
use io;
use memio;
use os;
use strings;
use viper;

def W: int = 960;
def H: int = 640;
def PORTRAIT: int = 300;

// Chat area.
def CX: int = 366;
def CY: int = 44;
def CW: int = 570;
def CH: int = 512;
def LINE_H: int = 18;
def BUBBLE_COLS: int = 50;

def DEFAULT_PERSONA: str =
	"Du er Mastodon, en ældgammel, klog og godhjertet mastodont med et "
	"tørt, lidt gnavent lune. Du har set istider komme og gå og elsker at "
	"dele visdom, men du griner også af dig selv. Du taler dansk, medmindre "
	"brugeren skriver på et andet sprog. Du bliver altid i rollen.";

def GREETING: str = "Hrmpf... en besøgende! Jeg er Mastodon. "
	"Sæt dig ned ved bålet, og spørg om hvad du vil.";

type kind = enum { USER, MASTODON, INFO };

type msg = struct {
	kind: kind,
	text: str,
};

type chat = struct {
	msgs: []msg,
	persona: str,
	nrequests: uint,
};

type sprites = struct {
	idle: nullable *viper::image,
	talk: nullable *viper::image,
	think: nullable *viper::image,
	blink: nullable *viper::image,
};

// A dark, icy theme for Mastodon.
const mammoth: viper::theme = viper::theme {
	bg = 0xff12161d,
	panel = 0xff1c232d,
	border = 0xff38455a,
	text = 0xffeae4d6,
	text_dim = 0xff8d98a9,
	widget = 0xff28313f,
	widget_hot = 0xff323d4e,
	accent = 0xff86bde0,
	accent_hot = 0xffa4d0ec,
	accent_active = 0xff6299c0,
};

// Removes what the 8x16 font can't show anyway: emoji, joiners and
// variation selectors, plus markdown bold markers. Returns a new string.
fn clean(s: str) str = {
	let out = memio::dynamic();
	let it = strings::iter(s);
	let prev: rune = '\0';
	for (let r => strings::next(&it)) {
		const c = r: u32;
		const drop = c >= 0x1f000 || (c >= 0x2600 && c < 0x2800)
			|| c == 0x200d || c == 0xfe0f || (c >= 0x2b00 && c < 0x2c00);
		if (drop) continue;
		if (r == '*' && prev == '*') continue; // "**bold**" -> "*bold*"
		memio::appendrune(&out, r)!;
		prev = r;
	};
	const res = strings::trim(memio::string(&out)!);
	const dup = strings::dup(res)!;
	io::close(&out)!;
	return dup;
};

fn add(c: *chat, k: kind, text: str) void = {
	append(c.msgs, msg { kind = k, text = strings::dup(text)! })!;
};

// The OpenRouter key: $OPENROUTER_API_KEY, or else the first line of
// ~/.config/vipergui/openrouter.key (handy when started from the menu,
// where your shell's exports aren't visible).
fn find_apikey() (str | void) = {
	match (os::getenv("OPENROUTER_API_KEY")) {
	case let k: str =>
		if (len(k) > 0) return k;
	case void => void;
	};
	const home = match (os::getenv("HOME")) {
	case let h: str => yield h;
	case void => return;
	};
	const base = os::tryenv("XDG_CONFIG_HOME", "");
	const path = if (len(base) > 0)
		strings::concat(base, "/vipergui/openrouter.key")!
		else strings::concat(home, "/.config/vipergui/openrouter.key")!;
	defer free(path);
	const f = match (os::open(path)) {
	case let f: io::file => yield f;
	case => return;
	};
	defer io::close(f)!;
	const data = match (io::drain(f)) {
	case let d: []u8 => yield d;
	case => return;
	};
	const s = match (strings::fromutf8(data)) {
	case let s: str => yield s;
	case => free(data); return;
	};
	const (line, _) = strings::cut(s, "\n");
	const key = strings::trim(line);
	if (len(key) == 0) {
		free(data);
		return;
	};
	return key; // lives for the whole program
};

// Loads one sprite and scales it to fit the portrait box.
fn load_sprite(c: *chat, dir: str, name: str) nullable *viper::image = {
	const path = strings::concat(dir, "/", name)!;
	defer free(path);
	if (!os::exists(path)) return null;
	match (viper::load_png(path)) {
	case let img: viper::image =>
		defer viper::image_free(&img);
		let w = PORTRAIT, h = PORTRAIT;
		if (img.w > img.h) {
			h = PORTRAIT * img.h / img.w;
		} else {
			w = PORTRAIT * img.w / img.h;
		};
		return alloc(viper::resize(&img, w, h)!)!;
	case let e: viper::imgerror =>
		const m = fmt::asprintf("Kunne ikke læse {}: {}", path,
			viper::imgstrerror(e))!;
		defer free(m);
		add(c, kind::INFO, m);
		return null;
	};
};

fn override(slot: *nullable *viper::image, img: nullable *viper::image) void = {
	if (img != null) *slot = img;
};

// Loads mastodon.png: a sheet with up to four frames side by side, in the
// order idle, talk, blink, think (only idle is required).
fn load_sheet(c: *chat, dir: str, sp: *sprites) void = {
	const path = strings::concat(dir, "/mastodon.png")!;
	defer free(path);
	if (!os::exists(path)) return;
	let sheet = match (viper::load_png(path)) {
	case let img: viper::image => yield img;
	case let e: viper::imgerror =>
		const m = fmt::asprintf("Kunne ikke læse {}: {}", path,
			viper::imgstrerror(e))!;
		defer free(m);
		add(c, kind::INFO, m);
		return;
	};
	defer viper::image_free(&sheet);
	const frames = viper::split_sheet(&sheet, PORTRAIT, PORTRAIT)!;
	defer free(frames); // the images themselves live on in sp
	const slots: [4]*nullable *viper::image = [&sp.idle, &sp.talk, &sp.blink, &sp.think];
	for (let i = 0z; i < len(frames); i += 1) {
		if (i < len(slots)) {
			*slots[i] = alloc(frames[i])!;
		} else {
			viper::image_free(&frames[i]);
		};
	};
};

fn read_persona(dir: str) str = {
	const path = strings::concat(dir, "/persona.txt")!;
	defer free(path);
	match (os::open(path)) {
	case let f: io::file =>
		defer io::close(f)!;
		match (io::drain(f)) {
		case let d: []u8 =>
			match (strings::fromutf8(d)) {
			case let s: str =>
				const t = strings::trim(s);
				if (len(t) > 0) return t;
			case => void;
			};
			free(d);
		case => void;
		};
	case => void;
	};
	return DEFAULT_PERSONA;
};

// A line of wrapped text: byte range [start, end) of a message.
type span = struct { start: size, end: size };

// Word-wraps s to at most cols characters per line.
fn wrap(s: str, cols: int, out: *[]span) void = {
	let line_start = 0z, brk = 0z, brk_col = 0, col = 0;
	let it = strings::iter(s);
	for (true) {
		const pos = strings::position(&it);
		const r = match (strings::next(&it)) {
		case let r: rune => yield r;
		case done => break;
		};
		if (r == '\n') {
			append(out, span { start = line_start, end = pos })!;
			line_start = pos + 1;
			brk = line_start;
			col = 0;
			continue;
		};
		col += 1;
		if (r == ' ') {
			brk = strings::position(&it);
			brk_col = col;
		};
		if (col > cols) {
			if (brk > line_start) {
				// Break after the last space; drop that space.
				append(out, span { start = line_start, end = brk - 1 })!;
				line_start = brk;
				col -= brk_col;
			} else {
				// One very long word: hard break.
				append(out, span { start = line_start, end = pos })!;
				line_start = pos;
				col = 1;
			};
			brk = line_start;
		};
	};
	append(out, span { start = line_start, end = len(s) })!;
};

fn sub(s: str, sp: span) str =
	strings::fromutf8_unsafe(strings::toutf8(s)[sp.start..sp.end]);

// The first n characters of s.
fn first_runes(s: str, n: int) str = {
	let it = strings::iter(s);
	for (let i = 0; i < n; i += 1) {
		if (strings::next(&it) is done) break;
	};
	return strings::fromutf8_unsafe(
		strings::toutf8(s)[..strings::position(&it)]);
};

// Height of one message in the chat log.
fn msg_height(m: *msg, lines: size) int = switch (m.kind) {
case kind::INFO => yield lines: int * LINE_H + 12;
case => yield 18 + lines: int * LINE_H + 16 + 14;
};

// Draws the chat log. reveal_idx/reveal limit how much of a message is
// shown (typewriter effect); busy adds a "thinking" bubble at the end.
fn draw_chat(
	win: *viper::window,
	c: *chat,
	scroll: *int,
	reveal_idx: size,
	reveal: int,
	busy: bool,
	t: f64,
) void = {
	const th = &win.theme;
	let lines: []span = [];
	defer free(lines);

	// Measure.
	let total = 8;
	for (let i = 0z; i < len(c.msgs); i += 1) {
		lines = lines[..0];
		const cols = if (c.msgs[i].kind == kind::INFO) 66 else BUBBLE_COLS;
		wrap(c.msgs[i].text, cols, &lines);
		total += msg_height(&c.msgs[i], len(lines));
	};
	if (busy) total += 18 + LINE_H + 16 + 14;

	// Scrolling (scroll = pixels up from the bottom).
	*scroll += viper::wheel(win) * 40;
	const maxscroll = if (total > CH) total - CH else 0;
	if (*scroll > maxscroll) *scroll = maxscroll;
	if (*scroll < 0) *scroll = 0;
	let y = if (total > CH) CY + CH - total + *scroll + 8 else CY + 8;

	viper::clip(win, CX, CY, CW, CH);
	defer viper::noclip(win);

	for (let i = 0z; i < len(c.msgs); i += 1) {
		const m = &c.msgs[i];
		lines = lines[..0];
		const cols = if (m.kind == kind::INFO) 66 else BUBBLE_COLS;
		wrap(m.text, cols, &lines);
		const h = msg_height(m, len(lines));
		if (y + h < CY || y > CY + CH) {
			y += h;
			continue;
		};

		if (m.kind == kind::INFO) {
			for (let k = 0z; k < len(lines); k += 1) {
				const s = sub(m.text, lines[k]);
				viper::text(win, CX + (CW - viper::text_width(s, 1)) / 2,
					y + k: int * LINE_H, s, 0xffd9a35f);
			};
			y += h;
			continue;
		};

		let widest = 0;
		for (let sp .. lines) {
			const w = viper::text_width(sub(m.text, sp), 1);
			if (w > widest) widest = w;
		};
		const bw = widest + 24;
		const bh = len(lines): int * LINE_H + 16;
		const user = m.kind == kind::USER;
		const bx = if (user) CX + CW - bw - 12 else CX + 12;

		const who = if (user) "Dig" else "Mastodon";
		viper::text(win, if (user) CX + CW - 12 - viper::text_width(who, 1) else bx,
			y, who, th.text_dim);
		const by = y + 18;
		viper::round_rect(win, bx, by, bw, bh, 8,
			if (user) th.accent_active else th.widget_hot);

		// Typewriter: only show `reveal` characters of the newest reply.
		let budget = if (i == reveal_idx) reveal else 1 << 30;
		for (let k = 0z; k < len(lines) && budget > 0; k += 1) {
			let s = sub(m.text, lines[k]);
			const n = viper::runes(s);
			if (budget < n) s = first_runes(s, budget);
			viper::text(win, bx + 12, by + 8 + k: int * LINE_H, s,
				if (user) 0xff0f1620 else th.text);
			budget -= n + 1;
		};
		y += h;
	};

	if (busy) {
		viper::text(win, CX + 12, y, "Mastodon", th.text_dim);
		viper::round_rect(win, CX + 12, y + 18, 64, LINE_H + 16, 8, th.widget_hot);
		const dots = (t * 3.0): int % 3;
		for (let d = 0; d <= dots; d += 1) {
			viper::circle(win, CX + 30 + d * 14, y + 18 + 17, 3, th.text);
		};
	};
};

// Drawn when no sprites have been added yet: a simple mammoth face.
fn draw_placeholder(
	win: *viper::window,
	x: int, y: int,
	mouth: bool, blink: bool, thinking: bool, bob: int,
) void = {
	const fur: viper::color = 0xff7a4b2c, dark: viper::color = 0xff4e2e1a;
	const cx = x + PORTRAIT / 2, cy = y + 140 + bob;
	// Ears.
	viper::circle(win, cx - 92, cy - 6, 52, dark);
	viper::circle(win, cx + 92, cy - 6, 52, dark);
	viper::circle(win, cx - 92, cy - 6, 44, fur);
	viper::circle(win, cx + 92, cy - 6, 44, fur);
	// Head and hair tuft.
	viper::circle(win, cx, cy - 10, 82, dark);
	viper::circle(win, cx, cy - 10, 78, fur);
	viper::circle(win, cx, cy - 86, 22, dark);
	viper::circle(win, cx - 18, cy - 80, 16, dark);
	// Trunk.
	for (let i = 0; i < 90; i += 1) {
		const w = 34 - i / 5;
		const sway = (i * i) / 300;
		viper::rect(win, cx - w / 2 + sway, cy + 20 + i, w, 2, fur);
	};
	// Tusks.
	for (let i = 0; i < 70; i += 1) {
		const curve = (i * i) / 120;
		viper::rect(win, cx - 50 - i / 3 + curve / 2, cy + 30 + i - curve, 9, 3, 0xfff2ead6);
		viper::rect(win, cx + 41 + i / 3 - curve / 2, cy + 30 + i - curve, 9, 3, 0xfff2ead6);
	};
	// Eyes.
	if (blink) {
		viper::rect(win, cx - 38, cy - 18, 20, 4, 0xff1a0f08);
		viper::rect(win, cx + 18, cy - 18, 20, 4, 0xff1a0f08);
	} else {
		viper::circle(win, cx - 28, cy - 18, 9, 0xfff6efe0);
		viper::circle(win, cx + 28, cy - 18, 9, 0xfff6efe0);
		const look = if (thinking) -4 else 0;
		viper::circle(win, cx - 28 + 2, cy - 18 + look, 5, 0xff1a0f08);
		viper::circle(win, cx + 28 + 2, cy - 18 + look, 5, 0xff1a0f08);
	};
	// Mouth beside the trunk.
	if (mouth) {
		viper::circle(win, cx + 30, cy + 34, 10, 0xff2a120a);
		viper::rect(win, cx + 24, cy + 36, 12, 4, 0xffc2575a);
	} else {
		viper::rect(win, cx + 22, cy + 32, 18, 3, 0xff2a120a);
	};
};

fn draw_portrait(
	win: *viper::window,
	sp: *sprites,
	talking: bool, thinking: bool, t: f64,
) void = {
	const x = 24, y = 48;
	// Snowy backdrop.
	for (let i = 0; i < PORTRAIT + 6; i += 1) {
		viper::rect(win, x, y + i, PORTRAIT + 6, 1,
			viper::mix(0xff2d4a66, 0xffb9d4e6, i: f64 / (PORTRAIT + 6): f64));
	};
	viper::outline(win, x, y, PORTRAIT + 6, PORTRAIT + 6, win.theme.border);

	const mouth = talking && (t * 9.0): int % 2 == 0;
	const blink = !talking && (t * 1000.0): int % 4200 < 140;
	const bob = if (talking || thinking) 0 else ((t * 2.0): int % 2);

	// Pick the best sprite for the moment, falling back to idle.
	let img = sp.idle;
	if (thinking && sp.think != null) img = sp.think;
	if (mouth && sp.talk != null) img = sp.talk;
	if (blink && !thinking && sp.blink != null) img = sp.blink;

	viper::clip(win, x + 1, y + 1, PORTRAIT + 4, PORTRAIT + 4);
	match (img) {
	case let i: *viper::image =>
		viper::draw_image(win, i, x + 3 + (PORTRAIT - i.w) / 2,
			y + 3 + (PORTRAIT - i.h) / 2 + bob);
	case null =>
		draw_placeholder(win, x + 3, y + 3, mouth, blink, thinking, bob);
	};
	viper::noclip(win);
};

export fn main() void = {
	const win = match (viper::open("Mastodon - ViperGui chat", W, H)) {
	case let w: *viper::window =>
		yield w;
	case let e: viper::error =>
		fmt::fatal("viper:", viper::strerror(e));
	case nomem =>
		fmt::fatal("viper: out of memory");
	};
	defer viper::close(win);
	win.theme = mammoth;

	const dir = os::tryenv("MASTODON_DIR", "assets/mastodon");
	let c = chat { persona = read_persona(dir), ... };
	let sp = sprites { ... };
	load_sheet(&c, dir, &sp);
	// Single files override frames from the sheet.
	override(&sp.idle, load_sprite(&c, dir, "idle.png"));
	override(&sp.talk, load_sprite(&c, dir, "talk.png"));
	override(&sp.think, load_sprite(&c, dir, "think.png"));
	override(&sp.blink, load_sprite(&c, dir, "blink.png"));
	add(&c, kind::MASTODON, GREETING);

	const apikey = find_apikey();
	if (apikey is void) {
		add(&c, kind::INFO, "Ingen API-nøgle. Sæt OPENROUTER_API_KEY, eller "
			"læg nøglen i ~/.config/vipergui/openrouter.key");
	};
	const model = os::tryenv("MASTODON_MODEL", DEFAULT_MODEL);

	let input = viper::textinput { focused = true, ... };
	let busy: (request | void) = void;
	let scroll = 0;
	let typewriter = true;
	let reveal_idx = 0z;
	let reveal = 0.0;
	let t = 0.0;
	let buf: [128]u8 = [0...];

	for (viper::frame(win)) {
		if (viper::key_pressed(win, viper::key::ESCAPE)) break;
		const dt = viper::delta(win);
		t += dt;

		// Finished thinking?
		match (busy) {
		case let r: request =>
			match (ai_poll(&r)) {
			case void => void;
			case let reply: str =>
				append(c.msgs, msg { kind = kind::MASTODON, text = clean(reply) })!;
				free(reply);
				reveal_idx = len(c.msgs) - 1;
				reveal = 0.0;
				scroll = 0;
				busy = void;
			case let e: apierr =>
				const m = fmt::asprintf("Fejl: {}", e: str)!;
				free(e: str);
				append(c.msgs, msg { kind = kind::INFO, text = m })!;
				busy = void;
			};
		case void => void;
		};

		// Typewriter progress.
		const total = viper::runes(c.msgs[reveal_idx].text);
		if (!typewriter) reveal = total: f64;
		if (reveal < total: f64) {
			reveal += dt * 55.0;
			// Clicking the chat shows the whole reply at once.
			const (mx, my) = viper::mouse(win);
			if (viper::mouse_pressed(win) && mx >= CX && mx < CX + CW
					&& my >= CY && my < CY + CH) {
				reveal = total: f64;
			};
		};
		const talking = reveal < total: f64;
		const thinking = busy is request;

		const th = &win.theme;
		viper::clear(win, th.bg);

		// Left: Mastodon.
		viper::panel(win, 12, 12, 330, 616, "MASTODON");
		draw_portrait(win, &sp, talking, thinking, t);
		viper::text_scaled(win, 24, 368, "Mastodon", th.accent, 3);
		const status = if (thinking) "Tænker..." else if (talking) "Snakker"
			else "Lytter";
		viper::circle(win, 30, 432, 5, if (thinking) 0xffd9a35f
			else if (talking) 0xff6fd08c else th.text_dim);
		viper::text(win, 42, 424, status, th.text);
		viper::text(win, 24, 452, fmt::bsprintf(buf, "Model: {}", model)!, th.text_dim);

		viper::checkbox(win, "Skrivemaskine-effekt", 24, 486, &typewriter);
		if (viper::button(win, "Ny samtale", 24, 520) && busy is void) {
			for (let m .. c.msgs) free(m.text);
			c.msgs = c.msgs[..0];
			add(&c, kind::MASTODON, GREETING);
			reveal_idx = 0;
			reveal = 0.0;
			scroll = 0;
		};
		viper::text(win, 24, 568, "Enter sender  ·  Esc lukker", th.text_dim);
		viper::text(win, 24, 588, "Scroll med musehjulet", th.text_dim);

		// Right: the conversation.
		viper::panel(win, 354, 12, 594, 616, "Chat");
		draw_chat(win, &c, &scroll, reveal_idx, reveal: int, thinking, t);
		viper::rect(win, 355, CY + CH + 4, 592, 1, th.border);

		// There is only one text field, so it always keeps the focus.
		input.focused = true;
		const send_key = viper::textbox(win, &input, CX, 576, 470,
			"Skriv til Mastodon...");
		const send_btn = viper::button(win, "Send", 860, 577);
		const text = strings::trim(viper::textinput_str(&input));
		if ((send_key || send_btn) && len(text) > 0 && busy is void) {
			add(&c, kind::USER, text);
			viper::textinput_clear(&input);
			scroll = 0;
			match (apikey) {
			case let k: str =>
				match (ai_start(&c, k)) {
				case let r: request =>
					busy = r;
				case let e: str =>
					const m = fmt::asprintf("Fejl: {}", e)!;
					defer free(m);
					add(&c, kind::INFO, m);
				};
			case void =>
				add(&c, kind::INFO, "Ingen API-nøgle: sæt OPENROUTER_API_KEY "
					"og start igen.");
			};
		};

		viper::present(win);
	};

	match (busy) {
	case let r: request => ai_cancel(&r);
	case void => void;
	};
};
