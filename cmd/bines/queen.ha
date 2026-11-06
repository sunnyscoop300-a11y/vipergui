// BINES — Queen Evalin. She steps onto the honey shelf to talk to the
// player: she introduces each level, praises a full jar and hands out her
// scepter. Her messages queue up and are shown one at a time; a click on
// her (or her speech bubble) skips to the next.
use strings;
use viper;

def QUEEN_CELL: int = 132;
def QUEEN_X: f64 = 96.0;       // where she stands on the shelf
def QUEEN_TIME: f64 = 4.0;     // seconds per message
def QUEEN_SLIDE: f64 = 0.35;   // walking on and off

type qline = struct {
	text: [2][48]u8,
	n: [2]size,
};

type queen = struct {
	queue: [4]qline,
	nq: size,
	t: f64,
};

// Queues a message of one or two lines (each up to 48 bytes).
fn queen_say(g: *game, l1: str, l2: str) void = {
	let q = &g.queen;
	if (q.nq >= len(q.queue)) return;
	let m = &q.queue[q.nq];
	for (let i = 0z; i < 2; i += 1) {
		const b = strings::toutf8(if (i == 0) l1 else l2);
		const n = if (len(b) > len(m.text[i])) len(m.text[i]) else len(b);
		m.text[i][..n] = b[..n];
		m.n[i] = n;
	};
	if (q.nq == 0) q.t = 0.0;
	q.nq += 1;
};

fn queen_clear(g: *game) void = {
	g.queen.nq = 0;
	g.queen.t = 0.0;
};

fn queen_next(q: *queen) void = {
	for (let i = 1z; i < q.nq; i += 1) q.queue[i - 1] = q.queue[i];
	if (q.nq > 0) q.nq -= 1;
	q.t = 0.0;
};

fn queen_update(win: *viper::window, g: *game, dt: f64) void = {
	let q = &g.queen;
	if (q.nq == 0) return;
	q.t += dt;
	// The thief has the shelf: she steps off while he is there.
	if (g.thief.phase != tphase::OFF && g.thief.phase != tphase::FLEE
			&& q.t < QUEEN_TIME - QUEEN_SLIDE) {
		q.t = QUEEN_TIME - QUEEN_SLIDE;
	};
	// A click on her or her bubble skips ahead.
	const (mx, my) = viper::mouse(win);
	if (viper::mouse_pressed(win) && mx < 494 && my > (SHELF_Y: int - 130)
			&& q.t > QUEEN_SLIDE && q.t < QUEEN_TIME - QUEEN_SLIDE) {
		q.t = QUEEN_TIME - QUEEN_SLIDE;
	};
	if (q.t >= QUEEN_TIME) queen_next(q);
};

fn draw_queen(win: *viper::window, g: *game, s: *strip) void = {
	const q = &g.queen;
	if (q.nq == 0) return;
	// Slide on from the left, and off again at the end.
	let e = 1.0;
	if (q.t < QUEEN_SLIDE) e = q.t / QUEEN_SLIDE;
	if (q.t > QUEEN_TIME - QUEEN_SLIDE) e = (QUEEN_TIME - q.t) / QUEEN_SLIDE;
	if (e < 0.0) e = 0.0;
	e = 1.0 - (1.0 - e) * (1.0 - e);
	const x = QUEEN_X - (1.0 - e) * 220.0;
	const talking = q.t > QUEEN_SLIDE && q.t < QUEEN_TIME - QUEEN_SLIDE - 0.4;

	let head = SHELF_Y - 120.0;
	match (strip_frame(s, true, if (talking) q.t else 0.0, 6.0, false)) {
	case let fr: *viper::image =>
		const top = SHELF_Y + 6.0 - s.foot: f64;
		viper::draw_image(win, fr, x: int - fr.w / 2, top: int);
		head = top + s.top: f64;
	case null =>
		// No sprite: a little crowned bee.
		draw_bee(win, x, SHELF_Y - 30.0, 24.0);
		viper::rect(win, x: int - 12, (SHELF_Y - 64.0): int, 24, 8, 0xffffc23a);
		head = SHELF_Y - 90.0;
	};

	// The speech bubble, once she has arrived.
	if (e < 0.98) return;
	const m = &q.queue[0];
	const l1 = strings::fromutf8_unsafe(m.text[0][..m.n[0]]);
	const l2 = strings::fromutf8_unsafe(m.text[1][..m.n[1]]);
	const w1 = viper::text_width(l1, 1), w2 = viper::text_width(l2, 1);
	const w = (if (w1 > w2) w1 else w2) + 24;
	const lines = if (m.n[1] > 0) 2 else 1;
	const h = lines * 18 + 14;
	const bx = (x + 66.0): int;
	const by = (head: int + 14);
	const tail: [3](f64, f64) = [(bx: f64 + 2.0, by: f64 + 14.0),
		(bx: f64 + 2.0, by: f64 + 30.0), (bx: f64 - 14.0, by: f64 + 26.0)];
	viper::round_rect(win, bx - 2, by - 2, w + 4, h + 4, 10, 0xff6b2a8a);
	viper::polygon(win, tail, 0xff6b2a8a);
	viper::round_rect(win, bx, by, w, h, 8, 0xfffff8e8);
	viper::text(win, bx + 12, by + 7, l1, 0xff4a1a5a);
	if (lines == 2) viper::text(win, bx + 12, by + 25, l2, 0xff2a1604);
};
