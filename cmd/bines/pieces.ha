// BINES — drawing the pieces and power-ups. Pieces are drawn from shapes;
// if assets/bines/pieces.png exists (seven pieces side by side in the
// order honey, flower, leaf, berry, crystal, wax, pollen) those are used.
use math;
use viper;

type sprites = struct {
	frames: []viper::image,
};

fn load_sprites() sprites = {
	match (viper::load_png("assets/bines/pieces.png")) {
	case let sheet: viper::image =>
		defer viper::image_free(&sheet);
		const px = (R * 1.45): int;
		return sprites { frames = viper::split_sheet(&sheet, px, px)! };
	case viper::imgerror =>
		return sprites { frames = [] };
	};
};

const piece_color: [7]viper::color = [0xffffb320, 0xffff8fbf, 0xff5ccf4a,
	0xff4a7aff, 0xffb46aff, 0xfff6e7b0, 0xffffa424];

fn drop(win: *viper::window, x: f64, y: f64, u: f64, dark: viper::color,
		light: viper::color, shine: viper::color) void = {
	const pts: [3](f64, f64) = [(x, y - u * 1.25), (x - u * 0.72, y - u * 0.05),
		(x + u * 0.72, y - u * 0.05)];
	viper::circle(win, x: int, (y + u * 0.18): int, (u * 0.8): int, dark);
	viper::polygon(win, pts, dark);
	const inner: [3](f64, f64) = [(x, y - u * 1.05), (x - u * 0.6, y),
		(x + u * 0.6, y)];
	viper::circle(win, x: int, (y + u * 0.18): int, (u * 0.68): int, light);
	viper::polygon(win, inner, light);
	viper::circle(win, (x - u * 0.28): int, (y + u * 0.05): int, (u * 0.16): int, shine);
};

// s scales the piece (1.0 = normal, shrinking to 0 when it pops).
fn draw_piece(win: *viper::window, sp: *sprites, k: u8, x: f64, y: f64, s: f64) void = {
	if (s <= 0.05) return;
	if (k < len(sp.frames): u8 && s >= 0.99) {
		const img = &sp.frames[k];
		viper::draw_image(win, img, x: int - img.w / 2, y: int - img.h / 2);
		return;
	};
	const ix = x: int, iy = y: int;
	const u = R * 0.62 * s; // unit size
	switch (k) {
	case piece::HONEY =>
		drop(win, x, y, u, 0xff9a5a08, 0xffffb320, 0xfffff0b0);
	case piece::FLOWER =>
		for (let i = 0; i < 5; i += 1) {
			const a = -math::PI / 2.0 + i: f64 * 2.0 * math::PI / 5.0;
			const px = x + math::cosf64(a) * u * 0.6, py = y + math::sinf64(a) * u * 0.6;
			viper::circle(win, px: int, py: int, (u * 0.45): int, 0xffc2407a);
			viper::circle(win, px: int, py: int, (u * 0.37): int, 0xffff8fbf);
		};
		viper::circle(win, ix, iy, (u * 0.34): int, 0xffb87a00);
		viper::circle(win, ix, iy, (u * 0.27): int, 0xffffd23a);
	case piece::LEAF =>
		// A pointed leaf, tilted, with a vein down the middle.
		let outer: [16](f64, f64) = [(0.0, 0.0)...];
		let inner: [16](f64, f64) = [(0.0, 0.0)...];
		for (let i = 0z; i < 16; i += 1) {
			const t = i: f64 / 16.0 * 2.0 * math::PI;
			// Lens shape: width shrinks towards both tips.
			const lx = math::sinf64(t) * u * 0.55;
			const ly = math::cosf64(t) * u * 1.05;
			const ca = 0.78, sa = 0.62; // ~38 degrees
			outer[i] = (x + lx * ca - ly * sa, y + lx * sa + ly * ca);
			inner[i] = (x + lx * 0.82 * ca - ly * 0.88 * sa, y + lx * 0.82 * sa + ly * 0.88 * ca);
		};
		viper::polygon(win, outer, 0xff2a7a22);
		viper::polygon(win, inner, 0xff5ccf4a);
		viper::line(win, (x + u * 0.62): int, (y - u * 0.78): int,
			(x - u * 0.62): int, (y + u * 0.78): int, 0xff2a7a22);
		viper::circle(win, (x + u * 0.15): int, (y - u * 0.35): int, (u * 0.1): int, 0xffb8f0a0);
	case piece::BERRY =>
		viper::circle(win, ix, (y + u * 0.1): int, (u * 0.82): int, 0xff1a2a7a);
		viper::circle(win, ix, (y + u * 0.1): int, (u * 0.72): int, 0xff4a7aff);
		viper::circle(win, (x - u * 0.28): int, (y - u * 0.15): int, (u * 0.2): int, 0xffc8d8ff);
		// Little green leaves on top.
		const lf: [3](f64, f64) = [(x, y - u * 0.55), (x - u * 0.45, y - u * 0.95),
			(x + u * 0.1, y - u * 0.75)];
		viper::polygon(win, lf, 0xff3a9a32);
		const lf2: [3](f64, f64) = [(x, y - u * 0.55), (x + u * 0.5, y - u * 0.9),
			(x + u * 0.05, y - u * 0.78)];
		viper::polygon(win, lf2, 0xff4ab83c);
	case piece::CRYSTAL =>
		viper::hexagon(win, x, y, u * 0.98, 0xff4a1a8a, true);
		viper::hexagon(win, x, y, u * 0.85, 0xffb46aff, true);
		// Facets.
		const top: [4](f64, f64) = [(x, y - u * 0.85), (x + u * 0.73, y - u * 0.42),
			(x, y), (x - u * 0.73, y - u * 0.42)];
		viper::polygon(win, top, 0xffd8a8ff);
		viper::hexagon(win, x, y + u * 0.1, u * 0.32, 0xff8a3ae0, true);
		viper::rect(win, (x - u * 0.45): int, (y - u * 0.5): int, 3, 3, 0xffffffff);
	case piece::WAX =>
		viper::hexagon(win, x, y, u * 0.95, 0xff8a6a2a, true);
		viper::hexagon(win, x, y, u * 0.8, 0xfff6e7b0, true);
		viper::hexagon(win, x - u * 0.12, y - u * 0.12, u * 0.42, 0xfffffbe6, true);
	case piece::POLLEN =>
		const grains: [7](f64, f64) = [(0.0, 0.0), (0.55, -0.2), (-0.55, -0.2),
			(0.3, 0.5), (-0.3, 0.5), (0.25, -0.62), (-0.25, -0.62)];
		for (let g .. grains) {
			viper::circle(win, (x + g.0 * u): int, (y + g.1 * u): int,
				(u * 0.36): int, 0xffb85c00);
		};
		for (let g .. grains) {
			viper::circle(win, (x + g.0 * u): int, (y + g.1 * u): int,
				(u * 0.28): int, 0xffffa424);
			viper::rect(win, (x + g.0 * u - u * 0.08): int, (y + g.1 * u - u * 0.12): int,
				2, 2, 0xffffe1a0);
		};
	case RAINBOW =>
		// Regnbueblomst: six coloured petals.
		const cols: [6]viper::color = [0xffff4a4a, 0xffffa424, 0xffffe03a,
			0xff5ccf4a, 0xff4a7aff, 0xffb46aff];
		for (let i = 0; i < 6; i += 1) {
			const a = i: f64 * math::PI / 3.0 + 0.3;
			viper::circle(win, (x + math::cosf64(a) * u * 0.62): int,
				(y + math::sinf64(a) * u * 0.62): int, (u * 0.42): int, cols[i]);
		};
		viper::circle(win, ix, iy, (u * 0.36): int, 0xffffffff);
		viper::circle(win, ix, iy, (u * 0.22): int, 0xfffff4b0);
	case => void;
	};
};

