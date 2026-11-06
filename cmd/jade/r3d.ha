// JADE — a small software 3D renderer on top of ViperGui's pixel buffer.
//
// World space: x to the right, y up, z toward the viewer at the start;
// grid cell (gx, gy) is the unit square from (gx, 0, gy) to (gx+1, 0, gy+1).
// Triangles are lit by one light, faded into fog with distance, clipped
// against the near plane, projected with perspective and filled into the
// window with a z-buffer, so near things hide far ones pixel by pixel.
use math;
use viper;

type v3 = struct { x: f64, y: f64, z: f64 };

fn v(x: f64, y: f64, z: f64) v3 = v3 { x = x, y = y, z = z };
fn vadd(a: v3, b: v3) v3 = v(a.x + b.x, a.y + b.y, a.z + b.z);
fn vsub(a: v3, b: v3) v3 = v(a.x - b.x, a.y - b.y, a.z - b.z);
fn vmul(a: v3, k: f64) v3 = v(a.x * k, a.y * k, a.z * k);
fn vdot(a: v3, b: v3) f64 = a.x * b.x + a.y * b.y + a.z * b.z;
fn vcross(a: v3, b: v3) v3 =
	v(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
fn vlen(a: v3) f64 = math::sqrtf64(vdot(a, a));
fn vnorm(a: v3) v3 = {
	const l = vlen(a);
	return if (l < 1e-9) a else vmul(a, 1.0 / l);
};
fn vlerp(a: v3, b: v3, t: f64) v3 = vadd(a, vmul(vsub(b, a), t));

// The direction a yaw angle looks in, flat on the ground. Yaw 0 looks
// toward -z (grid "up"), a quarter turn toward +x.
fn yaw_dir(yaw: f64) v3 = v(math::sinf64(yaw), 0.0, -math::cosf64(yaw));

type camera = struct {
	pos: v3,
	right: v3,
	up: v3,
	fwd: v3,
	f: f64,      // focal length in pixels
	cx: f64,
	cy: f64,
};

def NEAR: f64 = 0.12;

fn look_at(pos: v3, target: v3, w: int, h: int, fov_deg: f64) camera = {
	const fwd = vnorm(vsub(target, pos));
	const right = vnorm(vcross(fwd, v(0.0, 1.0, 0.0)));
	const up = vcross(right, fwd);
	const f = (h: f64 / 2.0) / math::tanf64(fov_deg * math::PI / 360.0);
	return camera { pos = pos, right = right, up = up, fwd = fwd, f = f,
		cx = w: f64 / 2.0, cy = h: f64 / 2.0 };
};

type r3d = struct {
	win: *viper::window,
	zb: []f32,          // 1/depth of the nearest thing drawn at each pixel
	cam: camera,
	light: v3,          // toward the light
	fog: u32,
	fog_near: f64,
	fog_far: f64,
	tris: size,         // drawn this frame, for the curious
};

fn r3d_new(win: *viper::window) r3d = r3d {
	win = win,
	zb = alloc([0.0f32...], (win.width * win.height): size)!,
	light = vnorm(v(-0.45, 1.0, 0.35)),
	fog = 0xff4a2e5a,
	fog_near = 14.0,
	fog_far = 46.0,
	...
};

fn r3d_begin(r: *r3d, cam: camera) void = {
	r.cam = cam;
	r.tris = 0;
	for (let i = 0z; i < len(r.zb); i += 1) r.zb[i] = 0.0;
};

// A point in view space: x right, y up, z = distance in front.
fn to_view(c: *camera, p: v3) v3 = {
	const d = vsub(p, c.pos);
	return v(vdot(d, c.right), vdot(d, c.up), vdot(d, c.fwd));
};

// Where a world point lands on screen, if it's in front of the camera.
fn project(r: *r3d, p: v3) ((f64, f64, f64) | void) = {
	const q = to_view(&r.cam, p);
	if (q.z < NEAR) return;
	return (r.cam.cx + r.cam.f * q.x / q.z, r.cam.cy - r.cam.f * q.y / q.z, q.z);
};

fn scale_col(c: u32, k: f64) u32 = {
	const r = ((c >> 16) & 0xff): f64 * k, g = ((c >> 8) & 0xff): f64 * k,
		b = (c & 0xff): f64 * k;
	return 0xff000000 | c8(r) << 16 | c8(g) << 8 | c8(b);
};

fn c8(v: f64) u32 = if (v < 0.0) 0 else if (v > 255.0) 255 else v: u32;

// A triangle with its outward normal n. Faces turned away from the camera
// are skipped unless two_sided.
fn tri_n(r: *r3d, a: v3, b: v3, c: v3, n: v3, col: u32, two_sided: bool) void = {
	if (!two_sided && vdot(n, vsub(a, r.cam.pos)) >= 0.0) return;
	// Light: a bit of ambient, plus the sun.
	let l = vdot(n, r.light);
	if (two_sided && vdot(n, vsub(a, r.cam.pos)) > 0.0) l = -l;
	const k = 0.42 + 0.62 * (if (l > 0.0) l else 0.0);
	let shaded = scale_col(col, k);

	let pv: [3]v3 = [to_view(&r.cam, a), to_view(&r.cam, b), to_view(&r.cam, c)];
	// Fog by distance.
	const dist = (pv[0].z + pv[1].z + pv[2].z) / 3.0;
	if (dist > r.fog_near) {
		let t = (dist - r.fog_near) / (r.fog_far - r.fog_near);
		if (t > 1.0) t = 1.0;
		shaded = viper::mix(shaded, r.fog, t);
	};

	// Clip against the near plane: up to four corners remain.
	let out: [4]v3 = [v(0.0, 0.0, 0.0)...];
	let n_out = 0z;
	for (let i = 0z; i < 3; i += 1) {
		const p = pv[i], q = pv[(i + 1) % 3];
		const pin = p.z >= NEAR, qin = q.z >= NEAR;
		if (pin) {
			out[n_out] = p;
			n_out += 1;
		};
		if (pin != qin) {
			const t = (NEAR - p.z) / (q.z - p.z);
			out[n_out] = vlerp(p, q, t);
			n_out += 1;
		};
	};
	if (n_out < 3) return;
	let sx: [4]f64 = [0.0...], sy: [4]f64 = [0.0...], iz: [4]f64 = [0.0...];
	for (let i = 0z; i < n_out; i += 1) {
		sx[i] = r.cam.cx + r.cam.f * out[i].x / out[i].z;
		sy[i] = r.cam.cy - r.cam.f * out[i].y / out[i].z;
		iz[i] = 1.0 / out[i].z;
	};
	raster(r, sx[0], sy[0], iz[0], sx[1], sy[1], iz[1], sx[2], sy[2], iz[2], shaded);
	if (n_out == 4) {
		raster(r, sx[0], sy[0], iz[0], sx[2], sy[2], iz[2], sx[3], sy[3], iz[3], shaded);
	};
};

// A triangle of a closed, convex shape around center: the normal is the
// one pointing away from the center.
fn tri_c(r: *r3d, a: v3, b: v3, c: v3, center: v3, col: u32) void = {
	let n = vnorm(vcross(vsub(b, a), vsub(c, a)));
	if (vdot(n, vsub(a, center)) < 0.0) n = vmul(n, -1.0);
	tri_n(r, a, b, c, n, col, false);
};

fn quad_c(r: *r3d, a: v3, b: v3, c: v3, d: v3, center: v3, col: u32) void = {
	tri_c(r, a, b, c, center, col);
	tri_c(r, a, c, d, center, col);
};

// A flat horizontal quad facing up.
fn floor_quad(r: *r3d, x0: f64, z0: f64, x1: f64, z1: f64, y: f64, col: u32) void = {
	const up = v(0.0, 1.0, 0.0);
	const a = v(x0, y, z0), b = v(x1, y, z0), c = v(x1, y, z1), d = v(x0, y, z1);
	tri_n(r, a, b, c, up, col, false);
	tri_n(r, a, c, d, up, col, false);
};

// Fills a screen triangle, keeping the nearest pixel (largest 1/z).
fn raster(r: *r3d, x0: f64, y0: f64, z0: f64, x1: f64, y1: f64, z1: f64,
		x2: f64, y2: f64, z2: f64, col: u32) void = {
	let area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0);
	if (area == 0.0 || math::isnan(area)) return;
	const win = r.win;
	let minx = math::floorf64(min3(x0, x1, x2)): int;
	let maxx = math::ceilf64(max3(x0, x1, x2)): int;
	let miny = math::floorf64(min3(y0, y1, y2)): int;
	let maxy = math::ceilf64(max3(y0, y1, y2)): int;
	if (minx < win.clip_x0) minx = win.clip_x0;
	if (miny < win.clip_y0) miny = win.clip_y0;
	if (maxx > win.clip_x1 - 1) maxx = win.clip_x1 - 1;
	if (maxy > win.clip_y1 - 1) maxy = win.clip_y1 - 1;
	if (minx > maxx || miny > maxy) return;
	r.tris += 1;
	// Edge functions, stepped along x; the sign of area tells the winding.
	const s = if (area > 0.0) 1.0 else -1.0;
	const inv = 1.0 / (area * s);
	const a0 = (y1 - y2) * s, a1 = (y2 - y0) * s, a2 = (y0 - y1) * s;
	for (let y = miny; y <= maxy; y += 1) {
		const py = y: f64 + 0.5, px = minx: f64 + 0.5;
		let w0 = ((x2 - x1) * (py - y1) - (y2 - y1) * (px - x1)) * s;
		let w1 = ((x0 - x2) * (py - y2) - (y0 - y2) * (px - x2)) * s;
		let w2 = ((x1 - x0) * (py - y0) - (y1 - y0) * (px - x0)) * s;
		let row = (y * win.width): size;
		let inside = false;
		for (let x = minx; x <= maxx; x += 1) {
			if (w0 >= 0.0 && w1 >= 0.0 && w2 >= 0.0) {
				inside = true;
				const z = ((w0 * z0 + w1 * z1 + w2 * z2) * inv): f32;
				const i = row + x: size;
				if (z > r.zb[i]) {
					r.zb[i] = z;
					win.pixels[i] = col;
				};
			} else if (inside) {
				break; // past the right edge of a convex shape
			};
			w0 += a0;
			w1 += a1;
			w2 += a2;
		};
	};
};

