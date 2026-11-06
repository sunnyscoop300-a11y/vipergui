// Tests for Bines' rules: power-ups, chain reactions and the honey thief.
use math::random;

// A board with no matches anywhere: kind = (2q + 3r) mod 7 in axial
// coordinates gives every neighbour along every axis a different kind.
fn test_game() *game = {
	let g = alloc(game { ... })!;
	g.b.rng = random::init(42);
	g.b.kinds = 7;
	g.sel = NONE;
	g.drag = NONE;
	thief_reset(&g.thief);
	for (let c = 0; c < COLS; c += 1) for (let r = 0; r < ROWS; r += 1) {
		const (q, a) = axial(c, r);
		const k = ((2 * q + 3 * a) % 7 + 7) % 7;
		g.b.c[c][r] = cell { kind = k: u8, ... };
	};
	return g;
};

// Puts kind k on n cells starting at (c, r) along axis ai.
fn line_of(g: *game, c: int, r: int, ai: size, n: int, k: u8) void = {
	let (x, y) = (c, r);
	for (let i = 0; i < n; i += 1) {
		g.b.c[x][y].kind = k;
		const (nx, ny) = step(x, y, axes[ai].0, axes[ai].1);
		x = nx; y = ny;
	};
};

fn count_marked(g: *game) int = {
	let n = 0;
	for (let c = 0; c < COLS; c += 1) for (let r = 0; r < ROWS; r += 1) {
		if (g.b.c[c][r].marked) n += 1;
	};
	return n;
};

@test fn base_board_has_no_matches() void = {
	const g = test_game();
	defer free(g);
	const (n, _) = find_matches(&g.b);
	assert(n == 0);
};

@test fn four_makes_a_stripe() void = {
	const g = test_game();
	defer free(g);
	// Four honey drops down column 4 (axis 0 = vertical).
	line_of(g, 4, 2, 0, 4, piece::HONEY);
	const (n, longest) = find_matches(&g.b);
	assert(n == 4 && longest == 4);
	create_specials(g);
	// The middle cell (index 2 -> row 4) becomes a vertical stripe and stays.
	assert(g.b.c[4][4].special == special::STRIPE0);
	assert(!g.b.c[4][4].marked);
	assert(count_marked(g) == 3);
};

@test fn swapped_piece_gets_the_power_up() void = {
	const g = test_game();
	defer free(g);
	line_of(g, 4, 2, 0, 4, piece::HONEY);
	find_matches(&g.b);
	g.from_swap = true;
	g.swap_a = (4, 2);
	g.swap_b = (3, 2);
	create_specials(g);
	assert(g.b.c[4][2].special == special::STRIPE0);
};

@test fn five_makes_a_rainbow() void = {
	const g = test_game();
	defer free(g);
	line_of(g, 4, 1, 0, 5, piece::BERRY);
	const (_, longest) = find_matches(&g.b);
	assert(longest == 5);
	create_specials(g);
	assert(g.b.c[4][3].kind == RAINBOW);
	assert(g.b.c[4][3].special == special::RAINBOW);
	assert(count_marked(g) == 4);
};

@test fn crossing_lines_make_a_bomb() void = {
	const g = test_game();
	defer free(g);
	// A vertical and a diagonal line of leaves sharing the cell (4, 4).
	line_of(g, 4, 3, 0, 3, piece::LEAF);  // (4,3) (4,4) (4,5)
	const (c0, r0) = step(4, 4, -axes[1].0, -axes[1].1);
	line_of(g, c0, r0, 1, 3, piece::LEAF); // ... through (4,4)
	const (n, _) = find_matches(&g.b);
	assert(n == 5);
	assert(g.b.c[4][4].hits == 2);
	create_specials(g);
	assert(g.b.c[4][4].special == special::BOMB);
	assert(g.b.c[4][4].kind == piece::LEAF);
	assert(count_marked(g) == 4);
};

@test fn stripe_clears_its_line() void = {
	const g = test_game();
	defer free(g);
	// A vertical stripe in column 2 goes off: the whole column clears.
	g.b.c[2][5].special = special::STRIPE0;
	g.b.c[2][5].marked = true;
	const fired = fire_specials(g);
	assert(fired == 1);
	for (let r = 0; r < ROWS; r += 1) assert(g.b.c[2][r].marked);
	assert(count_marked(g) == ROWS);
};

