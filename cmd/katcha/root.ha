// The dangerous part. The window starts this same program again as root
// (via pkexec), with no window:
//
//   katcha --format /dev/sdb exfat LABEL STATUSFILE
//   katcha --iso    /dev/sdb FILE.iso    STATUSFILE
//
// It checks, as root, that the drive is a USB stick that holds no system
// mount point, and only then erases it. Progress goes to STATUSFILE as
// one line: RUN|DONE|ERR <tab> percent <tab> message.
use fmt;
use fs;
use io;
use os;
use strings;

// Runs a shell line when we do not care how it went.
fn quiet(script: str, a1: str, a2: str, a3: str, a4: str, a5: str) void = {
	if (!sh(script, a1, a2, a3, a4, a5)) return;
};

// Writes the status line. The file is given to the user who owns the
// folder, so the window (not root) can delete it later.
fn status(st: str, kind: str, pct: int, msg: str) void = {
	let pb: [8]u8 = [0...];
	quiet("printf '%s\\t%s\\t%s\\n' \"$2\" \"$3\" \"$4\" > \"$1.tmp\" "
		"&& chown --reference=\"$(dirname \"$1\")\" \"$1.tmp\"; mv \"$1.tmp\" \"$1\"",
		st, kind, fmt::bsprintf(pb, "{}", pct)!, msg, "");
};

fn fail(st: str, f: str, args: fmt::field...) never = {
	let b: [300]u8 = [0...];
	status(st, "ERR", 0, fmt::bsprintf(b, f, args...)!);
	os::exit(1);
};

// Runs a shell line; its errors go to "$4". On failure, stops with the
// last line it wrote.
fn root_run(st: str, what: str, script: str, a1: str, a2: str, a3: str) void = {
	let eb: [512]u8 = [0...];
	const errfile = fmt::bsprintf(eb, "{}.err", st)!;
	if (sh(script, a1, a2, a3, errfile, "")) return;
	let last = "";
	match (read_file(errfile)) {
	case let d: []u8 =>
		let end = len(d);
		for (end > 0 && (d[end - 1] == 10 || d[end - 1] == 32)) end -= 1;
		let start = end;
		for (start > 0 && d[start - 1] != 10) start -= 1;
		// d is not freed: we stop right after this anyway.
		last = strings::fromutf8_unsafe(d[start..end]);
	case void => void;
	};
	fail(st, "{} fejlede: {}", what, last);
};

fn root_check_name(st: str, dev: str) void = {
	// Only whole disks like /dev/sdb.
	if (!strings::hasprefix(dev, "/dev/sd") || len(dev) < 8 || len(dev) > 9) {
		fail(st, "{} er ikke et helt USB-drev.", dev);
	};
	for (let c .. strings::toutf8(dev)[7..]) {
		if (c < 97 || c > 122) fail(st, "{} er ikke et helt USB-drev.", dev);
	};
};

// Makes sure, again and as root, that dev is a USB stick we may erase.
// Returns it, with everything on it unmounted.
fn root_target(st: str, dev: str, d: *drive) void = {
	root_check_name(st, dev);
	if (os::getenv("PKEXEC_UID") is void) fail(st, "Skal startes med pkexec.");
	let lb: [512]u8 = [0...];
	const list = fmt::bsprintf(lb, "{}.lsblk", st)!;
	for (let round = 0; round < 2; round += 1) {
		if (!sh(LSBLK, list, "", "", "", "")) fail(st, "lsblk virker ikke.");
		const data = match (read_file(list)) {
		case let d: []u8 => yield d;
		case void => fail(st, "lsblk virker ikke.");
		};
		let found: [16]drive = [drive { ... }...];
		const n = usb_drives(data, found[..]);
		let ok = false;
		for (let i = 0z; i < n; i += 1) {
			if (found[i].path != dev) continue;
			ok = true;
			d.bytes = found[i].bytes;
			d.mounted = found[i].mounted;
		};
		if (!ok) fail(st, "{} er ikke et USB-stik, eller systemet bruger det. Intet er slettet.", dev);
		if (!d.mounted) return;
		if (round == 1) fail(st, "{} kunne ikke afmonteres. Intet er slettet.", dev);
		status(st, "RUN", 10, "Afmonterer...");
		quiet("for p in $(lsblk -nrpo NAME \"$1\"); do umount \"$p\" 2>/dev/null; done; true",
			dev, "", "", "", "");
	};
};

fn clean_label(buf: []u8, label: str, fs: str) str = {
	const max: size = if (fs == "fat32") 11 else if (fs == "exfat") 15 else 16;
	let n = 0z;
	for (let c .. strings::toutf8(label)) {
		if (n >= max) break;
		const ok = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
			|| c == 32 || c == 95 || c == 45;
		if (!ok) continue;
		buf[n] = if (fs == "fat32" && c >= 97 && c <= 122) c - 32 else c;
		n += 1;
	};
	if (n == 0) return "KATCHA";
	return strings::fromutf8_unsafe(buf[..n]);
};

