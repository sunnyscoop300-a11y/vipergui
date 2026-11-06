// JADE — the rules: a 13 x 13 temple garden, the snake, peaches, golden
// dumplings and the five gardens. Nothing here draws anything.
use math::random;
use strings;

def NS: size = 13;
def N: int = 13;
def MAXLEN: size = 169;
def GOAL: int = 10;           // peaches per garden
def GOLD_EVERY: int = 4;      // a golden dumpling after this many peaches
def GOLD_TIME: f64 = 7.0;     // seconds before it's gone

// The four ways the snake can go, named after where they point on screen.
// Grid x grows toward the lower right, grid y toward the lower left.
type dir = enum { UP, RIGHT, DOWN, LEFT };   // -y, +x, +y, -x

fn dvec(d: dir) (int, int) = switch (d) {
case dir::UP => yield (0, -1);
case dir::RIGHT => yield (1, 0);
case dir::DOWN => yield (0, 1);
case dir::LEFT => yield (-1, 0);
};

fn reverse(a: dir, b: dir) bool = (a: int + 2) % 4 == b: int;

// UP, RIGHT, DOWN, LEFT go clockwise round the screen.
fn right_of(d: dir) dir = ((d: int + 1) % 4): dir;
fn left_of(d: dir) dir = ((d: int + 3) % 4): dir;

// The arrow keys, as directions on the screen.
type arrow = enum { N, E, S, W };

// Does grid direction d move the snake partly toward arrow a on screen?
// (UP goes up-right, RIGHT down-right, DOWN down-left, LEFT up-left.)
fn leans(d: dir, a: arrow) bool = switch (a) {
case arrow::N => yield d == dir::UP || d == dir::LEFT;
case arrow::E => yield d == dir::UP || d == dir::RIGHT;
case arrow::S => yield d == dir::RIGHT || d == dir::DOWN;
case arrow::W => yield d == dir::DOWN || d == dir::LEFT;
};

// The direction she is about to go: the last queued turn, or her heading.
fn heading(s: *state) dir = if (s.nq > 0) s.queue[s.nq - 1] else s.d;

// Screen steering: an arrow key turns her toward that side of the screen.
// If she is already going that way, nothing happens.
fn screen_turn(s: *state, a: arrow) bool = {
	const cur = heading(s);
	if (leans(cur, a)) return false;
	const r = right_of(cur);
	const before = s.nq;
	turn(s, if (leans(r, a)) r else left_of(cur));
	return s.nq != before;
};

// Turn steering: left and right, as seen from the snake.
fn side_turn(s: *state, right: bool) bool = {
	const cur = heading(s);
	const before = s.nq;
	turn(s, if (right) right_of(cur) else left_of(cur));
	return s.nq != before;
};

type cell = enum u8 { FLOOR, PILLAR, WATER };

type event = enum { NONE, EAT, GOLD, DIE, CLEAR };

type state = struct {
	grid: [NS][NS]cell,
	body: [MAXLEN](int, int),  // body[0] is the head
	prev: [MAXLEN](int, int),  // where each part was before the last step
	n: size,
	grow: int,
	d: dir,
	queue: [2]dir,             // turns waiting for the next steps
	nq: size,
	food: (int, int),
	gold: (int, int),
	gold_t: f64,               // > 0 while a dumpling is out
	eaten: int,                // peaches in this garden
	score: int,
	level: int,
	alive: bool,
	rng: random::random,
};

type garden = struct {
	name: str,
	map: [NS]str,
};

// '#' a red pillar, '~' the lotus pond, '.' grass and stone.
// Row 11, where the snake starts, is kept clear.
const GARDENS: [5]garden = [
	garden { name = "Tempelhaven", map = [
		".............",
		".............",
		".............",
		"...#.....#...",
		".............",
		".............",
		"......#......",
		".............",
		".............",
		"...#.....#...",
		".............",
		".............",
		".............",
	] },
	garden { name = "Bambuslunden", map = [
		".............",
		".............",
		"..##.....##..",
		"..#.......#..",
		".............",
		".....#.#.....",
		".............",
		".....#.#.....",
		".............",
		"..#.......#..",
		"..##.....##..",
		".............",
		".............",
	] },
	garden { name = "Lotusdammen", map = [
		".............",
		".............",
		".............",
		"...#.....#...",
		".....~~~.....",
		"....~~~~~....",
		"....~~~~~....",
		".....~~~.....",
		".............",
		"...#.....#...",
		".............",
		".............",
		".............",
	] },
	garden { name = "Jadepaladset", map = [
		".............",
		".............",
		"..####.####..",
		".............",
		".............",
		"..#.......#..",
		"..#...#...#..",
		"..#.......#..",
		".............",
		".............",
		"..####.####..",
		".............",
		".............",
	] },
	garden { name = "Dragens Port", map = [
		".............",
		".#.........#.",
		".............",
		"...~~...~~...",
		"...~~...~~...",
		".............",
		"......#......",
		".............",
		"...~~...~~...",
		"...~~...~~...",
		".............",
		".............",
		".#.........#.",
	] },
];

