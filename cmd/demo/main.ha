// ViperGui 0.3.0 demo: widgets on the left, a tiny real-time game on the
// right ("Viper vs. Dumplings"). Arrows move, Space pauses, R restarts.
use fmt;
use math::random;
use viper;

def COLS: int = 26;
def ROWS: int = 22;
def CELL: int = 20;
def GRID_X: int = 264;
def GRID_Y: int = 40;
def MAX_LEN: size = 26 * 22;

type point = struct { x: int, y: int };

type game = struct {
	body: [MAX_LEN]point,
	length: size,
	dir: point,
	next_dir: point,
	food: point,
	score: int,
	best: int,
	over: bool,
	paused: bool,
	started: bool,
	timer: f64,
	rng: random::random,
};

fn reset(g: *game) void = {
	g.length = 4;
	for (let i = 0z; i < g.length; i += 1) {
		g.body[i] = point { x = COLS / 2 - i: int, y = ROWS / 2 };
	};
	g.dir = point { x = 1, y = 0 };
	g.next_dir = g.dir;
	g.score = 0;
	g.over = false;
	g.paused = false;
	g.started = false;
	g.timer = 0.0;
	place_food(g);
};

fn on_body(g: *game, p: point, upto: size) bool = {
	for (let i = 0z; i < upto; i += 1) {
		if (g.body[i].x == p.x && g.body[i].y == p.y) return true;
	};
	return false;
};

fn place_food(g: *game) void = {
	for (true) {
		const p = point {
			x = random::u32n(&g.rng, COLS: u32): int,
			y = random::u32n(&g.rng, ROWS: u32): int,
		};
		if (!on_body(g, p, g.length)) {
			g.food = p;
			return;
		};
	};
};

fn step(g: *game) void = {
	g.dir = g.next_dir;
	const head = point { x = g.body[0].x + g.dir.x, y = g.body[0].y + g.dir.y };
	const grow = head.x == g.food.x && head.y == g.food.y;

	// The tail moves away this step unless we grow, so it doesn't count.
	const check = if (grow) g.length else g.length - 1;
	if (head.x < 0 || head.y < 0 || head.x >= COLS || head.y >= ROWS
			|| on_body(g, head, check)) {
		g.over = true;
		if (g.score > g.best) g.best = g.score;
		return;
	};

	for (let i = g.length; i > 0; i -= 1) {
		g.body[i] = g.body[i - 1];
	};
	g.body[0] = head;
	if (grow) {
		g.length += 1;
		g.score += 1;
		if (g.length < MAX_LEN) place_food(g);
	};
};

fn steer(win: *viper::window, g: *game) void = {
	const want = if (viper::key_pressed(win, viper::key::UP)) point { x = 0, y = -1 }
		else if (viper::key_pressed(win, viper::key::DOWN)) point { x = 0, y = 1 }
		else if (viper::key_pressed(win, viper::key::LEFT)) point { x = -1, y = 0 }
		else if (viper::key_pressed(win, viper::key::RIGHT)) point { x = 1, y = 0 }
		else return;
	// No turning straight back into yourself.
	g.started = true;
	if (want.x == -g.dir.x && want.y == -g.dir.y) return;
	g.next_dir = want;
};

fn draw_game(win: *viper::window, g: *game, grid: bool) void = {
	const t = &win.theme;
	const field = viper::mix(t.panel, t.bg, 0.5);
	viper::rect(win, GRID_X, GRID_Y, COLS * CELL, ROWS * CELL, field);

	if (grid) {
		const gc = viper::mix(field, t.border, 0.25);
		for (let c = 1; c < COLS; c += 1) {
			viper::rect(win, GRID_X + c * CELL, GRID_Y, 1, ROWS * CELL, gc);
		};
		for (let r = 1; r < ROWS; r += 1) {
			viper::rect(win, GRID_X, GRID_Y + r * CELL, COLS * CELL, 1, gc);
		};
	};

	// Dumpling: a soft bun with little pleats on top.
	const fx = GRID_X + g.food.x * CELL + CELL / 2;
	const fy = GRID_Y + g.food.y * CELL + CELL / 2;
	viper::circle(win, fx, fy + 1, 8, 0xffcfa66a);
	viper::circle(win, fx, fy, 7, 0xfff4e2bd);
	viper::line(win, fx - 3, fy - 4, fx, fy - 1, 0xffcfa66a);
	viper::line(win, fx + 3, fy - 4, fx, fy - 1, 0xffcfa66a);

	// Viper: green body fading toward the tail, with a yellow belly stripe.
	for (let i = g.length; i > 0; i -= 1) {
		const seg = g.body[i - 1];
		const fade = (i - 1): f64 / g.length: f64;
		const body = viper::mix(0xff3f9a4f, 0xff7cc46a, fade);
		const x = GRID_X + seg.x * CELL, y = GRID_Y + seg.y * CELL;
		viper::rect(win, x + 2, y + 2, CELL - 4, CELL - 4, body);
		viper::rect(win, x + 7, y + 7, CELL - 14, CELL - 14, 0xffe8d26a);
	};

	// Head with eyes and a red flower (Viper's trademark).
	const h = g.body[0];
	const hx = GRID_X + h.x * CELL, hy = GRID_Y + h.y * CELL;
	viper::rect(win, hx + 1, hy + 1, CELL - 2, CELL - 2, 0xff2f7f3d);
	const ex = hx + CELL / 2 + g.dir.x * 4, ey = hy + CELL / 2 + g.dir.y * 4;
	const px = if (g.dir.x == 0) 4 else 0, py = if (g.dir.y == 0) 4 else 0;
	viper::rect(win, ex - px - 1, ey - py - 1, 3, 3, 0xff101010);
	viper::rect(win, ex + px - 1, ey + py - 1, 3, 3, 0xff101010);
	viper::circle(win, hx + 4, hy + 4, 3, 0xffd94040);

	if (g.over || g.paused || !g.started) {
		const msg = if (g.over) "GAME OVER" else if (g.paused) "PAUSED" else "READY?";
		const w = viper::text_width(msg, 3);
		const cx = GRID_X + (COLS * CELL - w) / 2;
		const cy = GRID_Y + ROWS * CELL / 2 - 40;
		viper::rect(win, cx - 16, cy - 12, w + 32, 72 + 24, t.panel);
		viper::outline(win, cx - 16, cy - 12, w + 32, 72 + 24, t.border);
		viper::text_scaled(win, cx, cy, msg, t.accent, 3);
		const hint = if (g.over) "Press R to try again"
			else if (g.paused) "Press Space" else "Press an arrow key";
		viper::text(win, GRID_X + (COLS * CELL - viper::text_width(hint, 1)) / 2,
			cy + 58, hint, t.text_dim);
	};
};

