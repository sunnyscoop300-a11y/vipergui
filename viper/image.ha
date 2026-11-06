// ViperGui — images: a PNG decoder written in pure Hare (including its own
// DEFLATE/inflate), box-filter resizing and alpha-blended drawing.
use endian;
use io;
use os;

// An image in 0xAARRGGBB pixels (straight, not premultiplied, alpha).
export type image = struct {
	w: int,
	h: int,
	pixels: []u32,
};

// The file is not a PNG this decoder understands.
export type badpng = !str;

// Anything that can go wrong while loading an image.
export type imgerror = !(badpng | io::error | fs_error | nomem);

// Wrapper so file errors can travel through [[imgerror]].
export type fs_error = !str;

// Returns a human-readable message for an [[imgerror]].
export fn imgstrerror(err: imgerror) str = {
	match (err) {
	case let b: badpng =>
		return b;
	case let e: io::error =>
		return io::strerror(e);
	case let f: fs_error =>
		return f;
	case nomem =>
		return "out of memory";
	};
};

// Frees an image's pixels.
export fn image_free(img: *image) void = {
	free(img.pixels);
	img.pixels = [];
};

// Loads a PNG file. 8-bit and 16-bit grey, RGB, palette and alpha images are
// supported (no interlacing), which covers what image generators produce.
export fn load_png(path: str) (image | imgerror) = {
	const f = match (os::open(path)) {
	case let f: io::file =>
		yield f;
	case =>
		return path: fs_error;
	};
	defer io::close(f)!;
	const data = io::drain(f)?;
	defer free(data);
	return decode_png(data);
};