fn min3(a: f64, b: f64, c: f64) f64 = if (a < b) (if (a < c) a else c) else (if (b < c) b else c);
fn max3(a: f64, b: f64, c: f64) f64 = if (a > b) (if (a > c) a else c) else (if (b > c) b else c);

// ---- Shapes ----

fn box3(r: *r3d, x0: f64, y0: f64, z0: f64, x1: f64, y1: f64, z1: f64, col: u32) void = {
	const c = v((x0 + x1) / 2.0, (y0 + y1) / 2.0, (z0 + z1) / 2.0);
	const p: [8]v3 = [v(x0, y0, z0), v(x1, y0, z0), v(x1, y0, z1), v(x0, y0, z1),
		v(x0, y1, z0), v(x1, y1, z0), v(x1, y1, z1), v(x0, y1, z1)];
	quad_c(r, p[4], p[5], p[6], p[7], c, col);           // top
	quad_c(r, p[0], p[1], p[2], p[3], c, col);           // bottom
	quad_c(r, p[0], p[1], p[5], p[4], c, col);           // -z
	quad_c(r, p[3], p[2], p[6], p[7], c, col);           // +z
	quad_c(r, p[0], p[3], p[7], p[4], c, col);           // -x
	quad_c(r, p[1], p[2], p[6], p[5], c, col);           // +x
};