@test fn chain_reaction() void = {
	const g = test_game();
	defer free(g);
	// A stripe in column 2 hits a bomb in the same column.
	g.b.c[2][1].special = special::STRIPE0;
	g.b.c[2][1].marked = true;
	g.b.c[2][6].special = special::BOMB;
	const fired = fire_specials(g);
	assert(fired == 2);
	// The bomb's neighbours outside the column were cleared too.
	const (nc, nr) = step(2, 6, 1, 0);
	assert(g.b.c[nc][nr].marked);
	assert(count_marked(g) == ROWS + 4); // column + 4 side neighbours
};

@test fn rainbow_swap_clears_a_colour() void = {
	const g = test_game();
	defer free(g);
	g.b.c[3][3].kind = RAINBOW;
	g.b.c[3][3].special = special::RAINBOW;
	const (c2, r2) = step(3, 3, 0, 1);
	const k = g.b.c[c2][r2].kind;
	let total = 0;
	for (let c = 0; c < COLS; c += 1) for (let r = 0; r < ROWS; r += 1) {
		if (g.b.c[c][r].kind == k) total += 1;
	};
	g.swap_a = (3, 3);
	g.swap_b = (c2, r2);
	rainbow_swap(g);
	fire_specials(g);
	assert(count_marked(g) == total + 1); // every piece of k + the flower
};

@test fn thief_arrives_and_escapes() void = {
	const g = test_game();
	defer free(g);
	g.goal = 300.0;
	g.level = 1;
	g.meter = 50.0;
	g.score = 1000;
	for (let i = 0; i < FIRST_THIEF; i += 1) {
		g.moves += 1;
		thief_on_move(g);
	};
	assert(g.thief.phase == tphase::ENTER);
	assert(g.thief.goal == 125.0); // 50 + 25 % of 300
	g.thief.phase = tphase::WAIT;  // he has walked in
	for (let i = 0; i < THIEF_STAY; i += 1) {
		g.moves += 1;
		thief_on_move(g);
	};
	assert(g.thief.phase == tphase::ESCAPE);
	assert(g.score == 700 && g.meter == 0.0);
	assert(g.thief.next == g.moves + THIEF_EVERY);
};

@test fn thief_chased_off() void = {
	const g = test_game();
	defer free(g);
	g.goal = 300.0;
	g.level = 1;
	g.moves = FIRST_THIEF;
	thief_on_move(g);
	g.thief.phase = tphase::WAIT;
	g.meter = g.thief.goal; // 75
	thief_on_honey(g);
	assert(g.thief.phase == tphase::FLEE);
	assert(g.score == 500);
	assert(g.meter == 90.0); // he drops 5 % of the goal
};

@test fn thief_cannot_be_chased_while_walking_in() void = {
	const g = test_game();
	defer free(g);
	g.goal = 300.0;
	g.moves = FIRST_THIEF;
	thief_on_move(g);
	g.meter = 300.0;
	thief_on_honey(g);
	assert(g.thief.phase == tphase::ENTER);
};

@test fn level_complete_and_game_over() void = {
	const g = test_game();
	defer free(g);
	g.saved_best = 1 << 30; // don't write a high score file in tests
	g.goal = 300.0;
	g.meter = 300.0;
	g.moves_left = 4;
	g.score = 1000;
	assert(check_level_end(g));
	assert(g.scr == screen::LEVEL_DONE);
	assert(g.bonus == 400 && g.score == 1400);

	g.scr = screen::PLAY;
	g.meter = 120.0;
	g.moves_left = 3;
	assert(!check_level_end(g)); // still moves left: keep playing
	g.moves_left = 0;
	assert(check_level_end(g));
	assert(g.scr == screen::GAME_OVER);
};

@test fn levels_get_harder() void = {
	assert(kinds_for(1) == 5 && kinds_for(3) == 6 && kinds_for(5) == 7);
	assert(level_moves(1) == 20 && level_moves(5) == 24);
	assert(level_goal(1) == 300.0 && level_goal(7) == 250.0);
	assert(world_name(1) == "Det Lille Bistade");
	assert(world_name(9) == "Dronningens Honningpalads");
};
