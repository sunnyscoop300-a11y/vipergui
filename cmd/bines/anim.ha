// BINES — animation strips: frames in square cells side by side (cell
// width = picture height), the format of the thief, queen and booster
// sheets. Unlike viper::split_sheet this doesn't look for gaps between
// frames, so loose bits (a honey jar, sparks, a "!") stay in their frame.
use strings;
use viper;

type strip = struct {
	right: []viper::image,
	left: []viper::image, // mirrored copies
	top: int,             // first row with artwork, over all frames
	foot: int,            // last row with artwork (where the feet are)
};

fn no_strip() strip = strip { right = [], left = [], top = 0, foot = 0 };

// Loads assets/bines/<name>.png and scales every cell to px x px.
// Returns an empty strip if the file isn't there.
fn load_strip(name: str, px: int, mirrored: bool) strip = {
	const path = strings::concat("assets/bines/", name, ".png")!;
	defer free(path);
	let sheet = match (viper::load_png(path)) {
	case let img: viper::image => yield img;
	case viper::imgerror => return no_strip();
	};
	defer viper::image_free(&sheet);
	const cell = sheet.h;
	if (cell <= 0 || sheet.w < cell) return no_strip();
	let s = no_strip();
	s.top = px;
	for (let x = 0; x + cell <= sheet.w; x += cell) {
		let fr = viper::crop(&sheet, x, 0, cell, cell)!;
		defer viper::image_free(&fr);
		const img = viper::resize(&fr, px, px)!;
		for (let y = 0; y < px; y += 1) for (let i = 0; i < px; i += 1) {
			if (img.pixels[(y * px + i): size] >> 24 > 40) {
				if (y < s.top) s.top = y;
				if (y > s.foot) s.foot = y;
			};
		};
		append(s.right, img)!;
		if (mirrored) append(s.left, viper::mirror(&img)!)!;
	};
	return s;
};

// The frame to show t seconds into the animation at fps frames a second.
// once: play through and stay on the last frame; otherwise loop.
fn strip_frame(s: *strip, right: bool, t: f64, fps: f64, once: bool) nullable *viper::image = {
	const frames = if (right || len(s.left) == 0) s.right else s.left;
	if (len(frames) == 0) return null;
	let i = (if (t < 0.0) 0.0 else t * fps): size;
	i = if (once) (if (i >= len(frames)) len(frames) - 1 else i) else i % len(frames);
	return &frames[i];
};

// Blends col over a rectangle with alpha a (0-255); viper::rect paints
// solid. Respects the clip rectangle.
fn shade(win: *viper::window, x: int, y: int, w: int, h: int, col: u32, a: u32) void = {
	if (a == 0) return;
	if (a > 255) a = 255;
	const x0 = if (x < win.clip_x0) win.clip_x0 else x;
	const y0 = if (y < win.clip_y0) win.clip_y0 else y;
	const x1 = if (x + w > win.clip_x1) win.clip_x1 else x + w;
	const y1 = if (y + h > win.clip_y1) win.clip_y1 else y + h;
	const cr = (col >> 16) & 0xff, cg = (col >> 8) & 0xff, cb = col & 0xff;
	for (let yy = y0; yy < y1; yy += 1) for (let xx = x0; xx < x1; xx += 1) {
		let p = &win.pixels[(yy * win.width + xx): size];
		const r = ((*p >> 16) & 0xff) * (255 - a) + cr * a;
		const g = ((*p >> 8) & 0xff) * (255 - a) + cg * a;
		const b = (*p & 0xff) * (255 - a) + cb * a;
		*p = 0xff000000 | (r / 255) << 16 | (g / 255) << 8 | b / 255;
	};
};
