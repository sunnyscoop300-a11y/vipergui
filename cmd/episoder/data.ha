// EPISODER — the series (from serie.txt), its episodes, and what you have
// seen, kept in ~/.local/share/episoder/<series>.
use ascii;
use fmt;
use fs;
use io;
use os;
use strconv;
use strings;
use time;

def MAXEP: size = 200;

type episode = struct {
	title: str,
	aired: str,
};

// The series, read from serie.txt when the program starts (see load_show).
let SERIES: str = "";
let GENRES: str = "";
let YEAR: str = "";
let STUDIO: str = "";
let EP_MIN: int = 24;          // minutes per episode, about
let PER: size = 12;            // episodes per part
let NEP: size = 0;
let EPISODES: []episode = [];

// How many parts, and how many episodes in part n.
fn nparts() int = ((NEP + PER - 1) / PER): int;

fn part_len(part: int) int = {
	const first = part: size * PER;
	if (first >= NEP) return 0;
	return (if (NEP - first < PER) NEP - first else PER): int;
};

def NOTE_MAX: size = 200;

type progress = struct {
	seen: [MAXEP]i64,            // when it was marked seen (Unix time), 0 = not
	notes: [MAXEP][NOTE_MAX]u8,
	nlen: [MAXEP]size,
	folder: [512]u8,           // where the episode files are
	flen: size,
};

fn now() i64 = time::now(time::clock::REALTIME).sec;

fn nseen(p: *progress) int = {
	let n = 0;
	for (let s .. p.seen) if (s != 0) n += 1;
	return n;
};

fn nseen_part(p: *progress, part: int) int = {
	let n = 0;
	for (let i = 0z; i < part_len(part): size; i += 1) {
		if (p.seen[part: size * PER + i] != 0) n += 1;
	};
	return n;
};

// The first episode not seen yet, or NEP when all are.
fn next_ep(p: *progress) size = {
	for (let i = 0z; i < NEP; i += 1) if (p.seen[i] == 0) return i;
	return NEP;
};

fn note(p: *progress, i: size) str = strings::fromutf8_unsafe(p.notes[i][..p.nlen[i]]);

fn set_note(p: *progress, i: size, s: str) void = {
	p.nlen[i] = copy_utf8(p.notes[i], s);
};

fn folder(p: *progress) str = strings::fromutf8_unsafe(p.folder[..p.flen]);

fn set_folder(p: *progress, s: str) void = {
	p.flen = copy_utf8(p.folder, s);
};

// Copies s into buf, cut on a character boundary if it doesn't fit.
fn copy_utf8(buf: []u8, s: str) size = {
	const b = strings::toutf8(s);
	let n = if (len(b) > len(buf)) len(buf) else len(b);
	for (n > 0 && n < len(b) && b[n] & 0xC0 == 0x80) n -= 1;
	buf[..n] = b[..n];
	return n;
};

// Episodes marked seen in each of the last weeks, newest last.
fn per_week(p: *progress, weeks: size, out: []int) void = {
	const t = now();
	for (let i = 0z; i < weeks; i += 1) out[i] = 0;
	for (let s .. p.seen) {
		if (s == 0 || s > t) continue;
		const ago = ((t - s) / (7 * 24 * 3600)): size;
		if (ago < weeks) out[weeks - 1 - ago] += 1;
	};
};

// ---- The file: "set N TIME", "note N TEXT", "mappe PATH" ----

fn save_dir() (str | void) = {
	match (os::getenv("XDG_DATA_HOME")) {
	case let d: str =>
		if (len(d) > 0) return strings::concat(d, "/episoder")!;
	case void => void;
	};
	match (os::getenv("HOME")) {
	case let h: str => return strings::concat(h, "/.local/share/episoder")!;
	case void => return;
	};
};

// One progress file per series, named after it: "Min Serie" -> min-serie.
fn progress_path(dir: str) str = {
	let name: []u8 = [];
	defer free(name);
	for (let r .. strings::toutf8(SERIES)) {
		const c = ascii::tolower(r: rune);
		if (ascii::isalnum(c)) {
			append(name, c: u8)!;
		} else if (len(name) > 0 && name[len(name) - 1] != '-') {
			append(name, '-')!;
		};
	};
	for (len(name) > 0 && name[len(name) - 1] == '-') delete(name[len(name) - 1]);
	if (len(name) == 0) append(name, strings::toutf8("serie")...)!;
	return strings::concat(dir, "/", strings::fromutf8_unsafe(name))!;
};

fn load(p: *progress) void = {
	*p = progress { ... };
	const dir = match (save_dir()) {
	case let d: str => yield d;
	case void => return;
	};
	defer free(dir);
	const path = progress_path(dir);
	defer free(path);
	const f = match (os::open(path)) {
	case let f: io::file => yield f;
	case => return;
	};
	defer io::close(f)!;
	const data = match (io::drain(f)) {
	case let d: []u8 => yield d;
	case => return;
	};
	defer free(data);
	const text = match (strings::fromutf8(data)) {
	case let s: str => yield s;
	case => return;
	};
	parse(p, text);
};

