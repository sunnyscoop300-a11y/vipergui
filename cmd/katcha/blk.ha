// Finding USB sticks with lsblk, and telling them apart from system disks.
// Both the window and the root part use this.
use fmt;
use strings;

// Mount points that mean "this is a system disk, hands off".
const SYSTEM: [_]str = ["/", "/boot", "/boot/efi", "/efi", "/home", "/usr",
	"/var", "/opt", "/srv", "/nix", "[SWAP]"];

def MAX_BYTES: u64 = 256000000000;     // 256 GB: hides USB hard disks with data
def MAXBLK: size = 64;

const LSBLK: str = "lsblk -P -b -o NAME,PATH,SIZE,TYPE,TRAN,PKNAME,FSTYPE,LABEL,VENDOR,MODEL,MOUNTPOINT > \"$1\"";

// One line of lsblk -P: a disk or a partition.
type blk = struct {
	name: str,
	path: str,
	bytes: u64,
	kind: str,             // disk, part, ...
	tran: str,             // usb, sata, nvme, ...
	parent: str,           // the disk a partition belongs to
	fstype: str,
	label: str,
	vendor: str,
	model: str,
	mount: str,
};

type drive = struct {
	name: str,             // sdb
	path: str,             // /dev/sdb
	bytes: u64,
	model: str,
	parts: str,            // what is on it now
	mounted: bool,
	modelbuf: [96]u8,
	partsbuf: [128]u8,
};

fn to_int(s: str) u64 = {
	let n = 0u64;
	for (let c .. strings::toutf8(s)) {
		if (c >= 48 && c <= 57) n = n * 10 + (c - 48): u64;
	};
	return n;
};

// Reads KEY="value" KEY="value" ... into b.
fn parse_blk(line: []u8, b: *blk) void = {
	*b = blk { ... };
	let i = 0z;
	for (i < len(line)) {
		for (i < len(line) && line[i] == 32) i += 1;
		const k0 = i;
		for (i < len(line) && line[i] != 61) i += 1;      // =
		const key = strings::fromutf8_unsafe(line[k0..i]);
		i += 2;                                           // ="
		if (i > len(line)) break;
		const v0 = i;
		for (i < len(line) && line[i] != 34) i += 1;      // "
		const val = strings::fromutf8_unsafe(line[v0..i]);
		i += 1;
		if (key == "NAME") b.name = val
		else if (key == "PATH") b.path = val
		else if (key == "SIZE") b.bytes = to_int(val)
		else if (key == "TYPE") b.kind = val
		else if (key == "TRAN") b.tran = val
		else if (key == "PKNAME") b.parent = val
		else if (key == "FSTYPE") b.fstype = val
		else if (key == "LABEL") b.label = val
		else if (key == "VENDOR") b.vendor = strings::trim(val)
		else if (key == "MODEL") b.model = strings::trim(val)
		else if (key == "MOUNTPOINT") b.mount = val;
	};
};

fn is_system(mount: str) bool = {
	for (let m .. SYSTEM) {
		if (mount == m) return true;
	};
	return false;
};

// Turns lsblk's output into the list of USB sticks we may touch.
// The strings in out point into data, so keep data alive.
fn usb_drives(data: []u8, out: []drive) size = {
	let blks: [MAXBLK]blk = [blk { ... }...];
	let nb = 0z, start = 0z;
	for (let i = 0z; i <= len(data) && nb < MAXBLK; i += 1) {
		if (i < len(data) && data[i] != 10) continue;
		if (i > start) {
			parse_blk(data[start..i], &blks[nb]);
			nb += 1;
		};
		start = i + 1;
	};

	let n = 0z;
	for (let k = 0z; k < nb && n < len(out); k += 1) {
		const d = &blks[k];
		// Only whole disks on the USB bus. (Removable or hot-plug flags
		// are not enough: hot-swap SATA disks have them too.)
		if (d.kind != "disk" || d.tran != "usb") continue;
		if (!strings::hasprefix(d.name, "sd")) continue;
		if (d.bytes == 0 || d.bytes > MAX_BYTES) continue;

		let system = is_system(d.mount);
		let mounted = len(d.mount) > 0;
		let o = &out[n];
		let pn = 0z;
		for (let j = 0z; j < nb; j += 1) {
			const p = &blks[j];
			if (p.parent != d.name) continue;
			if (is_system(p.mount)) system = true;
			if (len(p.mount) > 0) mounted = true;
			let what = if (len(p.fstype) > 0) p.fstype else "ukendt";
			let pb: [64]u8 = [0...];
			if (len(p.label) > 0) what = fmt::bsprintf(pb, "{} {}", what, p.label)!;
			const sep = if (pn == 0) "" else ", ";
			const before = strings::fromutf8_unsafe(o.partsbuf[..pn]);
			let tmp: [128]u8 = [0...];
			const joined = match (fmt::bsprintf(tmp, "{}{}{}", before, sep, what)) {
			case let s: str => yield s;
			case => continue;
			};
			const b = strings::toutf8(joined);
			o.partsbuf[..len(b)] = b;
			pn = len(b);
		};
		if (system) continue;

		o.name = d.name;
		o.path = d.path;
		o.bytes = d.bytes;
		o.mounted = mounted;
		o.parts = if (pn == 0) "tom" else strings::fromutf8_unsafe(o.partsbuf[..pn]);
		const m = if (len(d.vendor) > 0 && len(d.model) > 0)
				fmt::bsprintf(o.modelbuf, "{} {}", d.vendor, d.model)
			else if (len(d.model) > 0) fmt::bsprintf(o.modelbuf, "{}", d.model)
			else fmt::bsprintf(o.modelbuf, "USB-drev");
		o.model = match (m) {
		case let s: str => yield s;
		case => yield "USB-drev";
		};
		n += 1;
	};
	return n;
};
