// Tests for the Wayland backend's event handling: we feed it the exact bytes
// a compositor would send and check the resulting window state.
use endian;
use net;

fn testwin() (*window, *wl_backend) = {
	let be = alloc(wl_backend {
		sock = 0: net::socket,
		next_id = 2,
		width = 100,
		height = 100,
		pointer = 10,
		keyboard = 11,
		repeat_rate = 25,
		repeat_delay = 600,
		...
	})!;
	let win = alloc(window {
		be = be,
		width = 100,
		height = 100,
		pixels = [],
		theme = jade,
		...
	})!;
	return (win, be);
};

// Builds one wire message and runs it through the dispatcher.
fn feed(win: *window, be: *wl_backend, obj: u32, op: u16, words: u32...) void = {
	const sz = 8 + len(words) * 4;
	let buf: [64]u8 = [0...];
	endian::leputu32(buf[0..4], obj);
	endian::leputu32(buf[4..8], (sz: u32 << 16) | op);
	for (let i = 0z; i < len(words); i += 1) {
		endian::leputu32(buf[8 + i * 4..12 + i * 4], words[i]);
	};
	be.inbuf[be.inlen..be.inlen + sz] = buf[..sz];
	be.inlen += sz;
	dispatch(win, be);
};

fn fixed(v: int) u32 = (v * 256): i32: u32;

@test fn pointer() void = {
	const (win, be) = testwin();
	defer { free(be); free(win); };
	feed(win, be, 10, 2, 0, fixed(42), fixed(17)); // motion
	assert(win.mouse_x == 42 && win.mouse_y == 17);
	feed(win, be, 10, 3, 1, 0, 0x110, 1); // left button down
	latch_input(win);
	assert(win.mouse_pressed && win.mouse_down);
	feed(win, be, 10, 3, 2, 0, 0x110, 0); // up
	latch_input(win);
	assert(win.mouse_released && !win.mouse_down && !win.mouse_pressed);
	feed(win, be, 10, 3, 3, 0, 0x111, 1); // right button: ignored
	assert(!win.mouse_down);
	// Wheel: one click down via axis_discrete, its smooth axis is skipped.
	feed(win, be, 10, 8, 0, 1);
	feed(win, be, 10, 4, 0, 0, fixed(10));
	feed(win, be, 10, 5);
	latch_input(win);
	assert(win.wheel == -1);
	// Touchpad-style smooth scroll up by 20 units = 2 steps.
	feed(win, be, 10, 4, 0, 0, fixed(-20));
	latch_input(win);
	assert(win.wheel == 2);
};

@test fn keys_and_text() void = {
	const (win, be) = testwin();
	defer { free(be); free(win); };
	// Arrow up (evdev 103) -> HID UP, pressed and held.
	feed(win, be, 11, 3, 1, 0, 103, 1);
	latch_input(win);
	assert(key_pressed(win, key::UP) && key_down(win, key::UP));
	feed(win, be, 11, 3, 2, 0, 103, 0);
	latch_input(win);
	assert(!key_down(win, key::UP) && !key_pressed(win, key::UP));

	// "hej" then shift+ø, then AltGr+2 (@), Caps Lock + å.
	feed(win, be, 11, 3, 3, 0, 35, 1); // h
	feed(win, be, 11, 3, 4, 0, 18, 1); // e
	feed(win, be, 11, 3, 5, 0, 36, 1); // j
	feed(win, be, 11, 4, 6, 1, 0, 0, 0); // shift held
	feed(win, be, 11, 3, 7, 0, 40, 1); // Ø
	feed(win, be, 11, 4, 8, 0x80, 0, 0, 0); // AltGr held
	feed(win, be, 11, 3, 9, 0, 3, 1); // @
	feed(win, be, 11, 4, 10, 0, 0, 2, 0); // Caps Lock on
	feed(win, be, 11, 3, 11, 0, 26, 1); // Å
	feed(win, be, 11, 3, 12, 0, 51, 1); // , (caps doesn't affect)
	latch_input(win);
	assert(typed(win) == "hejØ@Å,");

	// Ctrl+C types nothing; Escape types nothing.
	feed(win, be, 11, 4, 13, 4, 0, 0, 0);
	feed(win, be, 11, 3, 14, 0, 46, 1);
	feed(win, be, 11, 4, 15, 0, 0, 0, 0);
	feed(win, be, 11, 3, 16, 0, 1, 1);
	latch_input(win);
	assert(typed(win) == "");
	assert(key_pressed(win, key::ESCAPE));
};

@test fn key_events_in_order() void = {
	const (win, be) = testwin();
	defer { free(be); free(win); };
	feed(win, be, 11, 3, 1, 0, 30, 1);  // a down
	feed(win, be, 11, 3, 2, 0, 30, 0);  // a up
	feed(win, be, 11, 3, 3, 0, 103, 1); // up arrow down
	feed(win, be, 11, 3, 4, 0, 30, 1);  // a again, same frame
	latch_input(win);
	const ev = key_events(win);
	assert(len(ev) == 4);
	assert(ev[0].hid == key::A && ev[0].down && ev[0].text == 'a');
	assert(ev[1].hid == key::A && !ev[1].down);
	assert(ev[2].hid == key::UP && ev[2].down && ev[2].text == '\0');
	assert(ev[3].hid == key::A && ev[3].down && ev[3].text == 'a');
	latch_input(win);
	assert(len(key_events(win)) == 0);
};

@test fn split_messages() void = {
	// A message that arrives in two reads must still be handled once.
	const (win, be) = testwin();
	defer { free(be); free(win); };
	let buf: [20]u8 = [0...];
	endian::leputu32(buf[0..4], 10);
	endian::leputu32(buf[4..8], (20u32 << 16) | 2);
	endian::leputu32(buf[12..16], fixed(5));
	endian::leputu32(buf[16..20], fixed(6));
	be.inbuf[..11] = buf[..11];
	be.inlen = 11;
	dispatch(win, be);
	assert(win.mouse_x == 0 && be.inlen == 11);
	be.inbuf[11..20] = buf[11..20];
	be.inlen = 20;
	dispatch(win, be);
	assert(win.mouse_x == 5 && win.mouse_y == 6 && be.inlen == 0);
};

@test fn click_during_present() void = {
	// The bug from Weston/pixman: a click read while present() waits for a
	// buffer must still reach the app on the next frame, not be wiped.
	const (win, be) = testwin();
	defer { free(be); free(win); };
	latch_input(win);                       // frame N starts
	feed(win, be, 10, 3, 1, 0, 0x110, 1);   // ...read during present()
	feed(win, be, 10, 3, 2, 0, 0x110, 0);
	assert(!win.mouse_pressed);             // not visible mid-frame
	latch_input(win);                       // frame N+1 starts
	assert(win.mouse_pressed && win.mouse_released);
	latch_input(win);                       // and only once
	assert(!win.mouse_pressed);
};
