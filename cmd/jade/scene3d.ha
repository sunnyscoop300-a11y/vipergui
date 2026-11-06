// JADE — the temple garden in real 3D, and the cameras that look at it.
use math;
use viper;

type view = enum { CHASE, BIRD, CLASSIC };

fn view_name(vw: view) str = switch (vw) {
case view::CHASE => yield "Kamera: bag slangen";
case view::BIRD => yield "Kamera: fugleperspektiv";
case view::CLASSIC => yield "Kamera: klassisk";
};

type cams = struct {
	yaw: f64,          // where the camera looks, smoothed
	bird_q: int,       // bird view: which quarter it looks from
	pos: v3,
	target: v3,
	ready: bool,
};

// The snake's heading as a yaw angle (UP = 0, RIGHT = a quarter turn...).
fn dir_yaw(d: dir) f64 = d: int: f64 * math::PI / 2.0;

// Turns a toward b the short way round.
fn approach_angle(a: f64, b: f64, k: f64) f64 = {
	let d = b - a;
	for (d > math::PI) d -= 2.0 * math::PI;
	for (d < -math::PI) d += 2.0 * math::PI;
	return a + d * (if (k > 1.0) 1.0 else k);
};

// Where the head is right now, in world space (between cells).
fn head_world(s: *state, f: f64) v3 = {
	const (x, y) = part_pos(s, 0, f);
	return v(x, 0.5, y);
};

fn update_camera(c: *cams, vw: view, s: *state, f: f64, dt: f64) void = {
	let pos = v(0.0, 0.0, 0.0), target = v(0.0, 0.0, 0.0);
	switch (vw) {
	case view::CHASE =>
		c.yaw = approach_angle(c.yaw, dir_yaw(s.d), dt * 6.0);
		const h = head_world(s, f);
		const fwd = yaw_dir(c.yaw);
		pos = vadd(vsub(h, vmul(fwd, 4.2)), v(0.0, 3.7, 0.0));
		target = vadd(vadd(h, vmul(fwd, 3.4)), v(0.0, -0.3, 0.0));
	case view::BIRD =>
		c.yaw = approach_angle(c.yaw, c.bird_q: f64 * math::PI / 2.0, dt * 5.0);
		const mid = v(N: f64 / 2.0, 0.0, N: f64 / 2.0);
		const fwd = yaw_dir(c.yaw);
		pos = vadd(vsub(mid, vmul(fwd, 10.5)), v(0.0, 13.0, 0.0));
		target = vadd(mid, vmul(fwd, 0.8));
	case view::CLASSIC => return;
	};
	if (!c.ready) {
		c.pos = pos;
		c.target = target;
		c.ready = true;
	};
	// Glide rather than jump.
	const k = if (dt * 8.0 > 1.0) 1.0 else dt * 8.0;
	c.pos = vlerp(c.pos, pos, k);
	c.target = vlerp(c.target, target, k);
};

// ---- The sky, which turns with the camera ----

fn draw_sky3d(win: *viper::window, r: *r3d, clock: f64) void = {
	// Where the horizon is on screen.
	let hy = r.cam.cy;
	match (project(r, vadd(r.cam.pos, vadd(vmul(vnorm(v(r.cam.fwd.x, 0.0, r.cam.fwd.z)), 100.0), v(0.0, 0.0, 0.0))))) {
	case let p: (f64, f64, f64) => hy = p.1;
	case void => void;
	};
	for (let y = 0; y < H; y += 1) {
		const t = (y: f64 - (hy - 330.0)) / 330.0;
		const c: u32 = if (t < 0.0) 0xff141238
			else if (t < 1.0) viper::mix(0xff141238, 0xffb0506a, t)
			else viper::mix(0xffb0506a, r.fog, if (t - 1.0 > 0.3) 1.0 else (t - 1.0) / 0.3);
		const row = (y * W): size;
		for (let x = 0z; x < W: size; x += 1) win.pixels[row + x] = c;
	};
	// Stars, fixed in the sky as the camera turns.
	let seed = 777u32;
	for (let i = 0; i < 120; i += 1) {
		seed = seed * 1103515245 + 12345;
		const a = (seed >> 8): f64 / 16777216.0 * 2.0 * math::PI;
		seed = seed * 1103515245 + 12345;
		const el = 0.12 + (seed >> 8): f64 / 16777216.0 * 0.9;
		const p = v(math::cosf64(a) * math::cosf64(el), math::sinf64(el), math::sinf64(a) * math::cosf64(el));
		match (project(r, vadd(r.cam.pos, vmul(p, 200.0)))) {
		case let q: (f64, f64, f64) =>
			if (q.0 >= 0.0 && q.1 >= 0.0 && q.0 < W: f64 && q.1 < H: f64) {
				win.pixels[(q.1: int * W + q.0: int): size] =
					if (i % 3 == 0) 0xffffffff else 0xffb8b0e0;
			};
		case void => void;
		};
	};
	// The moon.
	match (project(r, vadd(r.cam.pos, vmul(vnorm(v(0.6, 0.38, -0.7)), 200.0)))) {
	case let q: (f64, f64, f64) =>
		viper::circle(win, q.0: int, q.1: int, 40, 0xfff8eccc);
		viper::circle(win, q.0: int - 12, q.1: int - 8, 9, 0xffe8dab8);
		viper::circle(win, q.0: int + 12, q.1: int + 14, 6, 0xffe8dab8);
	case void => void;
	};
};

