// BINES — Honningtyven, the honey thief. He walks in on the honey shelf
// under the board, steals from the honey meter every time you make a move,
// and runs off when you fill the meter up to his mark. If you run out of
// moves first, he escapes with the honey.
use math;
use strings;
use viper;

def SHELF_Y: f64 = 626.0;      // where his feet touch the shelf
def THIEF_STAY: int = 6;        // moves you get to chase him off
def THIEF_GOAL: f64 = 0.25;     // add this share of the level goal to scare him
def FIRST_THIEF: int = 6;       // he shows up this many moves into a level...
def THIEF_EVERY: int = 10;      // ...and again this many moves later

// Honey he steals per move: a share of the level's goal that grows with
// the level, so he gets greedier deeper into the hive.
fn steal_amount(g: *game) f64 =
	g.goal * (0.03 + 0.006 * (if (g.level > 8) 7 else g.level - 1): f64);

type tphase = enum { OFF, ENTER, WAIT, STEAL, ANGRY, FLEE, ESCAPE };

type thief = struct {
	phase: tphase,
	x: f64,
	t: f64,         // time in the current phase
	anim: f64,      // running clock for walk cycles
	moves_left: int,
	goal: f64,      // honey meter value that scares him away
	sack: f64,      // how much honey he holds (sack size)
	next: int,      // move count at which he shows up next
	bubble: str,
	bubble_t: f64,
};

fn thief_reset(th: *thief) void = {
	*th = thief { phase = tphase::OFF, next = FIRST_THIEF, ... };
};

fn thief_active(th: *thief) bool =
	th.phase == tphase::ENTER || th.phase == tphase::WAIT
	|| th.phase == tphase::STEAL || th.phase == tphase::ANGRY;

fn say(th: *thief, text: str) void = {
	th.bubble = text;
	th.bubble_t = 2.2;
};

// Called after every move the player makes.
fn thief_on_move(g: *game) void = {
	let th = &g.thief;
	if (th.phase == tphase::OFF && g.moves >= th.next) {
		th.phase = tphase::ENTER;
		th.x = 545.0; // just behind the panel's edge; he walks out from it
		th.t = 0.0;
		th.moves_left = THIEF_STAY;
		th.goal = g.meter + g.goal * THIEF_GOAL;
		if (th.goal > g.goal) th.goal = g.goal;
		th.sack = 0.3;
		announce(g, "Honningtyven!", 0xffff5a5a);
		play_sfx(g, sfx::THIEF_IN, 1.0, 1.0);
		return;
	};
	if (th.phase != tphase::WAIT && th.phase != tphase::STEAL) return;
	th.moves_left -= 1;
	g.meter -= steal_amount(g);
	if (g.meter < 0.0) g.meter = 0.0;
	th.sack += 0.12;
	th.phase = tphase::STEAL;
	th.t = 0.0;
	play_sfx(g, sfx::STEAL, 0.8, 1.0);
	if (th.moves_left <= 0) {
		// He gets away with the honey.
		th.phase = tphase::ESCAPE;
		th.t = 0.0;
		say(th, "Hehehe... farvel!");
		const loss = if (g.score > 300) 300 else g.score;
		g.score -= loss;
		// He runs off with a big scoop of the level's honey.
		g.meter -= g.goal * 0.2;
		if (g.meter < 0.0) g.meter = 0.0;
		announce(g, "Han slap væk! -300", 0xffff7a2a);
		play_sfx(g, sfx::ESCAPE, 1.0, 1.0);
		th.next = g.moves + THIEF_EVERY;
	};
};

// Called whenever honey is added; a big combo makes him angry, and
// reaching his goal chases him off.
fn thief_on_honey(g: *game) void = {
	let th = &g.thief;
	// He can only be chased off once he has arrived on the shelf.
	if (!thief_active(th) || th.phase == tphase::ENTER) return;
	if (g.meter >= th.goal) {
		th.phase = tphase::FLEE;
		th.t = 0.0;
		say(th, "Aaargh! Bierne!");
		g.score += 500;
		if (g.score > g.best) g.best = g.score;
		// He drops a little honey as he flees.
		g.meter += g.goal * 0.05;
		if (g.meter > g.goal) g.meter = g.goal;
		announce(g, "Tyven flygtede! +500", 0xff7ee07e);
		earn(g, THIEF_COINS);
		queen_say(g, "Flot! Han flygtede.", "+5 guldhonning til dig!");
		play_sfx(g, sfx::FLEE, 1.0, 1.0);
		th.next = g.moves + THIEF_EVERY;
	} else if (g.combo >= 3 && th.phase != tphase::ENTER) {
		th.phase = tphase::ANGRY;
		th.t = 0.0;
		say(th, "Hey! Lad være!");
		play_sfx(g, sfx::BONK, 0.7, 0.8);
	};
};

