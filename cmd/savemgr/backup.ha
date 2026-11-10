// HPO STEAM SAVE MANAGER — backups: copying save folders with a SHA-256 of
// every file, the history, checking a backup, and restoring one.
use crypto::sha256;
use encoding::hex;
use fmt;
use fs;
use hash;
use io;
use memio;
use os;
use sort;
use strconv;
use strings;

type backup = struct {
	stamp: str,      // its folder name, "2026-11-07_18-42-05"
	when: i64,
	version: int,
	sz: u64,
	files: size,
	note: str,
	machine: str,    // the PC it was made on ("" for old backups)
};

fn free_backups(bs: []backup) void = {
	for (let b .. bs) {
		free(b.stamp);
		free(b.note);
		free(b.machine);
	};
	free(bs);
};

// The files under root, as paths relative to it.
fn walk(root: str, rel: str, out: *[]str) (void | fs::error | nomem) = {
	const dir = if (len(rel) == 0) strings::dup(root)! else strings::concat(root, "/", rel)!;
	defer free(dir);
	const ents = os::readdir(dir)?;
	defer fs::dirents_free(ents);
	for (let e .. ents) {
		const r = if (len(rel) == 0) strings::dup(e.name)! else strings::concat(rel, "/", e.name)!;
		if (fs::isdir(e.ftype)) {
			walk(root, r, out)?;
			free(r);
		} else if (fs::isfile(e.ftype)) {
			append(out, r)!;
		} else {
			free(r);
		};
	};
};

// Copies a file and hashes it on the way. Returns its size and SHA-256.
fn copy_hashed(src: str, dst: str) ((u64, [sha256::SZ]u8) | fs::error | io::error) = {
	const in = os::open(src)?;
	defer io::close(in)!;
	const out = os::create(dst, 0o644)?;
	defer io::close(out)!;
	let h = sha256::sha256();
	let buf: [65536]u8 = [0...];
	let n = 0u64;
	for (true) {
		match (io::read(in, buf)?) {
		case let k: size =>
			io::writeall(out, buf[..k])?;
			hash::write(&h, buf[..k]);
			n += k;
		case io::EOF => break;
		};
	};
	let sum: [sha256::SZ]u8 = [0...];
	hash::sum(&h, sum);
	return (n, sum);
};

fn hash_file(p: str) ((u64, [sha256::SZ]u8) | fs::error | io::error) = {
	const in = os::open(p)?;
	defer io::close(in)!;
	let h = sha256::sha256();
	let buf: [65536]u8 = [0...];
	let n = 0u64;
	for (true) {
		match (io::read(in, buf)?) {
		case let k: size =>
			hash::write(&h, buf[..k]);
			n += k;
		case io::EOF => break;
		};
	};
	let sum: [sha256::SZ]u8 = [0...];
	hash::sum(&h, sum);
	return (n, sum);
};

fn mkparent(p: str) void = {
	const (dir, _) = strings::rcut(p, "/");
	match (os::mkdirs(dir, fs::mode::USER_RWX)) {
	case => void;
	};
};

// Why something couldn't be done (a distinct type, so it can stand next
// to a str result).
type failure = str;

let errbuf: [256]u8 = [0...];

fn err(format: str, args: fmt::field...) failure = fmt::bsprintf(errbuf, format, args...)!;

