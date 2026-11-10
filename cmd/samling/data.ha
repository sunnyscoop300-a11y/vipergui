// SAMLING — a tracker for a family of series and films: what there is (read
// from samling.txt, which you keep yourself) and what you have seen (kept in
// ~/.local/share/samling/<name>). Nothing about any real series is in here.
use ascii;
use fmt;
use fs;
use io;
use os;
use os::exec;
use strconv;
use strings;
use time;

def MAXENT: size = 12;         // series and films
def MAXEP: size = 400;         // episodes in one series

type episode = struct {
	title: str,
	aired: str,
	desc: str,
};

type season = struct {
	label: str,                // "1", "2", "Special"...
	first: size,               // its first episode in the entry's list
	n: size,
};

type entry = struct {
	name: str,
	film: bool,
	year: str,
	aired: str,                // films: the release date
	minutes: int,              // films: the length
	seasons: []season,
	eps: []episode,            // all of them, season after season
};

// What samling.txt says.
let NAME: str = "";            // the family's name (the progress file's name)
let TITLE: str = "";           // the window's title
let EP_MIN: int = 22;          // minutes per episode, about
let ENTRIES: []entry = [];

fn nep(e: size) size = if (ENTRIES[e].film) 1 else len(ENTRIES[e].eps);

// ---- What you have seen ----

type progress = struct {
	seen: [MAXENT][MAXEP]i64,  // when (Unix time), 0 = not seen
	synced: i64,               // when MEGA last said it was in sync
};

fn now() i64 = time::now(time::clock::REALTIME).sec;

fn nseen(p: *progress, e: size) int = {
	let n = 0;
	for (let i = 0z; i < nep(e); i += 1) if (p.seen[e][i] != 0) n += 1;
	return n;
};

fn nseen_season(p: *progress, e: size, s: size) int = {
	const se = ENTRIES[e].seasons[s];
	let n = 0;
	for (let i = 0z; i < se.n; i += 1) if (p.seen[e][se.first + i] != 0) n += 1;
	return n;
};

// The first episode of a series not seen yet, or nep(e) when all are.
fn next_ep(p: *progress, e: size) size = {
	for (let i = 0z; i < nep(e); i += 1) if (p.seen[e][i] == 0) return i;
	return nep(e);
};

// The season an episode is in.
fn season_of(e: size, i: size) size = {
	const ss = ENTRIES[e].seasons;
	for (let s = 0z; s < len(ss); s += 1) {
		if (i >= ss[s].first && i < ss[s].first + ss[s].n) return s;
	};
	return 0;
};

// "Sæson 1", or the label as it is when it isn't a number ("Special").
fn season_name(buf: []u8, label: str) str = {
	match (strconv::stoi(label)) {
	case int => return fmt::bsprintf(buf, "Sæson {}", label)!;
	case => return label;
	};
};

// Minutes spent on what you have seen.
fn minutes_seen(p: *progress) int = {
	let m = 0;
	for (let e = 0z; e < len(ENTRIES); e += 1) {
		const per = if (ENTRIES[e].film) ENTRIES[e].minutes else EP_MIN;
		m += nseen(p, e) * per;
	};
	return m;
};

// ---- Files ----

fn save_dir() (str | void) = {
	match (os::getenv("XDG_DATA_HOME")) {
	case let d: str =>
		if (len(d) > 0) return strings::concat(d, "/samling")!;
	case void => void;
	};
	match (os::getenv("HOME")) {
	case let h: str => return strings::concat(h, "/.local/share/samling")!;
	case void => return;
	};
};

// A file in the save folder if it is there, else in assets/samling/.
fn find_file(name: str) str = {
	match (save_dir()) {
	case let d: str =>
		const p = strings::concat(d, "/", name)!;
		free(d);
		if (os::exists(p)) return p;
		free(p);
	case void => void;
	};
	return strings::concat("assets/samling/", name)!;
};