// Decodes PNG data that is already in memory.
export fn decode_png(data: []u8) (image | imgerror) = {
	const sig: [8]u8 = [0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'];
	if (len(data) < 8 || !bytes_eq(data[..8], sig)) {
		return "not a PNG file": badpng;
	};

	let w = 0u32, h = 0u32;
	let depth = 0u8, ctype = 0u8;
	let palette: [256]u32 = [0xff000000...];
	let idat: []u8 = [];
	defer free(idat);

	let pos = 8z;
	for (pos + 12 <= len(data)) {
		const n = endian::begetu32(data[pos..pos + 4]): size;
		const kind = data[pos + 4..pos + 8];
		if (pos + 12 + n > len(data)) return "truncated chunk": badpng;
		const body = data[pos + 8..pos + 8 + n];
		pos += 12 + n;

		if (bytes_eq(kind, ['I', 'H', 'D', 'R'])) {
			w = endian::begetu32(body[0..4]);
			h = endian::begetu32(body[4..8]);
			depth = body[8];
			ctype = body[9];
			if (body[12] != 0) return "interlaced PNGs are not supported": badpng;
		} else if (bytes_eq(kind, ['P', 'L', 'T', 'E'])) {
			for (let i = 0z; i + 2 < n && i / 3 < 256; i += 3) {
				palette[i / 3] = 0xff000000 | (body[i]: u32 << 16)
					| (body[i + 1]: u32 << 8) | body[i + 2]: u32;
			};
		} else if (bytes_eq(kind, ['t', 'R', 'N', 'S']) && ctype == 3) {
			for (let i = 0z; i < n && i < 256; i += 1) {
				palette[i] = (palette[i] & 0x00ffffff) | (body[i]: u32 << 24);
			};
		} else if (bytes_eq(kind, ['I', 'D', 'A', 'T'])) {
			append(idat, body...)?;
		} else if (bytes_eq(kind, ['I', 'E', 'N', 'D'])) {
			break;
		};
	};
	if (w == 0 || h == 0) return "missing IHDR": badpng;

	const channels: size = switch (ctype) {
	case 0 => yield 1;  // grey
	case 2 => yield 3;  // RGB
	case 3 => yield 1;  // palette
	case 4 => yield 2;  // grey + alpha
	case 6 => yield 4;  // RGBA
	case => return "unknown color type": badpng;
	};
	if (depth != 8 && !(depth == 16 && ctype != 3)) {
		return "only 8/16-bit PNGs are supported": badpng;
	};
	const bpp = channels * depth: size / 8;
	const stride = w: size * bpp;

	// zlib wrapper: 2-byte header, then raw DEFLATE.
	if (len(idat) < 2 || idat[0] & 0x0f != 8) return "bad zlib header": badpng;
	let raw: []u8 = alloc([0u8...], (stride + 1) * h: size)?;
	defer free(raw);
	inflate(idat[2..], raw)?;

	// Undo the per-row filters in place.
	let prev = 0z;
	for (let y = 0z; y < h: size; y += 1) {
		const row = y * (stride + 1);
		const ft = raw[row];
		const cur = row + 1;
		for (let i = 0z; i < stride; i += 1) {
			const a: u8 = if (i >= bpp) raw[cur + i - bpp] else 0;
			const b: u8 = if (y > 0) raw[prev + i] else 0;
			const c: u8 = if (y > 0 && i >= bpp) raw[prev + i - bpp] else 0;
			const add: u8 = switch (ft) {
			case 0 => yield 0;
			case 1 => yield a;
			case 2 => yield b;
			case 3 => yield ((a: uint + b: uint) / 2): u8;
			case 4 => yield paeth(a, b, c);
			case => return "bad filter type": badpng;
			};
			raw[cur + i] += add;
		};
		prev = cur;
	};

	// Convert to 0xAARRGGBB.
	let px: []u32 = alloc([0u32...], w: size * h: size)?;
	const step = depth: size / 8; // bytes per channel; we keep the high byte
	for (let y = 0z; y < h: size; y += 1) {
		const row = y * (stride + 1) + 1;
		for (let x = 0z; x < w: size; x += 1) {
			const p = row + x * bpp;
			px[y * w: size + x] = switch (ctype) {
			case 0 =>
				const g = chan(raw, p, step, 0);
				yield 0xff000000 | (g << 16) | (g << 8) | g;
			case 2 =>
				yield 0xff000000 | (chan(raw, p, step, 0) << 16)
					| (chan(raw, p, step, 1) << 8) | chan(raw, p, step, 2);
			case 3 =>
				yield palette[raw[p]];
			case 4 =>
				const g = chan(raw, p, step, 0);
				yield (chan(raw, p, step, 1) << 24) | (g << 16) | (g << 8) | g;
			case =>
				yield (chan(raw, p, step, 3) << 24)
					| (chan(raw, p, step, 0) << 16)
					| (chan(raw, p, step, 1) << 8) | chan(raw, p, step, 2);
			};
		};
	};
	return image { w = w: int, h = h: int, pixels = px };
};

// Channel i of the pixel at p; for 16-bit images the high byte is used.
fn chan(raw: []u8, p: size, step: size, i: size) u32 = raw[p + i * step]: u32;

fn paeth(a: u8, b: u8, c: u8) u8 = {
	const p = a: int + b: int - c: int;
	const pa = if (p > a: int) p - a: int else a: int - p;
	const pb = if (p > b: int) p - b: int else b: int - p;
	const pc = if (p > c: int) p - c: int else c: int - p;
	if (pa <= pb && pa <= pc) return a;
	if (pb <= pc) return b;
	return c;
};

fn bytes_eq(a: []u8, b: []u8) bool = {
	if (len(a) != len(b)) return false;
	for (let i = 0z; i < len(a); i += 1) {
		if (a[i] != b[i]) return false;
	};
	return true;
};

// ---- DEFLATE (RFC 1951) ----

type bitreader = struct {
	data: []u8,
	pos: size,
	buf: u32,
	cnt: u32,
};

fn getbits(br: *bitreader, n: u32) (u32 | badpng) = {
	for (br.cnt < n) {
		if (br.pos >= len(br.data)) return "unexpected end of data": badpng;
		br.buf |= br.data[br.pos]: u32 << br.cnt;
		br.pos += 1;
		br.cnt += 8;
	};
	const v = br.buf & ((1u32 << n) - 1);
	br.buf >>= n;
	br.cnt -= n;
	return v;
};

// Canonical Huffman table (as in zlib's "puff").
type huffman = struct {
	counts: [16]u16,
	symbols: [288]u16,
};

fn build(h: *huffman, lengths: []u8) void = {
	h.counts = [0...];
	for (let l .. lengths) h.counts[l] += 1;
	h.counts[0] = 0;
	let offs: [16]u16 = [0...];
	for (let i = 1z; i < 15; i += 1) {
		offs[i + 1] = offs[i] + h.counts[i];
	};
	for (let sym = 0z; sym < len(lengths); sym += 1) {
		const l = lengths[sym];
		if (l != 0) {
			h.symbols[offs[l]] = sym: u16;
			offs[l] += 1;
		};
	};
};

fn decode(br: *bitreader, h: *huffman) (u16 | badpng) = {
	let code = 0i32, first = 0i32, index = 0i32;
	for (let l = 1z; l < 16; l += 1) {
		code |= getbits(br, 1)?: i32;
		const count = h.counts[l]: i32;
		if (code - first < count) {
			return h.symbols[(index + code - first): size];
		};
		index += count;
		first += count;
		first <<= 1;
		code <<= 1;
	};
	return "bad Huffman code": badpng;
};

const lbase: [29]u16 = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
	35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
const lext: [29]u8 = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
	3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
const dbase: [30]u16 = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129,
	193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193,
	12289, 16385, 24577];