// Backs up game gi. Returns the new backup's stamp (yours to free), or why
// it couldn't.
fn backup_game(gi: size, note: str) (str | failure) = {
	const g = GAMES[gi];
	if (len(g.dirs) == 0) return err("{} har ingen save-mapper (se Spil-stier)", g.name);
	if (running(g.proc)) return err("{} kører – luk spillet først", g.name);
	const t = now();
	let sb: [32]u8 = [0...];
	let stamp = strings::dup(stamp_name(sb, t))!;
	const base = game_dir(g.appid);
	defer free(base);
	let dir = strings::concat(base, "/backups/", stamp)!;
	// Never over an old one.
	for (let k = 2; os::exists(dir); k += 1) {
		free(dir);
		const s2 = fmt::asprintf("{}_{}", stamp_name(sb, t), k)!;
		free(stamp);
		stamp = s2;
		dir = strings::concat(base, "/backups/", stamp)!;
	};
	defer free(dir);
	const old = list_backups(g.appid);
	const version = if (len(old) > 0) old[0].version + 1 else 1;
	free_backups(old);

	let meta = memio::dynamic();
	defer io::close(&meta)!;
	fmt::fprintfln(&meta, "appid {}", g.appid)!;
	fmt::fprintfln(&meta, "navn {}", g.name)!;
	fmt::fprintfln(&meta, "version {}", version)!;
	fmt::fprintfln(&meta, "dato {}", t)!;
	if (len(note) > 0) fmt::fprintfln(&meta, "note {}", note)!;
	fmt::fprintfln(&meta, "maskine {}", machine())!;
	let files = 0z;
	for (let k = 0z; k < len(g.dirs); k += 1) {
		const src = local_path(g.dirs[k]);
		defer free(src);
		fmt::fprintfln(&meta, "mappe {} {}", k, g.dirs[k])!;
		let list: []str = [];
		defer strings::freeall(list);
		match (walk(src, "", &list)) {
		case void => void;
		case =>
			cleanup(dir);
			return err("kan ikke læse {}", g.dirs[k]);
		};
		for (let rel .. list) {
			const from = strings::concat(src, "/", rel)!;
			defer free(from);
			const to = fmt::asprintf("{}/{}/{}", dir, k, rel)!;
			defer free(to);
			mkparent(to);
			match (copy_hashed(from, to)) {
			case let r: (u64, [sha256::SZ]u8) =>
				fmt::fprintfln(&meta, "fil {} {} {} {}", k, hex::encodestr(r.1)!, r.0, rel)!;
				files += 1;
			case =>
				cleanup(dir);
				return err("kunne ikke kopiere {}", rel);
			};
		};
	};
	if (files == 0) {
		cleanup(dir);
		return err("ingen save-filer fundet for {}", g.name);
	};
	// The metadata last: a backup without it doesn't count.
	const mdir = strings::concat(base, "/metadata")!;
	defer free(mdir);
	match (os::mkdirs(mdir, fs::mode::USER_RWX)) {
	case => void;
	};
	const mp = fmt::asprintf("{}/{}.txt", mdir, stamp)!;
	defer free(mp);
	const tmp = strings::concat(mp, ".tmp")!;
	defer free(tmp);
	match (write_file(tmp, memio::string(&meta)!)) {
	case void => void;
	case =>
		cleanup(dir);
		return err("kunne ikke skrive metadata");
	};
	match (os::rename(tmp, mp)) {
	case void => void;
	case =>
		cleanup(dir);
		return err("kunne ikke skrive metadata");
	};
	let lb: [160]u8 = [0...], zb: [32]u8 = [0...];
	const total = backup_size(g.appid, stamp);
	log(fmt::bsprintf(lb, "Backup oprettet: {} ({}, {} filer{}{})", g.name,
		size_text(zb, total), files, if (len(note) > 0) ", " else "", note)!);
	return stamp;
};

fn cleanup(dir: str) void = {
	match (os::rmdirall(dir)) {
	case => void;
	};
};

fn write_file(p: str, text: str) (void | fs::error | io::error) = {
	mkparent(p);
	const f = os::create(p, 0o644)?;
	defer io::close(f)!;
	io::writeall(f, strings::toutf8(text))?;
};