// "Lynholdet: Nye Helte" -> lynholdet-nye-helte
fn slug(s: str) str = {
	let name: []u8 = [];
	for (let r .. strings::toutf8(s)) {
		const c = ascii::tolower(r: rune);
		if (ascii::isalnum(c)) {
			append(name, c: u8)!;
		} else if (len(name) > 0 && name[len(name) - 1] != '-') {
			append(name, '-')!;
		};
	};
	for (len(name) > 0 && name[len(name) - 1] == '-') delete(name[len(name) - 1]);
	if (len(name) == 0) append(name, strings::toutf8("samling")...)!;
	return strings::fromutf8_unsafe(name);
};

fn progress_path(dir: str) str = {
	const s = slug(NAME);
	defer free(s);
	return strings::concat(dir, "/", s)!;
};

fn read_text(path: str) (str | void) = {
	const f = match (os::open(path)) {
	case let f: io::file => yield f;
	case => return;
	};
	defer io::close(f)!;
	const data = match (io::drain(f)) {
	case let d: []u8 => yield d;
	case => return;
	};
	match (strings::fromutf8(data)) {
	case let s: str => return s;
	case =>
		free(data);
		return;
	};
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
	match (read_text(path)) {
	case let s: str =>
		parse(p, s);
		free(s);
	case void => void;
	};
};