const dext: [30]u8 = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
	7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];

// Inflates raw DEFLATE data into out, which must be exactly the right size
// (PNG tells us the decompressed size up front).
fn inflate(data: []u8, out: []u8) (void | badpng) = {
	let br = bitreader { data = data, ... };
	let o = 0z;
	let lit = huffman { ... }, dist = huffman { ... };

	for (true) {
		const final = getbits(&br, 1)?;
		const kind = getbits(&br, 2)?;
		switch (kind) {
		case 0 =>
			// Stored block: skip to a byte boundary.
			br.buf = 0;
			br.cnt = 0;
			if (br.pos + 4 > len(data)) return "truncated stored block": badpng;
			const n = data[br.pos]: size | (data[br.pos + 1]: size << 8);
			br.pos += 4;
			if (br.pos + n > len(data) || o + n > len(out)) {
				return "bad stored block": badpng;
			};
			out[o..o + n] = data[br.pos..br.pos + n];
			o += n;
			br.pos += n;
			if (final == 1) break;
			continue;
		case 1 =>
			let lens: [288]u8 = [0...];
			for (let i = 0z; i < 144; i += 1) lens[i] = 8;
			for (let i = 144z; i < 256; i += 1) lens[i] = 9;
			for (let i = 256z; i < 280; i += 1) lens[i] = 7;
			for (let i = 280z; i < 288; i += 1) lens[i] = 8;
			build(&lit, lens);
			let dl: [30]u8 = [5...];
			build(&dist, dl);
		case 2 =>
			const nlit = getbits(&br, 5)?: size + 257;
			const ndist = getbits(&br, 5)?: size + 1;
			const ncode = getbits(&br, 4)?: size + 4;
			const order: [19]u8 = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5,
				11, 4, 12, 3, 13, 2, 14, 1, 15];
			let cl: [19]u8 = [0...];
			for (let i = 0z; i < ncode; i += 1) {
				cl[order[i]] = getbits(&br, 3)?: u8;
			};
			let clh = huffman { ... };
			build(&clh, cl);

			let lens: [320]u8 = [0...];
			let i = 0z;
			for (i < nlit + ndist) {
				const sym = decode(&br, &clh)?;
				if (sym < 16) {
					lens[i] = sym: u8;
					i += 1;
					continue;
				};
				let rep = 0z, val = 0u8;
				switch (sym) {
				case 16 =>
					if (i == 0) return "bad repeat": badpng;
					val = lens[i - 1];
					rep = 3 + getbits(&br, 2)?: size;
				case 17 =>
					rep = 3 + getbits(&br, 3)?: size;
				case =>
					rep = 11 + getbits(&br, 7)?: size;
				};
				if (i + rep > nlit + ndist) return "bad lengths": badpng;
				for (let k = 0z; k < rep; k += 1) {
					lens[i] = val;
					i += 1;
				};
			};
			build(&lit, lens[..nlit]);
			build(&dist, lens[nlit..nlit + ndist]);
		case =>
			return "bad block type": badpng;
		};

		// Huffman-coded block body.
		for (true) {
			const sym = decode(&br, &lit)?;
			if (sym < 256) {
				if (o >= len(out)) return "too much data": badpng;
				out[o] = sym: u8;
				o += 1;
			} else if (sym == 256) {
				break;
			} else {
				const li = (sym - 257): size;
				if (li >= 29) return "bad length code": badpng;
				const n = lbase[li]: size + getbits(&br, lext[li])?: size;
				const di = decode(&br, &dist)?: size;
				if (di >= 30) return "bad distance code": badpng;
				const d = dbase[di]: size + getbits(&br, dext[di])?: size;
				if (d > o || o + n > len(out)) return "bad distance": badpng;
				for (let k = 0z; k < n; k += 1) {
					out[o] = out[o - d];
					o += 1;
				};
			};
		};
		if (final == 1) break;
	};
	if (o != len(out)) return "image data too short": badpng;
};