// The backups of a game, newest first.
fn list_backups(appid: str) []backup = {
	let out: []backup = [];
	const mdir = fmt::asprintf("{}/metadata", game_dir_tmp(appid))!;
	defer free(mdir);
	const ents = match (os::readdir(mdir)) {
	case let e: []fs::dirent => yield e;
	case => return out;
	};
	defer fs::dirents_free(ents);
	for (let e .. ents) {
		if (!strings::hassuffix(e.name, ".txt")) continue;
		const p = strings::concat(mdir, "/", e.name)!;
		defer free(p);
		const text = match (read_text(p)) {
		case let s: str => yield s;
		case void => continue;
		};
		defer free(text);
		let b = backup {
			stamp = strings::dup(strings::trimsuffix(e.name, ".txt"))!,
			note = "",
			machine = "",
			...
		};
		let note = "", mach = "";
		let it = strings::tokenize(text, "\n");
		for (let line => strings::next_token(&it)) {
			const (key, rest) = strings::cut(line, " ");
			switch (key) {
			case "dato" => b.when = match (strconv::stoi64(rest)) {
				case let v: i64 => yield v;
				case => yield 0;
				};
			case "version" => b.version = match (strconv::stoi(rest)) {
				case let v: int => yield v;
				case => yield 0;
				};
			case "note" => note = rest;
			case "maskine" => mach = rest;
			case "fil" =>
				let f = strings::tokenize(rest, " ");
				strings::next_token(&f);
				strings::next_token(&f);
				match (strings::next_token(&f)) {
				case let s: str =>
					b.sz += match (strconv::stou64(s)) {
					case let v: u64 => yield v;
					case => yield 0;
					};
				case done => void;
				};
				b.files += 1;
			case => void;
			};
		};
		b.note = strings::dup(note)!;
		b.machine = strings::dup(mach)!;
		append(out, b)!;
	};
	sort::sort(out, size(backup), &newest_first)!;
	return out;
};

fn newest_first(a: const *opaque, b: const *opaque) int = {
	const a = a: const *backup, b = b: const *backup;
	return if (a.when > b.when) -1 else if (a.when < b.when) 1
		else strings::compare(b.stamp, a.stamp);
};

let gdbuf: [1024]u8 = [0...];

fn game_dir_tmp(appid: str) str = {
	const d = game_dir(appid);
	defer free(d);
	const n = copy_utf8(gdbuf, d);
	return strings::fromutf8_unsafe(gdbuf[..n]);
};

// A line of a backup's metadata: "fil N SHA SIZE PATH".
type entry = struct {
	k: size,
	sum: str,
	sz: u64,
	rel: str,
};

fn parse_entry(rest: str) (entry | void) = {
	const (k, rest) = strings::cut(rest, " ");
	const (sum, rest) = strings::cut(rest, " ");
	const (sz, rel) = strings::cut(rest, " ");
	const k = match (strconv::stoz(k)) {
	case let v: size => yield v;
	case => return;
	};
	const sz = match (strconv::stou64(sz)) {
	case let v: u64 => yield v;
	case => return;
	};
	if (len(sum) != sha256::SZ * 2 || len(rel) == 0) return;
	return entry { k = k, sum = sum, sz = sz, rel = rel };
};

fn read_meta(appid: str, stamp: str) (str | void) = {
	const p = fmt::asprintf("{}/metadata/{}.txt", game_dir_tmp(appid), stamp)!;
	defer free(p);
	return read_text(p);
};

// Checks that every file of a backup is there and unchanged.
fn verify(appid: str, stamp: str) (void | failure) = {
	const text = match (read_meta(appid, stamp)) {
	case let s: str => yield s;
	case void => return err("backuppen {} mangler sin metadata", stamp);
	};
	defer free(text);
	let n = 0z;
	let it = strings::tokenize(text, "\n");
	for (let line => strings::next_token(&it)) {
		const (key, rest) = strings::cut(line, " ");
		if (key != "fil") continue;
		const e = match (parse_entry(rest)) {
		case let e: entry => yield e;
		case void => return err("metadata er ødelagt");
		};
		const p = fmt::asprintf("{}/backups/{}/{}/{}", game_dir_tmp(appid), stamp, e.k, e.rel)!;
		defer free(p);
		match (hash_file(p)) {
		case let r: (u64, [sha256::SZ]u8) =>
			const hex = hex::encodestr(r.1)!;
			defer free(hex);
			if (r.0 != e.sz || hex != e.sum) return err("{} er ændret", e.rel);
		case => return err("{} mangler i backuppen", e.rel);
		};
		n += 1;
	};
	if (n == 0) return err("backuppen er tom");
};