fn thief_update(g: *game, dt: f64) void = {
	let th = &g.thief;
	th.t += dt;
	th.anim += dt;
	if (th.bubble_t > 0.0) th.bubble_t -= dt;
	switch (th.phase) {
	case tphase::ENTER =>
		th.x -= 170.0 * dt;
		if (th.x <= 330.0) {
			th.x = 330.0;
			th.phase = tphase::WAIT;
			th.anim = 0.0;
			say(th, "Den honning er MIN!");
		};
	case tphase::STEAL =>
		if (th.t > STEAL_TIME) th.phase = tphase::WAIT;
	case tphase::ANGRY =>
		if (th.t > 0.6) th.phase = tphase::WAIT;
	case tphase::FLEE =>
		th.x += 420.0 * dt; // runs off to the right, scared
		if (th.x > 560.0) th.phase = tphase::OFF;
	case tphase::ESCAPE =>
		th.x -= 300.0 * dt; // sneaks off to the left with the honey
		if (th.x < -80.0) th.phase = tphase::OFF;
	case tphase::WAIT, tphase::OFF => void;
	};
};

// ---- Sprites ----
//
// assets/bines/thief_<anim>.png, square cells side by side, facing right
// (see anim.ha): walk, steal, talk, plus the optional idle, angry and
// flee. Any that is missing falls back to walk, and without walk the thief
// is drawn from shapes.

def THIEF_CELL: int = 132;     // sprite cell size on screen
def STEAL_TIME: f64 = 1.2;

type thief_sprites = struct {
	walk: strip,
	idle: strip,
	steal: strip,
	angry: strip,
	flee: strip,
	talk: strip,
};

fn load_thief_sprites() thief_sprites = thief_sprites {
	walk = load_strip("thief_walk", THIEF_CELL, true),
	idle = load_strip("thief_idle", THIEF_CELL, true),
	steal = load_strip("thief_steal", THIEF_CELL, true),
	angry = load_strip("thief_angry", THIEF_CELL, true),
	flee = load_strip("thief_flee", THIEF_CELL, true),
	talk = load_strip("thief_talk", THIEF_CELL, true),
};

// The strip if it was loaded, otherwise the fallback.
fn pick(s: *strip, fallback: *strip) *strip =
	if (len(s.right) > 0) s else fallback;