fn parse(p: *progress, text: str) void = {
	let it = strings::tokenize(text, "\n");
	for (let line => strings::next_token(&it)) {
		const (key, rest) = strings::cut(line, " ");
		if (key == "mappe") {
			set_folder(p, rest);
			continue;
		};
		const (num, val) = strings::cut(rest, " ");
		const n = match (strconv::stoz(num)) {
		case let n: size => yield n;
		case => continue;
		};
		if (n < 1 || n > NEP) continue;
		switch (key) {
		case "set" =>
			p.seen[n - 1] = match (strconv::stoi64(val)) {
			case let t: i64 => yield if (t > 0) t else 1;
			case => yield 1;
			};
		case "note" => set_note(p, n - 1, val);
		case => void;
		};
	};
};

fn save(p: *progress) void = {
	const dir = match (save_dir()) {
	case let d: str => yield d;
	case void => return;
	};
	defer free(dir);
	match (os::mkdirs(dir, fs::mode::USER_RWX)) {
	case => void;
	};
	const path = progress_path(dir);
	defer free(path);
	const f = match (os::create(path, 0o644)) {
	case let f: io::file => yield f;
	case => return;
	};
	defer io::close(f)!;
	match (write(f, p)) {
	case => void;
	};
};

fn write(f: io::handle, p: *progress) (void | io::error) = {
	fmt::fprintfln(f, "# Episoder - {}", SERIES)?;
	if (p.flen > 0) fmt::fprintfln(f, "mappe {}", folder(p))?;
	for (let i = 0z; i < NEP; i += 1) {
		if (p.seen[i] != 0) fmt::fprintfln(f, "set {} {}", i + 1, p.seen[i])?;
		if (p.nlen[i] > 0) fmt::fprintfln(f, "note {} {}", i + 1, note(p, i))?;
	};
};

// ---- The series: serie.txt ----
//
//	navn Min Serie
//	genrer Eventyr  ·  Action
//	år 2024
//	studie Et Studie
//	minutter 24
//	del 12
//	afsnit 4. jan 2024 | Den første titel
//	afsnit 11. jan 2024 | Den anden titel
//
// One "afsnit" line per episode, in order; "del" is how many episodes
// make a part (a tab in the list). Looked for in ~/.local/share/episoder/,
// then assets/episoder/, and assets/episoder/eksempel.txt is the fallback.

fn load_show() (str | void) = {
	let tried: []str = [];
	defer strings::freeall(tried);
	match (save_dir()) {
	case let d: str =>
		append(tried, strings::concat(d, "/serie.txt")!)!;
		free(d);
	case void => void;
	};
	append(tried, strings::dup("assets/episoder/serie.txt")!)!;
	append(tried, strings::dup("assets/episoder/eksempel.txt")!)!;
	for (let path .. tried) {
		const f = match (os::open(path)) {
		case let f: io::file => yield f;
		case => continue;
		};
		const data = io::drain(f);
		io::close(f)!;
		const data = match (data) {
		case let d: []u8 => yield d;
		case => continue;
		};
		// The text stays alive: the series' strings point into it.
		const text = match (strings::fromutf8(data)) {
		case let s: str => yield s;
		case => return strings::concat("ikke UTF-8: ", path)!;
		};
		parse_show(text);
		if (NEP == 0) return strings::concat("ingen afsnit i ", path)!;
		return;
	};
	return strings::dup("fandt ingen serie.txt (se assets/episoder/eksempel.txt)")!;
};

fn parse_show(text: str) void = {
	let eps: []episode = [];
	let it = strings::tokenize(text, "\n");
	for (let line => strings::next_token(&it)) {
		const line = strings::trim(line);
		if (len(line) == 0 || strings::hasprefix(line, "#")) continue;
		const (key, rest) = strings::cut(line, " ");
		const rest = strings::trim(rest);
		switch (key) {
		case "navn" => SERIES = rest;
		case "genrer" => GENRES = rest;
		case "år" => YEAR = rest;
		case "studie" => STUDIO = rest;
		case "minutter" =>
			match (strconv::stoi(rest)) {
			case let n: int => if (n > 0) EP_MIN = n;
			case => void;
			};
		case "del" =>
			match (strconv::stoz(rest)) {
			case let n: size => if (n > 0) PER = n;
			case => void;
			};
		case "afsnit" =>
			if (len(eps) == MAXEP) continue;
			const (aired, title) = strings::cut(rest, "|");
			append(eps, episode {
				title = strings::trim(title),
				aired = strings::trim(aired),
			})!;
		case => void;
		};
	};
	EPISODES = eps;
	NEP = len(eps);
};