// A folder restore may empty: not /, not $HOME, not a drive or a user folder.
fn safe_target(p: str) bool = {
	let parts = 0;
	let it = strings::tokenize(p, "/");
	for (let x => strings::next_token(&it)) if (len(x) > 0 && x != ".") parts += 1;
	if (parts < 4) return false;
	match (os::getenv("HOME")) {
	case let h: str => if (strings::trimsuffix(p, "/") == strings::trimsuffix(h, "/")) return false;
	case void => void;
	};
	return !strings::contains(p, "..");
};

// Restores a backup of game gi: checks the game isn't running and the
// backup is whole, backs up what is there now, and puts the backup back.
// Returns the stamp of the backup made first (yours to free), or why not.
fn restore(gi: size, stamp: str) (str | void | failure) = {
	const g = GAMES[gi];
	if (running(g.proc)) return err("{} kører – luk spillet først", g.name);
	match (verify(g.appid, stamp)) {
	case let e: failure =>
		// e lives in errbuf: copy it before err writes there.
		let tmp: [256]u8 = [0...];
		const n = copy_utf8(tmp, e);
		return err("backuppen er ikke i orden: {}", strings::fromutf8_unsafe(tmp[..n]));
	case void => void;
	};
	const text = match (read_meta(g.appid, stamp)) {
	case let s: str => yield s;
	case void => return err("metadata mangler");
	};
	defer free(text);
	// The folders to put it back into: this machine's, else the backup's.
	let targets: []str = [];
	defer strings::freeall(targets);
	let it = strings::tokenize(text, "\n");
	for (let line => strings::next_token(&it)) {
		const (key, rest) = strings::cut(line, " ");
		if (key != "mappe") continue;
		const (k, p) = strings::cut(rest, " ");
		const k = match (strconv::stoz(k)) {
		case let v: size => yield v;
		case => continue;
		};
		const t = local_path(if (k < len(g.dirs)) g.dirs[k] else p);
		if (!safe_target(t)) {
			free(t);
			return err("gendanner ikke til {}: for tæt på roden", p);
		};
		for (len(targets) <= k) append(targets, "")!;
		free(targets[k]);
		targets[k] = t;
	};
	// What is there now goes into a backup of its own first.
	let before: (str | void) = void;
	match (backup_game(gi, "før gendannelse")) {
	case let s: str => before = s;
	case let e: failure =>
		// Nothing there now is fine; anything else stops us.
		if (!strings::hasprefix(e, "ingen save-filer")) {
			let tmp: [256]u8 = [0...];
			const n = copy_utf8(tmp, e);
			return err("kunne ikke tage backup af de nuværende saves: {}",
				strings::fromutf8_unsafe(tmp[..n]));
		};
	};
	for (let t .. targets) {
		if (len(t) == 0) continue;
		match (os::rmdirall(t)) {
		case => void;
		};
		match (os::mkdirs(t, fs::mode::USER_RWX)) {
		case => void;
		};
	};
	let it = strings::tokenize(text, "\n");
	for (let line => strings::next_token(&it)) {
		const (key, rest) = strings::cut(line, " ");
		if (key != "fil") continue;
		const e = match (parse_entry(rest)) {
		case let e: entry => yield e;
		case void => continue;
		};
		if (e.k >= len(targets) || len(targets[e.k]) == 0) continue;
		const from = fmt::asprintf("{}/backups/{}/{}/{}", game_dir_tmp(g.appid), stamp, e.k, e.rel)!;
		defer free(from);
		const to = strings::concat(targets[e.k], "/", e.rel)!;
		defer free(to);
		mkparent(to);
		match (copy_hashed(from, to)) {
		case let r: (u64, [sha256::SZ]u8) =>
			const hex = hex::encodestr(r.1)!;
			defer free(hex);
			if (hex != e.sum) return err("{} blev ikke gendannet rigtigt", e.rel);
		case => return err("kunne ikke skrive {}", e.rel);
		};
	};
	log_restore(g.name, stamp);
	return before;
};