// Draws the thief from sprites. Returns false if there are no sprites.
fn draw_thief_sprite(win: *viper::window, g: *game, ts: *thief_sprites) bool = {
	const th = &g.thief;
	if (len(ts.walk.right) == 0) return false;
	// He enters walking left, waits facing left, and flees to the right.
	const right = th.phase == tphase::FLEE;
	let img: nullable *viper::image = null;
	let used = &ts.walk;
	let x = th.x, bob = 0.0;
	let jar = false, shout = false;
	switch (th.phase) {
	case tphase::ENTER =>
		used = &ts.walk;
		img = strip_frame(used, right, th.anim, 12.0, false);
	case tphase::WAIT =>
		if (th.bubble_t > 0.0 && len(ts.talk.right) > 0) {
			// Talking while his speech bubble is up.
			used = &ts.talk;
			img = strip_frame(used, right, th.anim, 6.5, false);
		} else if (len(ts.idle.right) > 0) {
			used = &ts.idle;
			img = strip_frame(used, right, th.anim, 3.0, false);
		} else if (len(ts.talk.right) > 0) {
			// The talk strip's first frame is a calm pose.
			used = &ts.talk;
			img = strip_frame(used, right, 0.0, 1.0, false);
			bob = math::sinf64(th.anim * 3.0) * 1.5;
		} else {
			img = strip_frame(used, right, 0.0, 1.0, false);
			bob = math::sinf64(th.anim * 3.0) * 1.5;
		};
	case tphase::STEAL =>
		if (len(ts.steal.right) > 0) {
			used = &ts.steal;
			img = strip_frame(used, right, th.t,
				len(used.right): f64 / STEAL_TIME, true);
		} else {
			img = strip_frame(used, right, 0.0, 1.0, false);
			jar = true;
		};
	case tphase::ANGRY =>
		if (len(ts.angry.right) > 0) {
			used = &ts.angry;
			img = strip_frame(used, right, th.t,
				len(used.right): f64 / 0.6, true);
		} else {
			used = pick(&ts.talk, &ts.walk);
			img = strip_frame(used, right, 0.0, 1.0, false);
			x += math::sinf64(th.t * 60.0) * 3.0;
			shout = true;
		};
	case tphase::FLEE =>
		used = pick(&ts.flee, &ts.walk);
		img = strip_frame(used, true, th.anim, 20.0, false);
	case tphase::ESCAPE =>
		// Sneaking off to the left with the honey.
		used = pick(&ts.flee, &ts.walk);
		img = strip_frame(used, false, th.anim, 16.0, false);
	case tphase::OFF => void;
	};
	const fr = match (img) {
	case let f: *viper::image => yield f;
	case null => return true;
	};
	const top = SHELF_Y + 6.0 - used.foot: f64 + bob;
	viper::draw_image(win, fr, x: int - fr.w / 2, top: int);
	const head = top + used.top: f64;
	if (jar && th.t < 0.6) {
		const jx = x - 34.0, jy = head + 40.0 - th.t * 10.0;
		viper::round_rect(win, (jx - 7.0): int, (jy - 8.0): int, 14, 14, 3, 0xffe0951e);
		viper::rect(win, (jx - 8.0): int, (jy - 10.0): int, 16, 4, 0xff8a5212);
	};
	if (shout) {
		viper::text_scaled(win, x: int - 4, head: int - 30, "!", 0xffff3a3a, 2);
	};
	draw_bubble(win, th, x, head);
	return true;
};

fn draw_bubble(win: *viper::window, th: *thief, x: f64, top: f64) void = {
	if (th.bubble_t <= 0.0) return;
	const w = viper::text_width(th.bubble, 1) + 16;
	let bx = x: int - w / 2;
	if (bx + w > 480) bx = 480 - w;
	if (bx < 30) bx = 30;
	const by = top: int - 26;
	viper::round_rect(win, bx, by, w, 22, 8, 0xfffff8e8);
	viper::text(win, bx + 8, by + 3, th.bubble, 0xff2a1604);
};

// ---- Drawing from shapes (used when there are no sprites) ----