export fn main() void = {
	const win = match (viper::open("ViperGui 0.3.0 demo", 800, 500)) {
	case let w: *viper::window =>
		yield w;
	case let e: viper::error =>
		fmt::fatal("viper: could not open window:", viper::strerror(e));
	case nomem =>
		fmt::fatal("viper: out of memory");
	};
	defer viper::close(win);

	let g = game { rng = random::init(viper::ticks(): u64 + 1), ... };
	reset(&g);

	let strikes = 0;
	let night_mode = false;
	let show_grid = true;
	let speed = 0.35;
	let buf: [64]u8 = [0...];

	for (viper::frame(win)) {
		if (viper::key_pressed(win, viper::key::ESCAPE)) break;
		if (viper::key_pressed(win, viper::key::R)) reset(&g);
		if (viper::key_pressed(win, viper::key::SPACE) && !g.over) {
			g.paused = !g.paused;
		};

		// Game update: fixed steps, rate set by the speed slider.
		steer(win, &g);
		if (g.started && !g.over && !g.paused) {
			g.timer += viper::delta(win);
			const interval = 1.0 / (4.0 + speed * 16.0);
			for (g.timer >= interval && !g.over) {
				g.timer -= interval;
				step(&g);
			};
		};

		const t = &win.theme;
		viper::clear(win, t.bg);

		// Left: widget panel.
		viper::panel(win, 12, 12, 236, 476, "ViperGui 0.3.0");
		viper::text_scaled(win, 28, 48, "Viper", t.accent, 3);
		viper::text(win, 28, 98, "Simple. Fast. Flexible.", t.text_dim);

		if (viper::button(win, "Strike!", 28, 128)) strikes += 1;
		viper::label(win, 130, 134, fmt::bsprintf(buf, "x {}", strikes)!);

		if (viper::checkbox(win, "Night theme", 28, 176, &night_mode)) {
			win.theme = if (night_mode) viper::night else viper::jade;
		};
		viper::checkbox(win, "Show grid", 28, 204, &show_grid);

		viper::slider(win, fmt::bsprintf(buf, "Speed: {}", 4 + (speed * 16.0): int)!,
			28, 236, 200, &speed);

		viper::label(win, 28, 290, fmt::bsprintf(buf, "Score: {}   Best: {}",
			g.score, g.best)!);
		viper::text(win, 28, 312, "Next level", t.text_dim);
		viper::progress(win, 120, 315, 108, (g.score % 5): f64 / 5.0);

		if (viper::button(win, "New game", 28, 340)) reset(&g);

		viper::text(win, 28, 392, "Arrows  move", t.text_dim);
		viper::text(win, 28, 410, "Space   pause", t.text_dim);
		viper::text(win, 28, 428, "R       restart", t.text_dim);
		viper::text(win, 28, 446, "Esc     quit", t.text_dim);
		const (mx, my) = viper::mouse(win);
		viper::text(win, 28, 466, fmt::bsprintf(buf, "mouse {},{}", mx, my)!,
			viper::mix(t.text_dim, t.panel, 0.4));

		// Right: the game.
		viper::panel(win, 260, 12, 528, 476, "Viper vs. Dumplings");
		draw_game(win, &g, show_grid);

		viper::present(win);
	};
};