// ---- Resizing and drawing ----

// Returns a new image scaled to w x h. Downscaling averages every source
// pixel (box filter), so big AI-generated sprites stay smooth.
export fn resize(src: *image, w: int, h: int) (image | nomem) = {
	let px: []u32 = alloc([0u32...], (w * h): size)?;
	for (let y = 0; y < h; y += 1) {
		const sy0 = y * src.h / h;
		let sy1 = (y + 1) * src.h / h;
		if (sy1 <= sy0) sy1 = sy0 + 1;
		for (let x = 0; x < w; x += 1) {
			const sx0 = x * src.w / w;
			let sx1 = (x + 1) * src.w / w;
			if (sx1 <= sx0) sx1 = sx0 + 1;
			// Average with alpha weighting so edges don't get dark halos.
			let a = 0u64, r = 0u64, g = 0u64, b = 0u64, n = 0u64;
			for (let sy = sy0; sy < sy1; sy += 1) {
				for (let sx = sx0; sx < sx1; sx += 1) {
					const p = src.pixels[(sy * src.w + sx): size];
					const pa = (p >> 24): u64;
					a += pa;
					r += ((p >> 16) & 0xff): u64 * pa;
					g += ((p >> 8) & 0xff): u64 * pa;
					b += (p & 0xff): u64 * pa;
					n += 1;
				};
			};
			px[(y * w + x): size] = if (a == 0) 0 else
				((a / n): u32 << 24) | ((r / a): u32 << 16)
				| ((g / a): u32 << 8) | (b / a): u32;
		};
	};
	return image { w = w, h = h, pixels = px };
};

// Draws an image at x, y with alpha blending (respects [[clip]]).
export fn draw_image(win: *window, img: *image, x: int, y: int) void = {
	const x0 = if (x < win.clip_x0) win.clip_x0 else x;
	const y0 = if (y < win.clip_y0) win.clip_y0 else y;
	const x1 = if (x + img.w > win.clip_x1) win.clip_x1 else x + img.w;
	const y1 = if (y + img.h > win.clip_y1) win.clip_y1 else y + img.h;
	for (let yy = y0; yy < y1; yy += 1) {
		const srow = (yy - y) * img.w - x;
		const drow = yy * win.width;
		for (let xx = x0; xx < x1; xx += 1) {
			const s = img.pixels[(srow + xx): size];
			const a = s >> 24;
			if (a == 0) continue;
			const di = (drow + xx): size;
			if (a == 255) {
				win.pixels[di] = s;
				continue;
			};
			const d = win.pixels[di];
			const ia = 255 - a;
			const r = (((s >> 16) & 0xff) * a + ((d >> 16) & 0xff) * ia) / 255;
			const g = (((s >> 8) & 0xff) * a + ((d >> 8) & 0xff) * ia) / 255;
			const b = ((s & 0xff) * a + (d & 0xff) * ia) / 255;
			win.pixels[di] = 0xff000000 | (r << 16) | (g << 8) | b;
		};
	};
};

