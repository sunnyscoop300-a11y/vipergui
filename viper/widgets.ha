// ViperGui — immediate-mode widgets.
//
// Widgets are plain function calls made every frame. There are no callbacks
// (Hare has no closures); a widget simply returns true when something
// happened, and stateful widgets take a pointer to your own variable.

use strings;

// Widgets are identified by where they are drawn.
fn widget_id(x: int, y: int) u64 = (x: u32: u64 << 32) | y: u32: u64;

fn inside(win: *window, x: int, y: int, w: int, h: int) bool =
	win.mouse_x >= x && win.mouse_x < x + w &&
	win.mouse_y >= y && win.mouse_y < y + h;

// Shared hover/press logic. Returns true when the widget was clicked.
fn interact(win: *window, id: u64, x: int, y: int, w: int, h: int) bool = {
	const over = inside(win, x, y, w, h);
	if (over) win.hot = id;
	if (over && win.mouse_pressed) win.active = id;
	return over && win.mouse_released && win.active == id;
};

// Draws text in the theme's text color.
export fn label(win: *window, x: int, y: int, s: str) void =
	text(win, x, y, s, win.theme.text);

// Draws a titled panel background.
export fn panel(win: *window, x: int, y: int, w: int, h: int, title: str) void = {
	const t = &win.theme;
	rect(win, x, y, w, h, t.panel);
	outline(win, x, y, w, h, t.border);
	if (len(title) > 0) {
		rect(win, x, y, w, 24, t.accent);
		text(win, x + 8, y + 4, title, t.panel);
	};
};

// A push button. Returns true on the frame it was clicked.
export fn button(win: *window, s: str, x: int, y: int) bool = {
	const w = text_width(s, 1) + 24, h = 28;
	const id = widget_id(x, y);
	const clicked = interact(win, id, x, y, w, h);
	const t = &win.theme;

	const pressed = win.active == id && win.mouse_down;
	const bg = if (pressed) t.accent_active
		else if (win.hot == id) t.accent_hot
		else t.accent;
	const off = if (pressed) 2 else 0;
	rect(win, x, y + 2, w, h - 2, t.accent_active); // little drop shadow
	rect(win, x, y + off, w, h - 2, bg);
	text(win, x + 12, y + 5 + off, s, t.panel);
	return clicked;
};

// A checkbox bound to `val`. Returns true when it was toggled.
export fn checkbox(win: *window, s: str, x: int, y: int, val: *bool) bool = {
	const box = 18;
	const w = box + 8 + text_width(s, 1);
	const id = widget_id(x, y);
	const clicked = interact(win, id, x, y, w, box);
	if (clicked) *val = !*val;
	const t = &win.theme;

	rect(win, x, y, box, box, if (win.hot == id) t.widget_hot else t.widget);
	outline(win, x, y, box, box, t.border);
	if (*val) {
		rect(win, x + 4, y + 4, box - 8, box - 8, t.accent);
	};
	text(win, x + box + 8, y + 1, s, t.text);
	return clicked;
};

// A horizontal slider bound to `val` (0.0 .. 1.0). Returns true while it
// is being changed.
export fn slider(win: *window, s: str, x: int, y: int, w: int, val: *f64) bool = {
	const t = &win.theme;
	text(win, x, y, s, t.text);

	const ty = y + 22, th = 14;
	const id = widget_id(x, ty);
	interact(win, id, x, ty, w, th);

	let changed = false;
	if (win.active == id && win.mouse_down) {
		let v = (win.mouse_x - x): f64 / w: f64;
		if (v < 0.0) v = 0.0;
		if (v > 1.0) v = 1.0;
		changed = v != *val;
		*val = v;
	};

	rect(win, x, ty + th / 2 - 3, w, 6, t.widget);
	const fill = (*val * w: f64): int;
	rect(win, x, ty + th / 2 - 3, fill, 6, t.accent);
	const knob = if (win.hot == id || win.active == id) t.accent_hot else t.accent;
	rect(win, x + fill - 5, ty, 10, th, knob);
	outline(win, x + fill - 5, ty, 10, th, t.accent_active);
	return changed;
};

// A progress bar (0.0 .. 1.0).
export fn progress(win: *window, x: int, y: int, w: int, val: f64) void = {
	const t = &win.theme;
	rect(win, x, y, w, 10, t.widget);
	rect(win, x, y, (val * w: f64): int, 10, t.accent);
	outline(win, x, y, w, 10, t.border);
};

// State for a [[textbox]]. Zero-initialize it: `let tb = viper::textinput { ... };`
export type textinput = struct {
	buf: [2048]u8,
	length: size,
	focused: bool,
};

// The current contents of a [[textinput]].
export fn textinput_str(tb: *textinput) str =
	strings::fromutf8_unsafe(tb.buf[..tb.length]);

// Empties a [[textinput]].
export fn textinput_clear(tb: *textinput) void = tb.length = 0;

// A single-line text field (UTF-8, so æøå work). Click to focus.
// Returns true on the frame Enter is pressed while it has focus.
export fn textbox(
	win: *window,
	tb: *textinput,
	x: int, y: int, w: int,
	placeholder: str,
) bool = {
	const h = 30;
	const id = widget_id(x, y);
	const over = inside(win, x, y, w, h);
	if (over) win.hot = id;
	if (win.mouse_pressed) tb.focused = over;

	let submit = false;
	if (tb.focused) {
		// Append typed text, but never split a multi-byte character.
		const t = strings::toutf8(typed(win));
		if (tb.length + len(t) <= len(tb.buf)) {
			tb.buf[tb.length..tb.length + len(t)] = t;
			tb.length += len(t);
		};
		if (key_typed(win, key::BACKSPACE) && tb.length > 0) {
			// Step back over UTF-8 continuation bytes (10xxxxxx).
			tb.length -= 1;
			for (tb.length > 0 && tb.buf[tb.length] & 0xc0 == 0x80) {
				tb.length -= 1;
			};
		};
		submit = key_pressed(win, key::RETURN)
			|| key_pressed(win, key::KP_ENTER);
	};

	const t = &win.theme;
	rect(win, x, y, w, h, if (win.hot == id || tb.focused) t.widget_hot else t.widget);
	outline(win, x, y, w, h, if (tb.focused) t.accent else t.border);

	const cols = (w - 16) / FONT_W;
	const s = textinput_str(tb);
	if (len(s) == 0 && !tb.focused) {
		text(win, x + 8, y + 7, placeholder, t.text_dim);
	} else {
		// Show the tail of the text when it is wider than the box.
		let shown = s;
		const n = runes(s);
		if (n > cols - 1) {
			let it = strings::iter(s);
			for (let i = 0; i < n - (cols - 1); i += 1) strings::next(&it);
			shown = strings::iterstr(&it);
		};
		text(win, x + 8, y + 7, shown, t.text);
		if (tb.focused && (win.frames / 30) % 2 == 0) {
			rect(win, x + 8 + text_width(shown, 1), y + 6, 2, 18, t.accent);
		};
	};
	return submit;
};