// An upright prism with k sides (8 makes a nice round pillar).
fn prism(r: *r3d, cx: f64, cz: f64, rad: f64, y0: f64, y1: f64, k: int, col: u32) void = {
	const c = v(cx, (y0 + y1) / 2.0, cz);
	for (let i = 0; i < k; i += 1) {
		const a0 = (i: f64 + 0.5) * 2.0 * math::PI / k: f64;
		const a1 = (i: f64 + 1.5) * 2.0 * math::PI / k: f64;
		const p0x = cx + math::cosf64(a0) * rad, p0z = cz + math::sinf64(a0) * rad;
		const p1x = cx + math::cosf64(a1) * rad, p1z = cz + math::sinf64(a1) * rad;
		quad_c(r, v(p0x, y0, p0z), v(p1x, y0, p1z), v(p1x, y1, p1z), v(p0x, y1, p0z), c, col);
		tri_c(r, v(cx, y1, cz), v(p0x, y1, p0z), v(p1x, y1, p1z), c, col);
	};
};

// A four-sided pyramid roof from a square base at y0 to a point at y1.
fn pyramid(r: *r3d, cx: f64, cz: f64, half: f64, y0: f64, y1: f64, col: u32) void = {
	const top = v(cx, y1, cz);
	const c = v(cx, y0 + (y1 - y0) * 0.25, cz);
	const p: [4]v3 = [v(cx - half, y0, cz - half), v(cx + half, y0, cz - half),
		v(cx + half, y0, cz + half), v(cx - half, y0, cz + half)];
	for (let i = 0z; i < 4; i += 1) tri_c(r, p[i], p[(i + 1) % 4], top, c, col);
	quad_c(r, p[0], p[1], p[2], p[3], c, col);
};