// ---- The garden ----

fn draw_garden3d(r: *r3d, s: *state, f: f64, clock: f64, dead: bool, show_ahead: bool) void = {
	const n = N: f64;
	// Mountains far away all around, and a misty ground under the garden.
	for (let i = 0; i < 28; i += 1) {
		const a0 = i: f64 * 2.0 * math::PI / 28.0, a1 = (i + 1): f64 * 2.0 * math::PI / 28.0;
		const am = (a0 + a1) / 2.0;
		const rad = 44.0;
		const mid = v(n / 2.0, -2.0, n / 2.0);
		const hgt = 7.0 + 5.0 * math::sinf64(i: f64 * 2.3) + 3.0 * math::sinf64(i: f64 * 0.9);
		const p0 = vadd(mid, v(math::cosf64(a0) * rad, 0.0, math::sinf64(a0) * rad));
		const p1 = vadd(mid, v(math::cosf64(a1) * rad, 0.0, math::sinf64(a1) * rad));
		const top = vadd(mid, v(math::cosf64(am) * rad * 1.05, hgt, math::sinf64(am) * rad * 1.05));
		const col: u32 = if (i % 2 == 0) 0xff3a2246 else 0xff2e1c3a;
		tri_n(r, p0, p1, top, vnorm(vsub(mid, top)), col, true);
	};
	floor_quad(r, -40.0, -40.0, n + 40.0, n + 40.0, -2.0, 0xff2a1a2e);

	// The stone platform and the temple wall around the garden.
	box3(r, -1.0, -0.9, -1.0, n + 1.0, -0.02, n + 1.0, 0xff8a7a66);
	const wall: u32 = 0xffb8322a, cap: u32 = 0xffe8b84a;
	box3(r, -1.0, 0.0, -1.0, n + 1.0, 0.5, 0.0, wall);
	box3(r, -1.0, 0.0, n, n + 1.0, 0.5, n + 1.0, wall);
	box3(r, -1.0, 0.0, 0.0, 0.0, 0.5, n, wall);
	box3(r, n, 0.0, 0.0, n + 1.0, 0.5, n, wall);
	box3(r, -1.05, 0.5, -1.05, n + 1.05, 0.62, -0.0, cap);
	box3(r, -1.05, 0.5, n, n + 1.05, 0.62, n + 1.05, cap);
	box3(r, -1.05, 0.5, 0.0, 0.0, 0.62, n, cap);
	box3(r, n, 0.5, 0.0, n + 1.05, 0.62, n, cap);

	// Grass, stone and water.
	for (let y = 0; y < N; y += 1) for (let x = 0; x < N; x += 1) {
		const fx = x: f64, fz = y: f64;
		switch (s.grid[x][y]) {
		case cell::WATER =>
			const w = 0.5 + 0.5 * math::sinf64(clock * 2.0 + (x + y): f64 * 0.9);
			floor_quad(r, fx, fz, fx + 1.0, fz + 1.0, 0.004, viper::mix(0xff2a6a9a, 0xff3a86b4, w));
			if ((x * 7 + y * 3) % 4 == 0) {
				ball3(r, v(fx + 0.4, 0.02, fz + 0.5), 0.28, 0.02, 0.28, 0xff3f9a4a);
				ball3(r, v(fx + 0.45, 0.07, fz + 0.45), 0.08, 0.06, 0.08, 0xffff9ad0);
			};
		case cell::PILLAR =>
			floor_quad(r, fx, fz, fx + 1.0, fz + 1.0, 0.0, 0xff378556);
			pillar3(r, fx + 0.5, fz + 0.5);
		case cell::FLOOR =>
			floor_quad(r, fx, fz, fx + 1.0, fz + 1.0, 0.0,
				if ((x + y) % 2 == 0) 0xff3f8f62 else 0xff378556);
		};
	};

	if (show_ahead && !dead) ahead3(r, s);

	// Food.
	const bob = math::sinf64(clock * 3.0) * 0.08;
	const fx = s.food.0: f64 + 0.5, fz = s.food.1: f64 + 0.5;
	if (inside(s.food.0, s.food.1)) {
		shadow3(r, fx, fz, 0.26);
		ball3(r, v(fx, 0.42 + bob, fz), 0.27, 0.27, 0.27, 0xffff9a6a);
		ball3(r, v(fx + 0.1, 0.36 + bob, fz + 0.12), 0.12, 0.12, 0.12, 0xffff6a72);
		const leaf = v(fx + 0.05, 0.72 + bob, fz);
		tri_n(r, leaf, vadd(leaf, v(0.25, 0.1, 0.0)), vadd(leaf, v(0.12, -0.05, 0.12)),
			v(0.0, 1.0, 0.0), 0xff4aa84a, true);
	};
	if (s.gold_t > 0.0 && !(s.gold_t < 2.0 && math::sinf64(clock * 18.0) < 0.0)) {
		const gx = s.gold.0: f64 + 0.5, gz = s.gold.1: f64 + 0.5;
		shadow3(r, gx, gz, 0.3);
		const b2 = 0.45 + math::sinf64(clock * 4.0) * 0.1;
		ball3(r, v(gx, b2, gz), 0.34, 0.26, 0.34, 0xfffff2d8);
		ball3(r, v(gx, b2 + 0.26, gz), 0.08, 0.08, 0.08, 0xffe8b84a);
		// A golden ring spinning around it.
		for (let i = 0; i < 8; i += 1) {
			const a = clock * 2.0 + i: f64 * math::PI / 4.0;
			ball3(r, v(gx + math::cosf64(a) * 0.48, b2, gz + math::sinf64(a) * 0.48),
				0.05, 0.05, 0.05, 0xffffd23a);
		};
	};

	snake3(r, s, f, clock, dead);
};

