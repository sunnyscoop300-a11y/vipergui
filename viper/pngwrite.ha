// ViperGui — saving pictures as PNG.
//
// The picture data is stored without compression (deflate "stored" blocks),
// so the files are bigger than usual, but any program can read them and no
// extra library is needed.
use fs;
use io;
use os;
use strings;

let crc_table: [256]u32 = [0...];
let crc_ready: bool = false;

fn crc_init() void = {
	for (let n = 0u32; n < 256; n += 1) {
		let c = n;
		for (let k = 0; k < 8; k += 1) {
			c = if (c & 1 != 0) 0xedb88320 ^ (c >> 1) else c >> 1;
		};
		crc_table[n: size] = c;
	};
	crc_ready = true;
};

fn crc_update(c: u32, data: []u8) u32 = {
	if (!crc_ready) crc_init();
	let v = c;
	for (let b .. data) {
		v = crc_table[((v ^ b: u32) & 0xff): size] ^ (v >> 8);
	};
	return v;
};

// Writes v as 4 bytes, most significant first (PNG's byte order).
fn put32(buf: []u8, v: u32) void = {
	buf[0] = (v >> 24): u8;
	buf[1] = (v >> 16): u8;
	buf[2] = (v >> 8): u8;
	buf[3] = v: u8;
};

// One PNG chunk: length, type, data and a checksum.
fn png_chunk(f: io::handle, kind: str, data: []u8) (void | io::error) = {
	let hdr: [8]u8 = [0...];
	put32(hdr[..4], len(data): u32);
	hdr[4..8] = strings::toutf8(kind);
	io::writeall(f, hdr)?;
	io::writeall(f, data)?;
	let c = crc_update(0xffffffff, hdr[4..8]);
	c = crc_update(c, data);
	let tail: [4]u8 = [0...];
	put32(tail, c ^ 0xffffffff);
	io::writeall(f, tail)?;
};

// Saves a picture as a PNG file (RGBA, 8 bits per channel).
export fn save_png(img: *image, path: str) (void | fs::error | io::error | nomem) = {
	const w = img.w: size, h = img.h: size;
	const rowlen = 1 + 4 * w;
	const n = h * rowlen;

	// The raw rows: a filter byte (0 = none) and then R, G, B, A per pixel.
	let raw: []u8 = alloc([0u8...], n)?;
	defer free(raw);
	for (let y = 0z; y < h; y += 1) {
		const o = y * rowlen;
		raw[o] = 0;
		for (let x = 0z; x < w; x += 1) {
			const p = img.pixels[y * w + x];
			const q = o + 1 + 4 * x;
			raw[q] = (p >> 16): u8;
			raw[q + 1] = (p >> 8): u8;
			raw[q + 2] = p: u8;
			raw[q + 3] = (p >> 24): u8;
		};
	};

	// A zlib stream made of stored (uncompressed) deflate blocks.
	const nblocks = if (n == 0) 1z else (n + 65534) / 65535;
	let z: []u8 = alloc([0u8...], 2 + nblocks * 5 + n + 4)?;
	defer free(z);
	z[0] = 0x78;
	z[1] = 0x01;
	let zp = 2z, rp = 0z;
	for (let b = 0z; b < nblocks; b += 1) {
		const blen = if (n - rp > 65535) 65535z else n - rp;
		z[zp] = if (b == nblocks - 1) 1 else 0;
		z[zp + 1] = blen: u8;
		z[zp + 2] = (blen >> 8): u8;
		z[zp + 3] = (~blen): u8;
		z[zp + 4] = (~blen >> 8): u8;
		zp += 5;
		z[zp..zp + blen] = raw[rp..rp + blen];
		zp += blen;
		rp += blen;
	};
	// Adler-32 checksum of the raw data ends the zlib stream.
	let s1 = 1u32, s2 = 0u32;
	for (let c .. raw) {
		s1 = (s1 + c: u32) % 65521;
		s2 = (s2 + s1) % 65521;
	};
	put32(z[zp..zp + 4], (s2 << 16) | s1);

	const f = os::create(path, 0o644)?;
	defer io::close(f)!;
	const sig: [8]u8 = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
	io::writeall(f, sig)?;
	let ihdr: [13]u8 = [0...];
	put32(ihdr[0..4], w: u32);
	put32(ihdr[4..8], h: u32);
	ihdr[8] = 8;    // 8 bits per channel
	ihdr[9] = 6;    // RGBA
	png_chunk(f, "IHDR", ihdr)?;
	png_chunk(f, "IDAT", z)?;
	png_chunk(f, "IEND", ihdr[..0])?;
};