// "set E S N TIME": episode N of season S of entry E (all from 1);
// "film E TIME"; "sync TIME".
fn parse(p: *progress, text: str) void = {
	let it = strings::tokenize(text, "\n");
	for (let line => strings::next_token(&it)) {
		let f: [5]str = [""...];
		let n = 0z;
		let words = strings::tokenize(strings::trim(line), " ");
		for (let w => strings::next_token(&words)) {
			if (n == len(f)) break;
			f[n] = w;
			n += 1;
		};
		let v: [4]size = [0...];
		for (let i = 1z; i < n; i += 1) {
			v[i - 1] = match (strconv::stoz(f[i])) {
			case let x: size => yield x;
			case => yield 0;
			};
		};
		switch (f[0]) {
		case "sync" =>
			p.synced = v[0]: i64;
		case "film" =>
			const e = v[0];
			if (e >= 1 && e <= len(ENTRIES) && ENTRIES[e - 1].film) {
				p.seen[e - 1][0] = v[1]: i64;
			};
		case "set" =>
			const (e, s, i) = (v[0], v[1], v[2]);
			if (e < 1 || e > len(ENTRIES) || ENTRIES[e - 1].film) continue;
			const ss = ENTRIES[e - 1].seasons;
			if (s < 1 || s > len(ss) || i < 1 || i > ss[s - 1].n) continue;
			p.seen[e - 1][ss[s - 1].first + i - 1] = v[3]: i64;
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
	fmt::fprintfln(f, "# Samling - {}", NAME)?;
	if (p.synced != 0) fmt::fprintfln(f, "sync {}", p.synced)?;
	for (let e = 0z; e < len(ENTRIES); e += 1) {
		if (ENTRIES[e].film) {
			if (p.seen[e][0] != 0) fmt::fprintfln(f, "film {} {}", e + 1, p.seen[e][0])?;
			continue;
		};
		const ss = ENTRIES[e].seasons;
		for (let s = 0z; s < len(ss); s += 1) {
			for (let i = 0z; i < ss[s].n; i += 1) {
				const t = p.seen[e][ss[s].first + i];
				if (t != 0) fmt::fprintfln(f, "set {} {} {} {}", e + 1, s + 1, i + 1, t)?;
			};
		};
	};
};

// ---- samling.txt ----
//
//	navn The Family
//	titel Family Tracker
//	minutter 22
//	serie Den første serie | 2013
//	sæson 1
//	afsnit 14. okt 2013 | Titel | En kort beskrivelse (kan udelades)
//	...
//	film En film | 2024 | 7. mar 2024 | 90
//	serie Den anden serie | 2025
//	sæson 1
//	afsnit ...
//	sæson Special
//	afsnit ...
//
// Looked for in ~/.local/share/samling/, then assets/samling/; the
// made-up assets/samling/eksempel.txt is the fallback.

fn load_collection() (str | void) = {
	let paths: [3]str = ["", "", ""];
	paths[0] = find_file("samling.txt");
	paths[1] = strings::dup("assets/samling/samling.txt")!;
	paths[2] = strings::dup("assets/samling/eksempel.txt")!;
	defer for (let p .. paths) free(p);
	for (let path .. paths) {
		// The text stays alive: the collection's strings point into it.
		match (read_text(path)) {
		case let text: str =>
			parse_collection(text);
			if (len(ENTRIES) == 0) return fmt::asprintf("ingen serier i {}", path)!;
			return;
		case void => void;
		};
	};
	return strings::dup("fandt ingen samling.txt (se assets/samling/eksempel.txt)")!;
};

fn field(s: str, n: size) str = {
	let it = strings::tokenize(s, "|");
	let i = 0z;
	for (let f => strings::next_token(&it)) {
		if (i == n) return strings::trim(f);
		i += 1;
	};
	return "";
};

fn parse_collection(text: str) void = {
	let ents: []entry = [];
	let it = strings::tokenize(text, "\n");
	for (let line => strings::next_token(&it)) {
		const line = strings::trim(line);
		if (len(line) == 0 || strings::hasprefix(line, "#")) continue;
		const (key, rest) = strings::cut(line, " ");
		const rest = strings::trim(rest);
		const cur: nullable *entry = if (len(ents) > 0) &ents[len(ents) - 1] else null;
		switch (key) {
		case "navn" => NAME = rest;
		case "titel" => TITLE = rest;
		case "minutter" =>
			match (strconv::stoi(rest)) {
			case let n: int => if (n > 0) EP_MIN = n;
			case => void;
			};
		case "serie", "film" =>
			if (len(ents) == MAXENT) continue;
			append(ents, entry {
				name = field(rest, 0),
				film = key == "film",
				year = field(rest, 1),
				aired = field(rest, 2),
				minutes = match (strconv::stoi(field(rest, 3))) {
				case let n: int => yield n;
				case => yield 90;
				},
				...
			})!;
		case "sæson" =>
			match (cur) {
			case let c: *entry =>
				if (c.film) continue;
				append(c.seasons, season {
					label = rest,
					first = len(c.eps),
					n = 0,
				})!;
			case null => void;
			};
		case "afsnit" =>
			match (cur) {
			case let c: *entry =>
				if (c.film || len(c.eps) == MAXEP) continue;
				if (len(c.seasons) == 0) {
					append(c.seasons, season { label = "1", ... })!;
				};
				append(c.eps, episode {
					aired = field(rest, 0),
					title = field(rest, 1),
					desc = field(rest, 2),
				})!;
				c.seasons[len(c.seasons) - 1].n += 1;
			case null => void;
			};
		case => void;
		};
	};
	// Drop series without episodes.
	let i = 0z;
	for (i < len(ents)) {
		if (!ents[i].film && len(ents[i].eps) == 0) {
			delete(ents[i]);
		} else {
			i += 1;
		};
	};
	ENTRIES = ents;
	if (len(NAME) == 0 && len(ents) > 0) NAME = ents[0].name;
	if (len(TITLE) == 0) TITLE = NAME;
};

// ---- MEGA ----

// Runs a MEGAcmd command and returns what it wrote (stdout and stderr
// both), or void when MEGAcmd isn't installed.
fn mega_run(name: str, args: str...) ([]u8 | void) = {
	let cmd = match (exec::cmd(name, args...)) {
	case let c: exec::command => yield c;
	case => return;
	};
	const (rd, wr) = exec::pipe();
	exec::addfile(&cmd, os::stdout_file, wr)!;
	exec::addfile(&cmd, os::stderr_file, wr)!;
	exec::addfile(&cmd, os::stdin_file, exec::nullfd)!;
	let proc = match (exec::start(&cmd)) {
	case let p: exec::process => yield p;
	case =>
		io::close(rd)!;
		io::close(wr)!;
		return;
	};
	io::close(wr)!;
	const data = match (io::drain(rd)) {
	case let d: []u8 => yield d;
	case => yield []: []u8;
	};
	io::close(rd)!;
	match (exec::wait(&proc)) {
	case => void;
	};
	return data;
};

def NO_MEGA: str = "MEGAcmd er ikke installeret";
def NOT_LOGGED_IN: str = "ikke logget ind";
def NOT_SYNCED: str = "mappen synkroniseres ikke";

// Asks MEGAcmd how the save folder's sync is doing: "Synced", "Pending",
// ..., or why we can't tell.
fn mega_status(out: []u8) str = {
	const dir = match (save_dir()) {
	case let d: str => yield d;
	case void => return "ingen mappe";
	};
	defer free(dir);
	const data = match (mega_run("mega-sync")) {
	case let d: []u8 => yield d;
	case void => return NO_MEGA;
	};
	defer free(data);
	const text = match (strings::fromutf8(data)) {
	case let s: str => yield s;
	case => return "ukendt svar";
	};
	if (strings::contains(text, "Not logged in")) return NOT_LOGGED_IN;
	return sync_state(out, text, dir);
};

// Logs in to MEGA. Returns void when it went well, else what MEGA said.
fn mega_login(out: []u8, mail: str, password: str) (void | str) = {
	const data = match (mega_run("mega-login", mail, password)) {
	case let d: []u8 => yield d;
	case void => return NO_MEGA;
	};
	defer free(data);
	const text = strings::fromutf8_unsafe(data);
	if (strings::contains(text, "Login complete") || strings::contains(text, "Already logged in")) {
		return;
	};
	return last_line(out, text);
};

// Makes /Samling on MEGA and syncs the save folder with it.
fn mega_setup(out: []u8) (void | str) = {
	const dir = match (save_dir()) {
	case let d: str => yield d;
	case void => return "ingen mappe";
	};
	defer free(dir);
	match (os::mkdirs(dir, fs::mode::USER_RWX)) {
	case => void;
	};
	match (mega_run("mega-mkdir", "-p", "/Samling")) {
	case let d: []u8 => free(d);
	case void => return NO_MEGA;
	};
	const data = match (mega_run("mega-sync", dir, "/Samling")) {
	case let d: []u8 => yield d;
	case void => return NO_MEGA;
	};
	defer free(data);
	const text = strings::fromutf8_unsafe(data);
	if (strings::contains(text, "Added sync") || strings::contains(text, "already")) return;
	return last_line(out, text);
};

// The last line that says something, without MEGAcmd's "[date cmd ERR".
fn last_line(out: []u8, text: str) str = {
	let last = "";
	let it = strings::tokenize(text, "\n");
	for (let line => strings::next_token(&it)) {
		const line = strings::trim(line);
		if (len(line) > 0) last = line;
	};
	match (strings::index(last, " ERR ")) {
	case let i: size => last = strings::trim(strings::sub(last, i + 5, strings::end), ']', ' ');
	case void => void;
	};
	if (len(last) == 0) last = "intet svar";
	const n = copy_utf8(out, last);
	return strings::fromutf8_unsafe(out[..n]);
};

// Finds dir's line in mega-sync's table and returns its STATUS column.
fn sync_state(out: []u8, table: str, dir: str) str = {
	let it = strings::tokenize(table, "\n");
	for (let line => strings::next_token(&it)) {
		let words = strings::tokenize(line, " ");
		let w: [6]str = [""...];
		let n = 0z;
		for (let x => strings::next_token(&words)) {
			if (len(x) == 0) continue;
			if (n == len(w)) break;
			w[n] = x;
			n += 1;
		};
		// ID LOCALPATH REMOTEPATH RUN_STATE STATUS ...
		if (n >= 5 && w[1] == dir) {
			const k = copy_utf8(out, w[4]);
			return strings::fromutf8_unsafe(out[..k]);
		};
	};
	return "mappen synkroniseres ikke";
};

// Copies s into buf, cut on a character boundary if it doesn't fit.
fn copy_utf8(buf: []u8, s: str) size = {
	const b = strings::toutf8(s);
	let n = if (len(b) > len(buf)) len(buf) else len(b);
	for (n > 0 && n < len(b) && b[n] & 0xC0 == 0x80) n -= 1;
	buf[..n] = b[..n];
	return n;
};
