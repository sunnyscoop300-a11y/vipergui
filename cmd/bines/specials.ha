// BINES — power-ups: creating them from big matches, and setting them off.
//
//   match 4            -> Honningstribe (clears its line in that direction)
//   two lines crossing -> Honningbombe  (clears itself + 6 neighbours)
//   match 5+           -> Regnbueblomst (swap it: clears every piece of
//                                        the colour it is swapped with)
use math::random;

type beam = struct { x0: f64, y0: f64, x1: f64, y1: f64, life: f64 };
type ring = struct { x: f64, y: f64, life: f64 };

fn run_cell(rn: *run, i: int) (int, int) = {
	let (c, r) = (rn.c, rn.r);
	for (let k = 0; k < i; k += 1) {
		const (nc, nr) = step(c, r, axes[rn.axis].0, axes[rn.axis].1);
		c = nc; r = nr;
	};
	return (c, r);
};

fn in_run(rn: *run, c: int, r: int) bool = {
	for (let i = 0; i < rn.n; i += 1) {
		const (x, y) = run_cell(rn, i);
		if (x == c && y == r) return true;
	};
	return false;
};

// Where a new power-up from this run goes: the piece the player moved if
// it is part of the run, otherwise the middle of the run.
fn pick_cell(g: *game, rn: *run) ((int, int) | void) = {
	for (let p .. [g.swap_a, g.swap_b]) {
		if (g.from_swap && in_run(rn, p.0, p.1)
				&& g.b.c[p.0][p.1].special == special::NONE) {
			return p;
		};
	};
	const mid = run_cell(rn, rn.n / 2);
	if (g.b.c[mid.0][mid.1].special == special::NONE) return mid;
	for (let i = 0; i < rn.n; i += 1) {
		const p = run_cell(rn, i);
		if (g.b.c[p.0][p.1].special == special::NONE) return p;
	};
};

fn place(g: *game, p: (int, int), sp: special, label: str) void = {
	let c = &g.b.c[p.0][p.1];
	c.marked = false; // it stays on the board as the new power-up
	c.special = sp;
	if (sp == special::RAINBOW) c.kind = RAINBOW;
	const (x, y) = center(p.0, p.1);
	float_text(g, x, y - 26.0, label, 0xfffff4d0, 1);
	play_sfx(g, sfx::SPARKLE, 0.9, 1.0);
	burst(g, x, y, 0xfffff4d0);
};

// Turns big matches into power-ups (call right after find_matches).
fn create_specials(g: *game) void = {
	const b = &g.b;
	let used: [64]bool = [false...];
	// 5 or more in a row: rainbow flower.
	for (let i = 0z; i < b.nruns; i += 1) {
		if (b.runs[i].n < 5) continue;
		match (pick_cell(g, &b.runs[i])) {
		case let p: (int, int) =>
			place(g, p, special::RAINBOW, "Regnbueblomst!");
			used[i] = true;
		case void => void;
		};
	};
	// Two lines crossing: honey bomb at the crossing.
	for (let c = 0; c < COLS; c += 1) for (let r = 0; r < ROWS; r += 1) {
		const cl = &b.c[c][r];
		if (cl.hits < 2 || !cl.marked || cl.special != special::NONE) continue;
		let open_ = true;
		for (let i = 0z; i < b.nruns; i += 1) {
			if (used[i] && in_run(&b.runs[i], c, r)) open_ = false;
		};
		if (!open_) continue;
		for (let i = 0z; i < b.nruns; i += 1) {
			if (in_run(&b.runs[i], c, r)) used[i] = true;
		};
		place(g, (c, r), special::BOMB, "Honningbombe!");
	};
	// Exactly 4: a stripe along the match's own direction.
	for (let i = 0z; i < b.nruns; i += 1) {
		if (used[i] || b.runs[i].n != 4) continue;
		match (pick_cell(g, &b.runs[i])) {
		case let p: (int, int) =>
			const sp = (special::STRIPE0: u8 + b.runs[i].axis: u8): special;
			place(g, p, sp, "Honningstribe!");
		case void => void;
		};
	};
};

fn mark(b: *board, c: int, r: int) void = {
	if (inside(c, r)) b.c[c][r].marked = true;
};

