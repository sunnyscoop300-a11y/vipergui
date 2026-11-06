// BINES — the honeycomb board: hex geometry, matching, gravity and refill.
//
// The board is a grid of flat-topped hexagons in columns; odd columns sit
// half a cell lower ("odd-q" layout). For neighbours and straight lines we
// convert to axial coordinates, where the three line directions are simple.
use math;
use math::random;

def COLS: int = 9;
def ROWS: int = 8;
def R: f64 = 29.0;                 // hexagon radius (center to corner)
def BX: f64 = 36.0;                // board position on screen
def BY: f64 = 84.0;
def EMPTY: u8 = 255;
def RAINBOW: u8 = 100;             // the rainbow flower has no colour
def MAX_KINDS: u8 = 7;

// The basic pieces, in the order of the concept sheet (and pieces.png).
type piece = enum u8 { HONEY, FLOWER, LEAF, BERRY, CRYSTAL, WAX, POLLEN };

// Power-ups. A stripe clears its whole line in one of the three hex
// directions; a bomb clears itself and its six neighbours.
type special = enum u8 { NONE, STRIPE0, STRIPE1, STRIPE2, BOMB, RAINBOW };

// A matched line: start cell, axis index (into axes) and length.
type run = struct {
	c: int,
	r: int,
	axis: int,
	n: int,
};

type cell = struct {
	kind: u8,
	// Animation: drawn at (center + offset). Swaps ease the offset to 0;
	// falling pieces accelerate down to it.
	sx: f64,
	sy: f64,
	oy: f64,
	vy: f64,
	marked: bool,
	special: special,
	fired: bool,     // special already went off this turn
	hits: u8,        // how many matched lines cover this cell
};

type board = struct {
	c: [COLS][ROWS]cell,
	kinds: u8,
	rng: random::random,
	runs: [64]run,
	nruns: size,
};

fn hex_h() f64 = math::sqrtf64(3.0) * R;

// Screen position of a cell's center.
fn center(c: int, r: int) (f64, f64) = {
	const h = hex_h();
	const x = BX + R + c: f64 * 1.5 * R;
	const y = BY + h / 2.0 + r: f64 * h + (if (c & 1 == 1) h / 2.0 else 0.0);
	return (x, y);
};

fn inside(c: int, r: int) bool = c >= 0 && c < COLS && r >= 0 && r < ROWS;

// Offset (column, row) <-> axial (q, r).
fn axial(c: int, r: int) (int, int) = (c, r - (c - (c & 1)) / 2);
fn from_axial(q: int, a: int) (int, int) = (q, a + (q - (q & 1)) / 2);

fn step(c: int, r: int, dq: int, dr: int) (int, int) = {
	const (q, a) = axial(c, r);
	return from_axial(q + dq, a + dr);
};

// The six neighbour directions in axial coordinates.
const dirs: [6](int, int) = [(0, 1), (0, -1), (1, 0), (-1, 0), (1, -1), (-1, 1)];
// The three line directions (each with its opposite in dirs).
const axes: [3](int, int) = [(0, 1), (1, 0), (1, -1)];

fn neighbours(c1: int, r1: int, c2: int, r2: int) bool = {
	for (let d .. dirs) {
		const (c, r) = step(c1, r1, d.0, d.1);
		if (c == c2 && r == r2) return true;
	};
	return false;
};

// The rainbow flower never matches by colour, so it reads as EMPTY here.
fn kind_at(b: *board, c: int, r: int) u8 = {
	if (!inside(c, r)) return EMPTY;
	const k = b.c[c][r].kind;
	return if (k == RAINBOW) EMPTY else k;
};

// Length of the run of same pieces through (c, r) along axis (dq, dr).
fn run_len(b: *board, c: int, r: int, dq: int, dr: int) int = {
	const k = kind_at(b, c, r);
	if (k == EMPTY) return 0;
	let n = 1;
	let (x, y) = step(c, r, dq, dr);
	for (kind_at(b, x, y) == k) {
		n += 1;
		const (nx, ny) = step(x, y, dq, dr);
		x = nx; y = ny;
	};
	let (x, y) = step(c, r, -dq, -dr);
	for (kind_at(b, x, y) == k) {
		n += 1;
		const (nx, ny) = step(x, y, -dq, -dr);
		x = nx; y = ny;
	};
	return n;
};

// Would the piece at (c, r) be part of a match?
fn match_at(b: *board, c: int, r: int) bool = {
	for (let a .. axes) {
		if (run_len(b, c, r, a.0, a.1) >= 3) return true;
	};
	return false;
};

// Marks every piece that is part of a line of 3+. Returns how many pieces
// were marked and the longest line found.
fn find_matches(b: *board) (int, int) = {
	for (let c = 0; c < COLS; c += 1) for (let r = 0; r < ROWS; r += 1) {
		b.c[c][r].marked = false;
		b.c[c][r].fired = false;
		b.c[c][r].hits = 0;
	};
	b.nruns = 0;
	let longest = 0;
	for (let c = 0; c < COLS; c += 1) for (let r = 0; r < ROWS; r += 1) {
		const k = kind_at(b, c, r);
		if (k == EMPTY) continue;
		for (let ai = 0z; ai < len(axes); ai += 1) {
			const a = axes[ai];
			// Only count from the start of each run.
			const (pc, pr) = step(c, r, -a.0, -a.1);
			if (kind_at(b, pc, pr) == k) continue;
			let n = 0;
			let (x, y) = (c, r);
			for (kind_at(b, x, y) == k) {
				n += 1;
				const (nx, ny) = step(x, y, a.0, a.1);
				x = nx; y = ny;
			};
			if (n < 3) continue;
			if (n > longest) longest = n;
			if (b.nruns < len(b.runs)) {
				b.runs[b.nruns] = run { c = c, r = r, axis = ai: int, n = n };
				b.nruns += 1;
			};
			let (x, y) = (c, r);
			for (let i = 0; i < n; i += 1) {
				b.c[x][y].marked = true;
				b.c[x][y].hits += 1;
				const (nx, ny) = step(x, y, a.0, a.1);
				x = nx; y = ny;
			};
		};
	};
	let count = 0;
	for (let c = 0; c < COLS; c += 1) for (let r = 0; r < ROWS; r += 1) {
		if (b.c[c][r].marked) count += 1;
	};
	return (count, longest);
};