// Draws the power-up marking on top of a piece.
fn draw_special(win: *viper::window, sp: special, x: f64, y: f64, s: f64, clock: f64) void = {
	if (s <= 0.05) return;
	switch (sp) {
	case special::STRIPE0, special::STRIPE1, special::STRIPE2 =>
		// Two glowing bars along the stripe's direction.
		const dirs: [3](f64, f64) = [(0.0, 1.0), (0.866, 0.5), (0.866, -0.5)];
		const d = dirs[(sp: u8 - special::STRIPE0: u8): size];
		const n = (-d.1, d.0); // perpendicular
		const len_ = R * 0.78 * s;
		for (let k = -1; k <= 1; k += 2) {
			const ox = n.0 * k: f64 * 6.0 * s, oy = n.1 * k: f64 * 6.0 * s;
			for (let w = -1; w <= 1; w += 1) {
				viper::line(win, (x + ox - d.0 * len_ + n.0 * w: f64): int,
					(y + oy - d.1 * len_ + n.1 * w: f64): int,
					(x + ox + d.0 * len_ + n.0 * w: f64): int,
					(y + oy + d.1 * len_ + n.1 * w: f64): int,
					if (w == 0) 0xffffffff else 0xff8a4a08);
			};
		};
	case special::BOMB =>
		// A pulsing ring and a fizzing fuse.
		const p = 0.5 + 0.5 * math::sinf64(clock * 8.0);
		const r = R * 0.8 * s;
		for (let i = 0; i < 24; i += 1) {
			const a = i: f64 * math::PI / 12.0;
			viper::circle(win, (x + math::cosf64(a) * r): int, (y + math::sinf64(a) * r): int,
				2, viper::mix(0xffff5a1a, 0xfffff4b0, p));
		};
		viper::line(win, x: int, (y - r): int, (x + 6.0): int, (y - r - 8.0): int, 0xff3a2a1a);
		viper::circle(win, (x + 7.0): int, (y - r - 9.0): int, 3,
			viper::mix(0xffff3a1a, 0xffffff60, p));
	case special::RAINBOW, special::NONE => void;
	};
};

// The bee mascot for the title.
fn draw_bee(win: *viper::window, x: f64, y: f64, u: f64) void = {
	viper::circle(win, (x - u * 0.35): int, (y - u * 0.62): int, (u * 0.36): int, 0xffcfe8ff);
	viper::circle(win, (x + u * 0.25): int, (y - u * 0.68): int, (u * 0.32): int, 0xffcfe8ff);
	viper::circle(win, x: int, y: int, (u * 0.78): int, 0xff2a1a08);
	viper::circle(win, x: int, y: int, (u * 0.68): int, 0xffffd02a);
	viper::rect(win, (x - u * 0.25): int, (y - u * 0.62): int, (u * 0.18): int, (u * 1.24): int, 0xff2a1a08);
	viper::rect(win, (x + u * 0.15): int, (y - u * 0.6): int, (u * 0.18): int, (u * 1.2): int, 0xff2a1a08);
	viper::circle(win, (x + u * 0.5): int, (y - u * 0.1): int, (u * 0.12): int, 0xff2a1a08);
};