// The most common colour on the board (for a rainbow set off by a blast).
fn common_kind(b: *board) u8 = {
	let n: [MAX_KINDS]int = [0...];
	for (let c = 0; c < COLS; c += 1) for (let r = 0; r < ROWS; r += 1) {
		const k = b.c[c][r].kind;
		if (k < MAX_KINDS && !b.c[c][r].marked) n[k] += 1;
	};
	let best = 0u8;
	for (let k = 1u8; k < MAX_KINDS; k += 1) if (n[k] > n[best]) best = k;
	return best;
};

fn mark_kind(b: *board, k: u8) void = {
	for (let c = 0; c < COLS; c += 1) for (let r = 0; r < ROWS; r += 1) {
		if (b.c[c][r].kind == k) b.c[c][r].marked = true;
	};
};

// Sets off every marked power-up; blasts can hit more power-ups, so keep
// going until nothing new goes off. Returns how many went off.
fn fire_specials(g: *game) int = {
	const b = &g.b;
	let fired = 0;
	for (true) {
		let any = false;
		for (let c = 0; c < COLS; c += 1) for (let r = 0; r < ROWS; r += 1) {
			let cl = &b.c[c][r];
			if (!cl.marked || cl.fired || cl.special == special::NONE) continue;
			cl.fired = true;
			any = true;
			fired += 1;
			const (x, y) = center(c, r);
			switch (cl.special) {
			case special::STRIPE0, special::STRIPE1, special::STRIPE2 =>
				const a = axes[(cl.special: u8 - special::STRIPE0: u8): size];
				let ends: [2](int, int) = [(c, r), (c, r)];
				for (let dir = 0z; dir < 2; dir += 1) {
					const sgn = if (dir == 0) 1 else -1;
					let (x, y) = (c, r);
					for (inside(x, y)) {
						mark(b, x, y);
						ends[dir] = (x, y);
						const (nx, ny) = step(x, y, a.0 * sgn, a.1 * sgn);
						x = nx; y = ny;
					};
				};
				const (x0, y0) = center(ends[0].0, ends[0].1);
				const (x1, y1) = center(ends[1].0, ends[1].1);
				add_beam(g, x0, y0, x1, y1);
				play_sfx(g, sfx::WHOOSH, 0.9, 1.0);
			case special::BOMB =>
				for (let d .. dirs) {
					const (nc, nr) = step(c, r, d.0, d.1);
					mark(b, nc, nr);
				};
				add_ring(g, x, y);
				play_sfx(g, sfx::BOOM, 1.0, 1.0);
			case special::RAINBOW =>
				mark_kind(b, common_kind(b));
				add_ring(g, x, y);
				play_sfx(g, sfx::RAINBOW, 1.0, 1.0);
			case special::NONE => void;
			};
		};
		if (!any) break;
	};
	return fired;
};

fn add_beam(g: *game, x0: f64, y0: f64, x1: f64, y1: f64) void = {
	g.beams[g.nbeam % len(g.beams)] = beam { x0 = x0, y0 = y0, x1 = x1, y1 = y1, life = 0.35 };
	g.nbeam += 1;
};

fn add_ring(g: *game, x: f64, y: f64) void = {
	g.rings[g.nring % len(g.rings)] = ring { x = x, y = y, life = 0.4 };
	g.nring += 1;
};

// Swapping a rainbow flower: clear every piece of the other colour (two
// rainbows clear the whole board).
fn rainbow_swap(g: *game) void = {
	const b = &g.b;
	for (let c = 0; c < COLS; c += 1) for (let r = 0; r < ROWS; r += 1) {
		b.c[c][r].marked = false;
		b.c[c][r].fired = false;
		b.c[c][r].hits = 0;
	};
	b.nruns = 0;
	const pa = &b.c[g.swap_a.0][g.swap_a.1], pb = &b.c[g.swap_b.0][g.swap_b.1];
	if (pa.kind == RAINBOW && pb.kind == RAINBOW) {
		for (let c = 0; c < COLS; c += 1) for (let r = 0; r < ROWS; r += 1) {
			b.c[c][r].marked = true;
		};
	} else {
		const other = if (pa.kind == RAINBOW) pb else pa;
		mark_kind(b, other.kind);
	};
	pa.marked = true;
	pb.marked = true;
	if (pa.kind == RAINBOW) pa.fired = true;
	if (pb.kind == RAINBOW) pb.fired = true;
	const (x, y) = center(g.swap_a.0, g.swap_a.1);
	announce(g, "Regnbue!", 0xffff9cf0);
	play_sfx(g, sfx::RAINBOW, 1.0, 1.0);
	add_ring(g, x, y);
};