fn pillar3(r: *r3d, cx: f64, cz: f64) void = {
	box3(r, cx - 0.4, 0.0, cz - 0.4, cx + 0.4, 0.16, cz + 0.4, 0xffb0a088);
	// Right next to the camera it would fill the screen: leave just the foot.
	const d = vsub(v(cx, 1.0, cz), r.cam.pos);
	if (d.x * d.x + d.z * d.z < 2.6 * 2.6) return;
	prism(r, cx, cz, 0.27, 0.16, 1.45, 8, 0xffc8382c);
	prism(r, cx, cz, 0.3, 1.18, 1.3, 8, 0xffe8b84a);
	box3(r, cx - 0.48, 1.45, cz - 0.48, cx + 0.48, 1.56, cz + 0.48, 0xff2f8f6a);
	pyramid(r, cx, cz, 0.48, 1.56, 2.0, 0xff3aa078);
	ball3(r, v(cx, 2.02, cz), 0.06, 0.06, 0.06, 0xffe8b84a);
};

// A thin frame on the cell she is about to enter.
fn ahead3(r: *r3d, s: *state) void = {
	const d = if (s.nq > 0) s.queue[0] else s.d;
	const (dx, dy) = dvec(d);
	const x = s.body[0].0 + dx, y = s.body[0].1 + dy;
	if (!inside(x, y)) return;
	const col: u32 = if (blocked(s, x, y, true)) 0xffff5a4a else 0xffa8f0c8;
	const fx = x: f64, fz = y: f64, t = 0.07, h = 0.02;
	floor_quad(r, fx, fz, fx + 1.0, fz + t, h, col);
	floor_quad(r, fx, fz + 1.0 - t, fx + 1.0, fz + 1.0, h, col);
	floor_quad(r, fx, fz, fx + t, fz + 1.0, h, col);
	floor_quad(r, fx + 1.0 - t, fz, fx + 1.0, fz + 1.0, h, col);
};

fn snake3(r: *r3d, s: *state, f: f64, clock: f64, dead: bool) void = {
	const body: u32 = if (dead) 0xff6a7064 else 0xff2fae74;
	const dark: u32 = if (dead) 0xff50564c else 0xff23905e;
	for (let i = s.n; i > 0; i -= 1) {
		const k = i - 1;
		const (x, z) = part_pos(s, k, f);
		const t = k: f64 / s.n: f64;
		const rad = 0.36 - t * 0.14;
		if (k > 0) {
			shadow3(r, x, z, rad * 0.9);
			ball3(r, v(x, rad + 0.04, z), rad, rad, rad, if (k % 2 == 0) body else dark);
			if (k % 4 == 2 && !dead) {
				ball3(r, v(x, rad * 2.0 + 0.02, z), 0.07, 0.05, 0.07, 0xffe8b84a);
			};
		};
		// Fill the gap to the next part.
		if (k + 1 < s.n) {
			const (x2, z2) = part_pos(s, k + 1, f);
			const r2 = 0.36 - (k + 1): f64 / s.n: f64 * 0.14;
			const rm = (rad + r2) / 2.0;
			ball3(r, v((x + x2) / 2.0, rm + 0.04, (z + z2) / 2.0), rm, rm, rm, body);
		};
	};
	head3(r, s, f, clock, dead);
};