fn draw_thief(win: *viper::window, g: *game, ts: *thief_sprites) void = {
	const th = &g.thief;
	if (th.phase == tphase::OFF) return;
	if (draw_thief_sprite(win, g, ts)) return;
	// Facing: left while walking in or escaping, right while fleeing.
	const f = if (th.phase == tphase::FLEE) 1.0 else -1.0;
	const walking = th.phase == tphase::ENTER || th.phase == tphase::FLEE
		|| th.phase == tphase::ESCAPE;
	const speed = if (th.phase == tphase::FLEE) 22.0 else 12.0;
	const step_ = if (walking) math::sinf64(th.anim * speed) else 0.0;
	let x = th.x, y = SHELF_Y - 4.0 - math::absf64(step_) * 4.0;
	if (th.phase == tphase::ANGRY) x += math::sinf64(th.t * 60.0) * 3.0;
	if (th.phase == tphase::WAIT) y += math::sinf64(th.anim * 3.0) * 1.5;

	// Sack of stolen honey on his back.
	const sr = 13.0 + th.sack * 10.0;
	const sx = x - f * 22.0, sy = y - 26.0;
	viper::circle(win, sx: int, sy: int, (sr + 2.0): int, 0xff4a2a0a);
	viper::circle(win, sx: int, sy: int, sr: int, 0xffa8763a);
	viper::hexagon(win, sx, sy, sr * 0.45, 0xffffc23a);
	viper::hexagon(win, sx, sy, sr * 0.3, 0xffe09a20);

	// Wings.
	const flap = if (walking) math::sinf64(th.anim * 40.0) * 3.0 else 0.0;
	viper::circle(win, (x - f * 6.0): int, (y - 40.0 + flap): int, 10, 0xffd8ecff);
	viper::circle(win, (x + f * 4.0): int, (y - 44.0 - flap): int, 8, 0xffeaf4ff);

	// Legs.
	for (let i = 0; i < 2; i += 1) {
		const lx = x - 6.0 + i: f64 * 12.0 + step_ * (if (i == 0) 5.0 else -5.0);
		viper::rect(win, lx: int, (y - 6.0): int, 5, 8, 0xff1a1008);
	};
	// Striped body.
	viper::circle(win, x: int, (y - 18.0): int, 17, 0xff1a1008);
	viper::circle(win, x: int, (y - 18.0): int, 15, 0xffffc82a);
	for (let i = -1; i <= 1; i += 2) {
		viper::rect(win, (x + i: f64 * 5.0 - 2.0): int, (y - 32.0): int, 5, 28, 0xff1a1008);
	};
	// Purple scarf.
	viper::rect(win, (x - 13.0): int, (y - 34.0): int, 26, 6, 0xff6b2a8a);
	viper::rect(win, (x - f * 12.0): int, (y - 32.0): int, 5, 12, 0xff6b2a8a);
	// Head with the bandit mask.
	const hx = x + f * 4.0, hy = y - 46.0;
	viper::circle(win, hx: int, hy: int, 13, 0xff1a1008);
	viper::circle(win, hx: int, hy: int, 11, 0xffffd85a);
	viper::rect(win, (hx - 11.0): int, (hy - 3.0): int, 23, 7, 0xff1a1008);
	const angry = th.phase == tphase::ANGRY || th.phase == tphase::FLEE;
	viper::rect(win, (hx + f * 3.0 - 2.0): int, (hy - 1.0): int, 4, (if (angry) 2 else 3), 0xffffffff);
	viper::rect(win, (hx + f * 8.0 - 2.0): int, (hy - 1.0): int, 4, (if (angry) 2 else 3), 0xffffffff);
	// Grin.
	viper::rect(win, (hx + f * 3.0): int, (hy + 6.0): int, 6, 2, 0xff1a1008);
	// Cap and goggles.
	viper::rect(win, (hx - 12.0): int, (hy - 13.0): int, 24, 6, 0xff3a2a1a);
	viper::rect(win, (hx + f * 6.0 - 4.0): int, (hy - 10.0): int, 8, 3, 0xff3a2a1a);
	viper::circle(win, (hx - 4.0): int, (hy - 10.0): int, 4, 0xff9ad0e8);
	viper::circle(win, (hx + 5.0): int, (hy - 10.0): int, 4, 0xff9ad0e8);
	// Antennae.
	viper::line(win, (hx - 4.0): int, (hy - 14.0): int, (hx - 8.0): int, (hy - 22.0): int, 0xff1a1008);
	viper::line(win, (hx + 4.0): int, (hy - 14.0): int, (hx + 8.0): int, (hy - 22.0): int, 0xff1a1008);

	// Stealing: a honey jar appears in his hand.
	if (th.phase == tphase::STEAL && th.t < 0.6) {
		const jx = x + f * 22.0, jy = y - 16.0 - th.t * 10.0;
		viper::round_rect(win, (jx - 7.0): int, (jy - 8.0): int, 14, 14, 3, 0xffe0951e);
		viper::rect(win, (jx - 8.0): int, (jy - 10.0): int, 16, 4, 0xff8a5212);
	};
	// "!" when angry.
	if (th.phase == tphase::ANGRY) {
		viper::text_scaled(win, (hx - 4.0): int, (hy - 46.0): int, "!", 0xffff3a3a, 2);
	};
	// Speech bubble.
	if (th.bubble_t > 0.0) {
		const w = viper::text_width(th.bubble, 1) + 16;
		const bx = (if (x + w: f64 / 2.0 > 470.0) 470 - w else (x: int - w / 2));
		const bx = if (bx < 30) 30 else bx;
		const by = (hy - 52.0): int;
		viper::round_rect(win, bx, by, w, 22, 8, 0xfffff8e8);
		viper::text(win, bx + 8, by + 3, th.bubble, 0xff2a1604);
	};
};

// The wooden honey shelf the thief walks on.
fn draw_shelf(win: *viper::window) void = {
	viper::rect(win, 22, SHELF_Y: int, 462, 10, 0xff6b3d0c);
	viper::rect(win, 22, SHELF_Y: int, 462, 3, 0xffa8661c);
	for (let x = 40; x < 480; x += 70) {
		viper::rect(win, x, SHELF_Y: int + 10, 6, 24, 0xff4a2a08);
	};
};
