// ViperGui — gzip (RFC 1952) unpacking in memory, built on the same inflate
// the PNG decoder uses. Handy for .gz data files (Shifu's CPU tests use it).

// Unpacks a gzip file held in memory. The caller frees the result.
export fn gunzip(data: []u8) ([]u8 | badpng | nomem) = {
	if (len(data) < 18 || data[0] != 0x1f || data[1] != 0x8b) {
		return "not a gzip file": badpng;
	};
	if (data[2] != 8) return "unknown gzip compression": badpng;
	const flg = data[3];
	let p = 10z;
	if (flg & 4 != 0) { // FEXTRA
		if (p + 2 > len(data)) return "bad gzip header": badpng;
		p += 2 + (data[p]: size | data[p + 1]: size << 8);
	};
	if (flg & 8 != 0) { // FNAME
		for (p < len(data) && data[p] != 0) p += 1;
		p += 1;
	};
	if (flg & 16 != 0) { // FCOMMENT
		for (p < len(data) && data[p] != 0) p += 1;
		p += 1;
	};
	if (flg & 2 != 0) p += 2; // FHCRC
	if (p + 8 > len(data)) return "bad gzip header": badpng;

	// The last 4 bytes give the unpacked size (mod 4 GiB).
	const t = len(data) - 4;
	const n = data[t]: size | data[t + 1]: size << 8 |
		data[t + 2]: size << 16 | data[t + 3]: size << 24;
	let out: []u8 = alloc([0u8...], n)?;
	match (inflate(data[p..t - 4], out)) {
	case void => return out;
	case let e: badpng =>
		free(out);
		return e;
	};
};