// Swaps two pieces, including any power-up they carry.
fn swap_kinds(b: *board, c1: int, r1: int, c2: int, r2: int) void = {
	const k = b.c[c1][r1].kind, s = b.c[c1][r1].special;
	b.c[c1][r1].kind = b.c[c2][r2].kind;
	b.c[c1][r1].special = b.c[c2][r2].special;
	b.c[c2][r2].kind = k;
	b.c[c2][r2].special = s;
};

// Finds a swap that makes a match, if there is one.
fn find_move(b: *board) ((int, int, int, int) | void) = {
	for (let c = 0; c < COLS; c += 1) for (let r = 0; r < ROWS; r += 1) {
		// The three axis directions reach every neighbour pair once.
		for (let d .. axes) {
			const (c2, r2) = step(c, r, d.0, d.1);
			if (!inside(c2, r2)) continue;
			// A rainbow flower can always be swapped with a neighbour.
			if (b.c[c][r].kind == RAINBOW || b.c[c2][r2].kind == RAINBOW) {
				return (c, r, c2, r2);
			};
			swap_kinds(b, c, r, c2, r2);
			const ok = match_at(b, c, r) || match_at(b, c2, r2);
			swap_kinds(b, c, r, c2, r2);
			if (ok) return (c, r, c2, r2);
		};
	};
};

fn random_kind(b: *board) u8 = random::u32n(&b.rng, b.kinds: u32): u8;

// Fills the whole board with no ready-made matches and at least one move.
// Pieces start above the board and drop in.
fn fill(b: *board) void = {
	for (true) {
		// Start from an empty board; otherwise leftover pieces (or the
		// zero value, which is HONEY) would count toward "matches".
		for (let c = 0; c < COLS; c += 1) for (let r = 0; r < ROWS; r += 1) {
			b.c[c][r].kind = EMPTY;
		};
		for (let c = 0; c < COLS; c += 1) for (let r = 0; r < ROWS; r += 1) {
			let tries = 0;
			for (true) {
				b.c[c][r].kind = random_kind(b);
				tries += 1;
				if (!match_at(b, c, r) || tries > 20) break;
			};
		};
		if (find_move(b) is (int, int, int, int)) break;
	};
	for (let c = 0; c < COLS; c += 1) for (let r = 0; r < ROWS; r += 1) {
		let p = &b.c[c][r];
		p.sx = 0.0; p.sy = 0.0; p.vy = 0.0; p.marked = false;
		p.special = special::NONE;
		p.oy = -(ROWS: f64 + 1.0) * hex_h() - c: f64 * 18.0;
	};
};

// Removes marked pieces, lets the rest fall, and drops in new ones.
fn collapse(b: *board) void = {
	const h = hex_h();
	for (let c = 0; c < COLS; c += 1) {
		let w = ROWS - 1;
		for (let r = ROWS - 1; r >= 0; r -= 1) {
			if (b.c[c][r].marked) continue;
			if (w != r) {
				b.c[c][w] = b.c[c][r];
				b.c[c][w].oy -= (w - r): f64 * h;
			};
			w -= 1;
		};
		// New pieces stack up above the board.
		const missing = w + 1;
		for (let r = w; r >= 0; r -= 1) {
			b.c[c][r] = cell {
				kind = random_kind(b),
				oy = -(missing: f64) * h - 12.0,
				...
			};
		};
	};
	for (let c = 0; c < COLS; c += 1) for (let r = 0; r < ROWS; r += 1) {
		b.c[c][r].marked = false;
	};
};

// Moves falling pieces. Returns true once everything has landed.
fn settle(b: *board, dt: f64) bool = {
	let landed = true;
	for (let c = 0; c < COLS; c += 1) for (let r = 0; r < ROWS; r += 1) {
		let p = &b.c[c][r];
		if (p.oy < 0.0) {
			p.vy += 2600.0 * dt;
			p.oy += p.vy * dt;
			if (p.oy >= 0.0) {
				p.oy = 0.0;
				p.vy = 0.0;
			} else {
				landed = false;
			};
		};
	};
	return landed;
};

// The cell under a screen position, if any.
fn cell_at(x: int, y: int) ((int, int) | void) = {
	let best = (-1, -1), bestd = R * R * 0.85;
	for (let c = 0; c < COLS; c += 1) for (let r = 0; r < ROWS; r += 1) {
		const (cx, cy) = center(c, r);
		const dx = x: f64 - cx, dy = y: f64 - cy;
		const d = dx * dx + dy * dy;
		if (d < bestd) {
			bestd = d;
			best = (c, r);
		};
	};
	if (best.0 < 0) return;
	return best;
};