// Returns a copy of the w x h area at x, y. Parts outside the source image
// become transparent.
export fn crop(src: *image, x: int, y: int, w: int, h: int) (image | nomem) = {
	let px: []u32 = alloc([0u32...], (w * h): size)?;
	for (let yy = 0; yy < h; yy += 1) {
		const sy = y + yy;
		if (sy < 0 || sy >= src.h) continue;
		for (let xx = 0; xx < w; xx += 1) {
			const sx = x + xx;
			if (sx < 0 || sx >= src.w) continue;
			px[(yy * w + xx): size] = src.pixels[(sy * src.w + sx): size];
		};
	};
	return image { w = w, h = h, pixels = px };
};

// Sets the window's icon (title bar, task bar). Every window starts with the
// ViperGui snake; call this to use your app's own icon instead.
export fn set_icon(win: *window, img: *image) void = {
	if (len(img.pixels) == 0) return;
	match (win.be) {
	case let be: *sdl_backend => sdl_icon(be, img);
	// Wayland compositors take the icon from the .desktop file that
	// matches the window's app id (the program name; see `make desktop`).
	case *wl_backend => void;
	};
};

fn set_default_icon(win: *window) void = {
	match (decode_png(icon_png)) {
	case let img: image =>
		set_icon(win, &img);
		image_free(&img);
	case imgerror => void;
	};
};

// Splits a sprite sheet into frames. Frames sit side by side, separated by
// fully transparent columns (as image generators usually produce them).
// Every frame gets the same box, so a character doesn't jump between
// frames, and is scaled to fit inside max_w x max_h. Free each frame with
// [[image_free]] and the slice with free().
export fn split_sheet(sheet: *image, max_w: int, max_h: int) ([]image | nomem) = {
	// Visible column runs, and the overall top/bottom of the artwork.
	let runs: [](int, int) = [];
	defer free(runs);
	let top = sheet.h, bottom = -1, start = -1;
	for (let x = 0; x <= sheet.w; x += 1) {
		let used = false;
		if (x < sheet.w) {
			for (let y = 0; y < sheet.h; y += 1) {
				if (sheet.pixels[(y * sheet.w + x): size] >> 24 > 20) {
					used = true;
					if (y < top) top = y;
					if (y > bottom) bottom = y;
				};
			};
		};
		if (used && start < 0) start = x;
		if (!used && start >= 0) {
			// Ignore specks narrower than 4 px (stray anti-aliasing).
			if (x - start >= 4) append(runs, (start, x))?;
			start = -1;
		};
	};
	let frames: []image = [];
	if (len(runs) == 0) return frames;

	let bw = 0;
	for (let r .. runs) if (r.1 - r.0 > bw) bw = r.1 - r.0;
	const bh = bottom - top + 1;
	// Fit the shared box into max_w x max_h, keeping the aspect ratio.
	let w = max_w, h = max_w * bh / bw;
	if (h > max_h) {
		h = max_h;
		w = max_h * bw / bh;
	};
	for (let r .. runs) {
		const cx = (r.0 + r.1) / 2;
		let fr = crop(sheet, cx - bw / 2, top, bw, bh)?;
		defer image_free(&fr);
		append(frames, resize(&fr, w, h)?)?;
	};
	return frames;
};

// Returns a horizontally mirrored copy (a sprite facing the other way).
export fn mirror(src: *image) (image | nomem) = {
	let px: []u32 = alloc([0u32...], len(src.pixels))?;
	for (let y = 0; y < src.h; y += 1) {
		const row = (y * src.w): size;
		for (let x = 0; x < src.w; x += 1) {
			px[row + (src.w - 1 - x): size] = src.pixels[row + x: size];
		};
	};
	return image { w = src.w, h = src.h, pixels = px };
};