fn log_restore(name: str, stamp: str) void = {
	let lb: [160]u8 = [0...];
	log(fmt::bsprintf(lb, "Save gendannet: {} fra {}", name, stamp)!);
};

// The size of one backup.
fn backup_size(appid: str, stamp: str) u64 = {
	let total = 0u64;
	match (read_meta(appid, stamp)) {
	case let text: str =>
		let it = strings::tokenize(text, "\n");
		for (let line => strings::next_token(&it)) {
			const (key, rest) = strings::cut(line, " ");
			if (key != "fil") continue;
			match (parse_entry(rest)) {
			case let e: entry => total += e.sz;
			case void => void;
			};
		};
		free(text);
	case void => void;
	};
	return total;
};

fn exists_backup(appid: str, stamp: str) bool = {
	const p = fmt::asprintf("{}/metadata/{}.txt", game_dir_tmp(appid), stamp)!;
	defer free(p);
	return os::exists(p);
};

// Deletes one backup: its files and its metadata. The metadata goes first,
// so a half-deleted backup is never listed.
fn delete_backup(appid: str, stamp: str) (void | failure) = {
	if (len(stamp) == 0 || strings::contains(stamp, "/") || strings::contains(stamp, "..")) {
		return err("ugyldig backup: {}", stamp);
	};
	const base = game_dir(appid);
	defer free(base);
	const mp = fmt::asprintf("{}/metadata/{}.txt", base, stamp)!;
	defer free(mp);
	const dir = fmt::asprintf("{}/backups/{}", base, stamp)!;
	defer free(dir);
	if (!os::exists(mp)) return err("backuppen {} findes ikke", stamp);
	match (os::remove(mp)) {
	case void => void;
	case => return err("kunne ikke slette {}", mp);
	};
	cleanup(dir);
	let lb: [200]u8 = [0...];
	const name = match (find_game(appid)) {
	case let i: size => yield GAMES[i].name;
	case void => yield appid;
	};
	log(fmt::bsprintf(lb, "Backup slettet: {} ({})", name, stamp)!);
};

// Keeps only the newest `keep` backups of a game (0 keeps them all).
// Returns how many were deleted.
fn prune(appid: str, keep: size) size = {
	if (keep == 0) return 0;
	const bs = list_backups(appid);
	defer free_backups(bs);
	let n = 0z;
	for (let i = keep; i < len(bs); i += 1) {
		if (delete_backup(appid, bs[i].stamp) is void) n += 1;
	};
	return n;
};

// ---- Playing with the saves in MEGA ----

let machine_buf: [128]u8 = [0...];
let machine_len: size = 0;

// This PC's name: $HPO_MACHINE, else the hostname.
fn machine() str = {
	if (machine_len == 0) {
		const name = match (os::getenv("HPO_MACHINE")) {
		case let s: str => yield strings::dup(s)!;
		case void => yield match (read_text("/etc/hostname")) {
			case let s: str => yield s;
			case void => yield strings::dup("ukendt")!;
			};
		};
		defer free(name);
		machine_len = copy_utf8(machine_buf, strings::trim(name));
	};
	return strings::fromutf8_unsafe(machine_buf[..machine_len]);
};

// The backup to play on from: the newest one made after playing or by
// hand (not the safety copies made before a restore), if it was made on
// another PC and is newer than the saves here. Its index, or void.
fn cloud_pick(bs: []backup, local_newest: i64) (size | void) = {
	for (let i = 0z; i < len(bs); i += 1) {
		if (bs[i].note == "før gendannelse") continue;
		if (len(bs[i].machine) == 0 || bs[i].machine == machine()) return;
		if (bs[i].when <= local_newest) return;
		return i;
	};
};