fn garden_of(level: int) *garden = &GARDENS[((level - 1) % len(GARDENS): int): size];

fn new_state(seed: u64) state = {
	let s = state { rng = random::init(seed), level = 1, ... };
	start_garden(&s);
	return s;
};

// Lays out the current garden and puts the snake at the start.
fn start_garden(s: *state) void = {
	const g = garden_of(s.level);
	for (let y = 0z; y < NS; y += 1) {
		const row = strings::toutf8(g.map[y]);
		for (let x = 0z; x < NS; x += 1) {
			s.grid[x][y] = switch (row[x]) {
			case '#' => yield cell::PILLAR;
			case '~' => yield cell::WATER;
			case => yield cell::FLOOR;
			};
		};
	};
	s.n = 3;
	for (let i = 0z; i < s.n; i += 1) {
		s.body[i] = (3 - i: int, 11);
		s.prev[i] = (2 - i: int, 11);
	};
	s.d = dir::RIGHT;
	s.nq = 0;
	s.grow = 0;
	s.eaten = 0;
	s.gold_t = 0.0;
	s.alive = true;
	place_food(s);
};

fn inside(x: int, y: int) bool = x >= 0 && y >= 0 && x < N && y < N;

// True if the snake (or something else) is in the way at (x, y). The tail
// end doesn't count when it's about to move on.
fn blocked(s: *state, x: int, y: int, tail_moves: bool) bool = {
	if (!inside(x, y) || s.grid[x][y] != cell::FLOOR) return true;
	const n = if (tail_moves && s.grow == 0) s.n - 1 else s.n;
	for (let i = 0z; i < n; i += 1) {
		if (s.body[i].0 == x && s.body[i].1 == y) return true;
	};
	return false;
};

fn free_cell(s: *state) ((int, int) | void) = {
	for (let tries = 0; tries < 500; tries += 1) {
		const x = random::u32n(&s.rng, N: u32): int;
		const y = random::u32n(&s.rng, N: u32): int;
		if (blocked(s, x, y, false)) continue;
		if (s.food.0 == x && s.food.1 == y) continue;
		if (s.gold_t > 0.0 && s.gold.0 == x && s.gold.1 == y) continue;
		// Not hidden behind a pillar.
		if (behind_pillar(s, x, y)) continue;
		// Not right in front of her nose.
		const (hx, hy) = s.body[0];
		if ((hx - x) * (hx - x) + (hy - y) * (hy - y) < 4) continue;
		return (x, y);
	};
};

// A pillar stands in front of (x, y) on screen.
fn behind_pillar(s: *state, x: int, y: int) bool = {
	const near: [3](int, int) = [(1, 0), (0, 1), (1, 1)];
	for (let d .. near) {
		const px = x + d.0, py = y + d.1;
		if (inside(px, py) && s.grid[px][py] == cell::PILLAR) return true;
	};
	return false;
};

fn place_food(s: *state) void = {
	s.food = (-10, -10);
	match (free_cell(s)) {
	case let p: (int, int) => s.food = p;
	case void => void;
	};
};

// Queues a turn. Turning back on herself, or the same way again, is ignored.
fn turn(s: *state, d: dir) void = {
	const last = if (s.nq > 0) s.queue[s.nq - 1] else s.d;
	if (d == last || reverse(d, last)) return;
	if (s.nq < len(s.queue)) {
		s.queue[s.nq] = d;
		s.nq += 1;
	};
};

// Seconds between steps: faster in later gardens and as she eats.
fn step_time(s: *state) f64 = {
	let t = 0.165 - 0.012 * (s.level - 1): f64 - 0.003 * s.eaten: f64;
	return if (t < 0.075) 0.075 else t;
};

fn tick_gold(s: *state, dt: f64) void = {
	if (s.gold_t > 0.0) {
		s.gold_t -= dt;
		if (s.gold_t < 0.0) s.gold_t = 0.0;
	};
};