fn head3(r: *r3d, s: *state, f: f64, clock: f64, dead: bool) void = {
	const (x, z) = part_pos(s, 0, f);
	// Facing: where she is going.
	let fwd = vnorm(v(dvec(s.d).0: f64, 0.0, dvec(s.d).1: f64));
	const side = v(-fwd.z, 0.0, fwd.x);
	const c = v(x, 0.48, z);
	shadow3(r, x, z, 0.45);
	const skin: u32 = if (dead) 0xff6a7064 else 0xff34b87c;
	// A head a little longer than it is wide, and a snout.
	ball3(r, c, 0.44 + math::absf64(fwd.x) * 0.08, 0.38, 0.44 + math::absf64(fwd.z) * 0.08, skin);
	ball3(r, vadd(c, vadd(vmul(fwd, 0.3), v(0.0, -0.06, 0.0))), 0.28, 0.24, 0.28, skin);
	// Eyes.
	for (let k = -1.0; k <= 1.0; k += 2.0) {
		const e = vadd(c, vadd(vadd(vmul(fwd, 0.22), vmul(side, 0.24 * k)), v(0.0, 0.22, 0.0)));
		if (dead) {
			ball3(r, e, 0.1, 0.03, 0.1, 0xff202020);
			continue;
		};
		ball3(r, e, 0.13, 0.13, 0.13, 0xfffff8e0);
		ball3(r, vadd(e, vmul(fwd, 0.1)), 0.07, 0.08, 0.07, 0xff101810);
	};
	if (dead) return;
	// A gold crest.
	pyramid(r, c.x - fwd.x * 0.12, c.z - fwd.z * 0.12, 0.09, 0.82, 1.08, 0xffe8b84a);
	// The tongue flicks now and then.
	if (math::sinf64(clock * 5.0) > 0.55) {
		const t0 = vadd(c, vadd(vmul(fwd, 0.55), v(0.0, -0.1, 0.0)));
		const t1 = vadd(t0, vmul(fwd, 0.35));
		const w = vmul(side, 0.03);
		tri_n(r, vsub(t0, w), vadd(t0, w), t1, v(0.0, 1.0, 0.0), 0xffe03050, true);
		tri_n(r, t1, vadd(t1, vadd(vmul(fwd, 0.12), vmul(side, 0.08))), vadd(t1, vmul(fwd, 0.04)),
			v(0.0, 1.0, 0.0), 0xffe03050, true);
		tri_n(r, t1, vadd(t1, vsub(vmul(fwd, 0.12), vmul(side, 0.08))), vadd(t1, vmul(fwd, 0.04)),
			v(0.0, 1.0, 0.0), 0xffe03050, true);
	};
};

// Arrows over the food, drawn on top of the 3D picture.
fn food_markers3d(win: *viper::window, r: *r3d, s: *state, clock: f64) void = {
	marker3d(win, r, s.food.0, s.food.1, clock, 0xffff8a6a);
	if (s.gold_t > 0.0) marker3d(win, r, s.gold.0, s.gold.1, clock + 1.0, 0xffffd23a);
};

fn marker3d(win: *viper::window, r: *r3d, x: int, y: int, clock: f64, col: u32) void = {
	if (!inside(x, y)) return;
	const bob = math::sinf64(clock * 4.0) * 0.1;
	const top = project(r, v(x: f64 + 0.5, 1.6 + bob, y: f64 + 0.5));
	const low = project(r, v(x: f64 + 0.5, 0.85, y: f64 + 0.5));
	const (tx, ty, tz) = match (top) {
	case let p: (f64, f64, f64) => yield p;
	case void => return;
	};
	// Smaller the further away it is.
	let k = 6.0 / tz;
	if (k > 1.3) k = 1.3;
	if (k < 0.5) k = 0.5;
	match (low) {
	case let p: (f64, f64, f64) =>
		for (let yy = ty + 10.0 * k; yy < p.1; yy += 6.0) {
			viper::rect(win, tx: int - 1, yy: int, 2, 2, col);
		};
	case void => void;
	};
	const out: [3](f64, f64) = [(tx - 12.0 * k, ty - 10.0 * k), (tx + 12.0 * k, ty - 10.0 * k), (tx, ty + 9.0 * k)];
	const tri: [3](f64, f64) = [(tx - 9.0 * k, ty - 8.0 * k), (tx + 9.0 * k, ty - 8.0 * k), (tx, ty + 6.0 * k)];
	viper::polygon(win, out, 0xff1a1010);
	viper::polygon(win, tri, col);
};