fn root_format(dev: str, fs: str, label: str, st: str) void = {
	if (fs != "exfat" && fs != "fat32" && fs != "ext4") fail(st, "Ukendt filsystem: {}", fs);
	const tool = if (fs == "exfat") "mkfs.exfat" else if (fs == "fat32") "mkfs.fat" else "mkfs.ext4";
	if (!sh("command -v \"$1\" >/dev/null", tool, "", "", "", "")) {
		const pkg = if (fs == "exfat") "exfatprogs" else if (fs == "fat32") "dosfstools" else "e2fsprogs";
		fail(st, "{} mangler - installer pakken {}.", tool, pkg);
	};
	let lb: [32]u8 = [0...];
	const name = clean_label(lb, label, fs);

	status(st, "RUN", 5, "KATCHA tjekker drevet...");
	let d = drive { ... };
	root_target(st, dev, &d);

	status(st, "RUN", 25, "Sletter de gamle filsystemer...");
	root_run(st, "wipefs", "wipefs -a \"$1\" >/dev/null 2>\"$4\"", dev, "", "");

	status(st, "RUN", 40, "Laver en ny partitionstabel...");
	const kind = if (fs == "exfat") "7" else if (fs == "fat32") "c" else "83";
	root_run(st, "sfdisk",
		"printf 'label: dos\\n,,%s\\n' \"$2\" | sfdisk --wipe always \"$1\" >/dev/null 2>\"$4\"",
		dev, kind, "");
	root_run(st, "Partitionen",
		"partprobe \"$1\" 2>/dev/null; udevadm settle 2>/dev/null; "
		"for i in $(seq 50); do [ -b \"${1}1\" ] && exit 0; sleep 0.1; done; "
		"echo \"${1}1 dukkede ikke op\" >\"$4\"; exit 1", dev, "", "");

	let pb: [16]u8 = [0...];
	const part = fmt::bsprintf(pb, "{}1", dev)!;
	let mb: [64]u8 = [0...];
	status(st, "RUN", 65, fmt::bsprintf(mb, "FORMAT QUEEN laver {}...", fs)!);
	if (fs == "exfat") {
		root_run(st, "mkfs.exfat", "mkfs.exfat -n \"$2\" \"$1\" >/dev/null 2>\"$4\"", part, name, "");
	} else if (fs == "fat32") {
		root_run(st, "mkfs.fat", "mkfs.fat -F 32 -n \"$2\" \"$1\" >/dev/null 2>\"$4\"", part, name, "");
	} else {
		root_run(st, "mkfs.ext4", "mkfs.ext4 -F -L \"$2\" \"$1\" >/dev/null 2>\"$4\"", part, name, "");
		// Let the user write to the new stick without sudo.
		quiet("m=$(mktemp -d) && mount \"$1\" \"$m\" && chown \"$PKEXEC_UID:$PKEXEC_UID\" \"$m\"; "
			"umount \"$m\" 2>/dev/null; rmdir \"$m\"", part, "", "", "", "");
	};
	status(st, "RUN", 90, "Gemmer alt på stikket...");
	quiet("sync", "", "", "", "", "");
	let db: [200]u8 = [0...];
	status(st, "DONE", 100, fmt::bsprintf(db, "{} er nu {} med navnet {}. HAAAAHAHAHA!!", dev, fs, name)!);
};

fn root_iso(dev: str, iso: str, st: str) void = {
	const total = match (os::stat(iso)) {
	case let s: fs::filestat => yield s.sz: u64;
	case => fail(st, "Kan ikke finde ISO-filen: {}", iso);
	};
	if (total == 0) fail(st, "ISO-filen er tom.");
	status(st, "RUN", 1, "KATCHA tjekker drevet...");
	let d = drive { ... };
	root_target(st, dev, &d);
	if (total > d.bytes) fail(st, "ISO-filen er større end USB-stikket.");
	root_run(st, "wipefs", "wipefs -a \"$1\" >/dev/null 2>\"$4\"", dev, "", "");

	const src = match (os::open(iso)) {
	case let f: io::file => yield f;
	case => fail(st, "Kan ikke åbne ISO-filen.");
	};
	// SYNC: every write really reaches the stick, so the progress is true.
	const dst = match (os::open(dev, fs::flag::WRONLY | fs::flag::SYNC)) {
	case let f: io::file => yield f;
	case => fail(st, "Kan ikke åbne {}.", dev);
	};
	let buf: []u8 = alloc([0...], 4 * 1024 * 1024)!;
	let written = 0u64, report = 0u64;
	for (true) {
		const n = match (io::read(src, buf)) {
		case let n: size => yield n;
		case io::EOF => break;
		case => fail(st, "Kan ikke læse ISO-filen.");
		};
		match (io::writeall(dst, buf[..n])) {
		case size => void;
		case => fail(st, "Skrivningen til {} fejlede.", dev);
		};
		written += n: u64;
		if (written >= report) {
			report = written + 32 * 1048576;
			let mb: [96]u8 = [0...];
			status(st, "RUN", (written * 97 / total): int,
				fmt::bsprintf(mb, "BOOTY ISO skriver... {} / {} MB",
					written / 1048576, total / 1048576)!);
		};
	};
	free(buf);
	io::close(src)!;
	io::close(dst)!;
	status(st, "RUN", 98, "Gemmer de sidste bytes...");
	quiet("sync", "", "", "", "", "");
	let db: [300]u8 = [0...];
	const base = match (strings::rindex(iso, '/')) {
	case let i: size => yield strings::sub(iso, i + 1, strings::end);
	case void => yield iso;
	};
	status(st, "DONE", 100, fmt::bsprintf(db, "{} er skrevet til {}. Klar til boot! HAAAAHAHAHA!!", base, dev)!);
};

// Runs the root part when the program was started with --format or --iso.
fn root_main(args: []str) void = {
	if (len(args) == 5 && args[0] == "--format") {
		root_format(args[1], args[2], args[3], args[4]);
	} else if (len(args) == 4 && args[0] == "--iso") {
		root_iso(args[1], args[2], args[3]);
	} else {
		fmt::errorln("Brug: katcha --format DEV FS NAVN STATUS | katcha --iso DEV ISO STATUS")!;
		os::exit(1);
	};
};