// Moves the snake one cell.
fn step(s: *state) event = {
	if (!s.alive) return event::NONE;
	if (s.nq > 0) {
		s.d = s.queue[0];
		s.queue[0] = s.queue[1];
		s.nq -= 1;
	};
	const (dx, dy) = dvec(s.d);
	const (hx, hy) = s.body[0];
	const nx = hx + dx, ny = hy + dy;
	if (blocked(s, nx, ny, true)) {
		s.alive = false;
		return event::DIE;
	};
	s.prev[..s.n] = s.body[..s.n];
	if (s.grow > 0 && s.n < MAXLEN) {
		s.prev[s.n] = s.body[s.n - 1];
		s.n += 1;
		s.grow -= 1;
	};
	for (let i = s.n - 1; i > 0; i -= 1) s.body[i] = s.body[i - 1];
	s.body[0] = (nx, ny);

	if (nx == s.food.0 && ny == s.food.1) {
		s.grow += 1;
		s.eaten += 1;
		s.score += 10 * s.level;
		if (s.eaten >= GOAL) return event::CLEAR;
		place_food(s);
		if (s.eaten % GOLD_EVERY == 0 && s.gold_t <= 0.0) {
			match (free_cell(s)) {
			case let p: (int, int) =>
				s.gold = p;
				s.gold_t = GOLD_TIME;
			case void => void;
			};
		};
		return event::EAT;
	};
	if (s.gold_t > 0.0 && nx == s.gold.0 && ny == s.gold.1) {
		s.gold_t = 0.0;
		s.grow += 2;
		s.score += 50 * s.level;
		return event::GOLD;
	};
	return event::NONE;
};

fn next_garden(s: *state) void = {
	s.level += 1;
	start_garden(s);
};

// ---- Autopilot, for the menu: the shortest way to the peach, or else the
// move with the most room. ----

fn autopilot(s: *state) void = {
	const (hx, hy) = s.body[0];
	let dist: [NS][NS]int = [[-1...]...];
	let first: [NS][NS]u8 = [[0...]...];
	let qx: [MAXLEN]int = [0...], qy: [MAXLEN]int = [0...];
	let head = 0z, tail = 0z;
	for (let d = 0u8; d < 4; d += 1) {
		if (reverse(d: dir, s.d)) continue;
		const (dx, dy) = dvec(d: dir);
		const x = hx + dx, y = hy + dy;
		if (blocked(s, x, y, true) || dist[x][y] >= 0) continue;
		dist[x][y] = 1;
		first[x][y] = d;
		qx[tail] = x;
		qy[tail] = y;
		tail += 1;
	};
	for (head < tail) {
		const x = qx[head], y = qy[head];
		head += 1;
		if (x == s.food.0 && y == s.food.1) {
			turn(s, first[x][y]: dir);
			return;
		};
		for (let d = 0u8; d < 4; d += 1) {
			const (dx, dy) = dvec(d: dir);
			const x2 = x + dx, y2 = y + dy;
			if (blocked(s, x2, y2, true) || dist[x2][y2] >= 0) continue;
			dist[x2][y2] = dist[x][y] + 1;
			first[x2][y2] = first[x][y];
			if (tail < len(qx)) {
				qx[tail] = x2;
				qy[tail] = y2;
				tail += 1;
			};
		};
	};
	// No way to the peach: go where there is the most room.
	let best = -1, bestd = s.d;
	for (let d = 0u8; d < 4; d += 1) {
		if (reverse(d: dir, s.d)) continue;
		const (dx, dy) = dvec(d: dir);
		const x = hx + dx, y = hy + dy;
		if (blocked(s, x, y, true)) continue;
		const room = flood(s, x, y);
		if (room > best) {
			best = room;
			bestd = d: dir;
		};
	};
	turn(s, bestd);
};

fn flood(s: *state, sx: int, sy: int) int = {
	let seen: [NS][NS]bool = [[false...]...];
	let qx: [MAXLEN]int = [0...], qy: [MAXLEN]int = [0...];
	let head = 0z, tail = 1z;
	qx[0] = sx;
	qy[0] = sy;
	seen[sx][sy] = true;
	for (head < tail) {
		const x = qx[head], y = qy[head];
		head += 1;
		for (let d = 0u8; d < 4; d += 1) {
			const (dx, dy) = dvec(d: dir);
			const x2 = x + dx, y2 = y + dy;
			if (blocked(s, x2, y2, true) || seen[x2][y2]) continue;
			seen[x2][y2] = true;
			if (tail < len(qx)) {
				qx[tail] = x2;
				qy[tail] = y2;
				tail += 1;
			};
		};
	};
	return tail: int;
};
