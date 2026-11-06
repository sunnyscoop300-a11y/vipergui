// JADE — tests for the rules in game.ha.

@test fn start() void = {
	const s = new_state(1);
	assert(s.n == 3 && s.alive && s.level == 1);
	assert(s.body[0].0 == 3 && s.body[0].1 == 11);
	assert(s.grid[s.food.0][s.food.1] == cell::FLOOR);
};

@test fn moves_and_turns() void = {
	let s = new_state(2);
	s.food = (12, 0);
	step(&s);
	assert(s.body[0].0 == 4 && s.body[0].1 == 11);
	assert(s.body[2].0 == 2);
	// Turning straight back is ignored.
	turn(&s, dir::LEFT);
	assert(s.nq == 0);
	turn(&s, dir::UP);
	step(&s);
	assert(s.body[0].0 == 4 && s.body[0].1 == 10);
};

@test fn screen_steering() void = {
	let s = new_state(10);
	s.food = (12, 0);
	// Going RIGHT (down-right on screen): up turns her UP (up-right).
	assert(screen_turn(&s, arrow::N));
	assert(heading(&s) == dir::UP);
	// Already going up: up again does nothing.
	assert(!screen_turn(&s, arrow::N));
	// Left now: from UP that is LEFT (up-left).
	assert(screen_turn(&s, arrow::W));
	assert(heading(&s) == dir::LEFT);
	let s = new_state(11);
	assert(side_turn(&s, true) && heading(&s) == dir::DOWN);
};

@test fn food_never_behind_pillars() void = {
	for (let i = 0u64; i < 50; i += 1) {
		let s = new_state(100 + i);
		s.level = 2;
		start_garden(&s);
		assert(!behind_pillar(&s, s.food.0, s.food.1));
	};
};

@test fn eats_and_grows() void = {
	let s = new_state(3);
	s.food = (4, 11);
	assert(step(&s) == event::EAT);
	assert(s.eaten == 1 && s.score == 10 && s.grow == 1);
	step(&s);
	assert(s.n == 4);
};

@test fn walls_and_pillars() void = {
	let s = new_state(4);
	s.food = (0, 0);
	s.grid[4][11] = cell::PILLAR;
	assert(step(&s) == event::DIE);
	assert(!s.alive);
	let s = new_state(5);
	s.food = (0, 0);
	s.d = dir::DOWN;
	step(&s);
	assert(step(&s) == event::DIE);   // off the bottom edge
};

@test fn bites_herself() void = {
	let s = new_state(6);
	s.food = (0, 0);
	s.n = 5;
	s.body[..5] = [(5, 5), (6, 5), (6, 6), (5, 6), (4, 6)];
	s.d = dir::LEFT;
	turn(&s, dir::DOWN);
	assert(step(&s) == event::DIE);
};

@test fn clears_a_garden() void = {
	let s = new_state(7);
	s.eaten = GOAL - 1;
	s.food = (4, 11);
	assert(step(&s) == event::CLEAR);
	next_garden(&s);
	assert(s.level == 2 && s.eaten == 0 && s.n == 3);
};

@test fn autopilot_survives() void = {
	let s = new_state(8);
	let eaten = 0, deaths = 0;
	for (let i = 0; i < 3000; i += 1) {
		autopilot(&s);
		switch (step(&s)) {
		case event::EAT => eaten += 1;
		case event::CLEAR => next_garden(&s);
		case event::DIE =>
			deaths += 1;
			s = new_state(9 + i: u64);
		case => void;
		};
	};
	assert(eaten > 20);
};