// A low-poly ball (faceted like cut jade), stretched by (sx, sy, sz).
def LAT: int = 5;
def LON: int = 8;

fn ball3(r: *r3d, c: v3, sx: f64, sy: f64, sz: f64, col: u32) void = {
	// Skip it whole if it's behind the camera.
	const q = to_view(&r.cam, c);
	const big = if (sx > sy) (if (sx > sz) sx else sz) else (if (sy > sz) sy else sz);
	if (q.z < -big) return;
	let ring: [LAT + 1][LON]v3 = [[v(0.0, 0.0, 0.0)...]...];
	for (let i = 0; i <= LAT; i += 1) {
		const th = i: f64 * math::PI / LAT: f64;
		const y = math::cosf64(th), rr = math::sinf64(th);
		for (let j = 0; j < LON; j += 1) {
			const ph = (j: f64 + (i % 2): f64 * 0.5) * 2.0 * math::PI / LON: f64;
			ring[i][j] = v(c.x + math::cosf64(ph) * rr * sx, c.y + y * sy,
				c.z + math::sinf64(ph) * rr * sz);
		};
	};
	for (let i = 0; i < LAT; i += 1) for (let j = 0; j < LON; j += 1) {
		const j1 = (j + 1) % LON;
		const a = ring[i][j], b = ring[i][j1];
		const d = ring[i + 1][j], e = ring[i + 1][j1];
		if (i != 0) tri_c(r, a, b, d, c, col);
		if (i != LAT - 1) tri_c(r, b, e, d, c, col);
	};
};

// A dark flat disc on the ground, as a soft-edged shadow stand-in.
fn shadow3(r: *r3d, x: f64, z: f64, rad: f64) void = {
	const up = v(0.0, 1.0, 0.0);
	const y = 0.012;
	for (let i = 0; i < 8; i += 1) {
		const a0 = i: f64 * math::PI / 4.0, a1 = (i + 1): f64 * math::PI / 4.0;
		tri_n(r, v(x, y, z), v(x + math::cosf64(a0) * rad, y, z + math::sinf64(a0) * rad),
			v(x + math::cosf64(a1) * rad, y, z + math::sinf64(a1) * rad), up, 0xff1c4632, false);
	};
};
