// HPO STEAM SAVE MANAGER — the games and their save folders, the paths, and
// the log.
//
// Everything lives in ~/.local/share/hpo-saves/:
//	games.txt       the games and where their saves are (this machine's)
//	log.txt         what happened
//	skin.png        the mockup, if you have one
//	Saves/          the backups; MEGAcmd keeps it in sync with /HPO/Saves
//	  Steam/<appid>/backups/<stamp>/<n>/...   the files of save folder n
//	  Steam/<appid>/metadata/<stamp>.txt      what is in that backup
//	covers/<appid>.png, covers/<appid>-banner.png   pictures, if you have them
//	settings.txt    "behold N": backups kept per game (0 = all);
//	                "skjul <appid>": a Steam game you removed, not found again;
//	                "megasaves ja|nej": Start spil plays on from MEGA's saves
use ascii;
use fmt;
use fs;
use io;
use memio;
use os;
use strconv;
use strings;
use time;
use time::date;

def VERSION: str = "0.1.0";

type game = struct {
	appid: str,
	name: str,
	dirs: []str,      // as written in games.txt (C:\... works in WSL)
	proc: str,        // the game's program, to see if it is running
	star: bool,       // a favourite: sorted first
};

let GAMES: []game = [];

// ---- Paths ----

let data_dir_buf: [512]u8 = [0...];
let data_dir_len: size = 0;

// ~/.local/share/hpo-saves (or $XDG_DATA_HOME/hpo-saves).
fn data_dir() str = {
	if (data_dir_len == 0) {
		const base = match (os::getenv("XDG_DATA_HOME")) {
		case let d: str => yield if (len(d) > 0) strings::dup(d)! else home_share();
		case void => yield home_share();
		};
		defer free(base);
		data_dir_len = copy_utf8(data_dir_buf, base);
		data_dir_len += copy_utf8(data_dir_buf[data_dir_len..], "/hpo-saves");
	};
	return strings::fromutf8_unsafe(data_dir_buf[..data_dir_len]);
};

fn home_share() str = match (os::getenv("HOME")) {
case let h: str => yield strings::concat(h, "/.local/share")!;
case void => yield strings::dup("/tmp")!;
};

fn path(parts: str...) str = {
	let p = strings::dup(data_dir())!;
	for (let x .. parts) {
		const n = strings::concat(p, "/", x)!;
		free(p);
		p = n;
	};
	return p;
};

fn saves_dir() str = path("Saves");

// Where game appid's backups go.
fn game_dir(appid: str) str = path("Saves", "Steam", appid);

// A save folder as this machine can open it: "C:\Users\x" becomes
// "/mnt/c/Users/x" (WSL), "~/x" becomes "$HOME/x".
fn local_path(p: str) str = {
	const b = strings::toutf8(p);
	if (len(b) >= 3 && ascii::isalpha(b[0]: rune) && b[1] == ':'
			&& (b[2] == '\\' || b[2] == '/')) {
		let out: []u8 = [];
		append(out, strings::toutf8("/mnt/")...)!;
		append(out, ascii::tolower(b[0]: rune): u8)!;
		for (let c .. b[2..]) append(out, if (c == '\\') '/' else c)!;
		for (len(out) > 1 && out[len(out) - 1] == '/') delete(out[len(out) - 1]);
		return strings::fromutf8_unsafe(out);
	};
	if (strings::hasprefix(p, "~/")) {
		match (os::getenv("HOME")) {
		case let h: str => return strings::concat(h, strings::sub(p, 1, strings::end))!;
		case void => void;
		};
	};
	return strings::dup(p)!;
};

// ---- games.txt ----
//
//	spil 1172380 | Death's Door
//	mappe C:\Users\Bossun\AppData\LocalLow\Acid Nerve\Death's Door
//	proces DeathsDoor.exe
//	favorit

fn load_games() void = {
	free_games();
	const p = path("games.txt");
	defer free(p);
	match (read_text(p)) {
	case let s: str =>
		parse_games(s);
		free(s);
	case void => void;
	};
};

fn free_games() void = {
	for (let g .. GAMES) {
		free(g.appid);
		free(g.name);
		strings::freeall(g.dirs);
		free(g.proc);
	};
	free(GAMES);
	GAMES = [];
};

fn parse_games(text: str) void = {
	let it = strings::tokenize(text, "\n");
	for (let line => strings::next_token(&it)) {
		const line = strings::trim(line);
		if (len(line) == 0 || strings::hasprefix(line, "#")) continue;
		const (key, rest) = strings::cut(line, " ");
		const rest = strings::trim(rest);
		if (key == "spil") {
			const (id, name) = strings::cut(rest, "|");
			const id = strings::trim(id);
			if (len(id) == 0) continue;
			append(GAMES, game {
				appid = strings::dup(id)!,
				name = strings::dup(strings::trim(name))!,
				proc = "",
				...
			})!;
			continue;
		};
		if (len(GAMES) == 0) continue;
		let g = &GAMES[len(GAMES) - 1];
		switch (key) {
		case "mappe" =>
			if (len(rest) > 0) append(g.dirs, strings::dup(rest)!)!;
		case "proces" =>
			free(g.proc);
			g.proc = strings::dup(rest)!;
		case "favorit" =>
			g.star = true;
		case => void;
		};
	};
};

fn save_games() void = {
	match (os::mkdirs(data_dir(), fs::mode::USER_RWX)) {
	case => void;
	};
	const p = path("games.txt");
	defer free(p);
	const f = match (os::create(p, 0o644)) {
	case let f: io::file => yield f;
	case => return;
	};
	defer io::close(f)!;
	match (write_games(f)) {
	case => void;
	};
};

fn write_games(f: io::handle) (void | io::error) = {
	fmt::fprintln(f, "# HPO Steam Save Manager: spil, save-mapper og program")?;
	for (let g .. GAMES) {
		fmt::fprintfln(f, "\nspil {} | {}", g.appid, g.name)?;
		for (let d .. g.dirs) fmt::fprintfln(f, "mappe {}", d)?;
		if (len(g.proc) > 0) fmt::fprintfln(f, "proces {}", g.proc)?;
		if (g.star) fmt::fprintln(f, "favorit")?;
	};
};

fn find_game(appid: str) (size | void) = {
	for (let i = 0z; i < len(GAMES); i += 1) if (GAMES[i].appid == appid) return i;
};

// Adds a game, or returns why not.
fn add_game(appid: str, name: str) (void | str) = {
	const appid = strings::trim(appid), name = strings::trim(name);
	if (len(appid) == 0) return "skriv spillets AppID";
	for (let r .. strings::toutf8(appid)) {
		if (!ascii::isdigit(r: rune)) return "AppID er kun tal";
	};
	if (find_game(appid) is size) return "spillet findes allerede";
	set_hidden(appid, false);
	append(GAMES, game {
		appid = strings::dup(appid)!,
		name = strings::dup(if (len(name) > 0) name else appid)!,
		proc = "",
		...
	})!;
	save_games();
};

// Removes a game; a Steam game isn't found again until added by hand.
fn remove_game(i: size) void = {
	const g = GAMES[i];
	set_hidden(g.appid, true);
	free(g.appid);
	free(g.name);
	strings::freeall(g.dirs);
	free(g.proc);
	delete(GAMES[i]);
	save_games();
};

// ---- The log ----

fn log(msg: str) void = {
	match (os::mkdirs(data_dir(), fs::mode::USER_RWX)) {
	case => void;
	};
	const p = path("log.txt");
	defer free(p);
	const f = match (os::create(p, 0o644, fs::flag::WRONLY | fs::flag::APPEND)) {
	case let f: io::file => yield f;
	case => return;
	};
	defer io::close(f)!;
	let b: [32]u8 = [0...];
	match (fmt::fprintfln(f, "{}  {}", stamp_text(b, now()), msg)) {
	case => void;
	};
};

// The last n lines of the log, newest first.
fn log_tail(n: size) []str = {
	const p = path("log.txt");
	defer free(p);
	let out: []str = [];
	const text = match (read_text(p)) {
	case let s: str => yield s;
	case void => return out;
	};
	defer free(text);
	let lines = strings::split(text, "\n")!;
	defer free(lines);
	for (let i = len(lines); i > 0 && len(out) < n; i -= 1) {
		const l = strings::trim(lines[i - 1]);
		if (len(l) > 0) append(out, strings::dup(l)!)!;
	};
	return out;
};

// ---- Little helpers ----

fn now() i64 = time::now(time::clock::REALTIME).sec;

// "2026-11-07 18:42"
fn stamp_text(buf: []u8, t: i64) str = {
	const d = date::from_instant(date::LOCAL, time::instant { sec = t, nsec = 0 });
	return fmt::bsprintf(buf, "{}-{:_02}-{:_02} {:_02}:{:_02}", date::year(&d),
		date::month(&d), date::day(&d), date::hour(&d), date::minute(&d))!;
};

// "2026-11-07_18-42-05": a backup's folder name.
fn stamp_name(buf: []u8, t: i64) str = {
	const d = date::from_instant(date::LOCAL, time::instant { sec = t, nsec = 0 });
	return fmt::bsprintf(buf, "{}-{:_02}-{:_02}_{:_02}-{:_02}-{:_02}", date::year(&d),
		date::month(&d), date::day(&d), date::hour(&d), date::minute(&d),
		date::second(&d))!;
};

// "12.4 MB"
fn size_text(buf: []u8, n: u64) str = {
	if (n < 1024) return fmt::bsprintf(buf, "{} B", n)!;
	const units = ["KB", "MB", "GB", "TB"];
	let v = n: f64 / 1024.0;
	let u = 0z;
	for (v >= 1024.0 && u + 1 < len(units)) {
		v /= 1024.0;
		u += 1;
	};
	const tenths = (v * 10.0 + 0.5): u64;
	return fmt::bsprintf(buf, "{}.{} {}", tenths / 10, tenths % 10, units[u])!;
};

fn read_text(p: str) (str | void) = {
	const f = match (os::open(p)) {
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

// Copies s into buf, cut on a character boundary if it doesn't fit.
fn copy_utf8(buf: []u8, s: str) size = {
	const b = strings::toutf8(s);
	let n = if (len(b) > len(buf)) len(buf) else len(b);
	for (n > 0 && n < len(b) && b[n] & 0xC0 == 0x80) n -= 1;
	buf[..n] = b[..n];
	return n;
};

// ---- Settings ----

// How many backups are kept per game; older ones are deleted after a
// backup. 0 keeps them all.
let KEEP: size = 10;
const KEEP_CHOICES: [_]size = [0, 3, 5, 10, 20, 50];

fn load_settings() void = {
	const p = path("settings.txt");
	defer free(p);
	strings::freeall(HIDDEN);
	HIDDEN = [];
	const text = match (read_text(p)) {
	case let s: str => yield s;
	case void => return;
	};
	defer free(text);
	let it = strings::tokenize(text, "\n");
	for (let line => strings::next_token(&it)) {
		const (k, v) = strings::cut(strings::trim(line), " ");
		if (k == "skjul" && len(strings::trim(v)) > 0) {
			append(HIDDEN, strings::dup(strings::trim(v))!)!;
			continue;
		};
		if (k == "megasaves") {
			MEGA_PLAY = strings::trim(v) != "nej";
			continue;
		};
		if (k == "behold") match (strconv::stoz(strings::trim(v))) {
		case let n: size => KEEP = n;
		case => void;
		};
	};
};

fn save_settings() void = {
	const p = path("settings.txt");
	defer free(p);
	let out = memio::dynamic();
	defer io::close(&out)!;
	fmt::fprintfln(&out, "behold {}", KEEP)!;
	fmt::fprintfln(&out, "megasaves {}", if (MEGA_PLAY) "ja" else "nej")!;
	for (let h .. HIDDEN) fmt::fprintfln(&out, "skjul {}", h)!;
	match (write_file(p, memio::string(&out)!)) {
	case => void;
	};
};

// Start spil: first the newest saves from another PC (in MEGA), and after
// playing a backup.
let MEGA_PLAY: bool = true;

// Steam games removed by hand, which finding Steam games skips.
let HIDDEN: []str = [];

fn hidden(appid: str) bool = {
	for (let h .. HIDDEN) if (h == appid) return true;
	return false;
};

fn set_hidden(appid: str, on: bool) void = {
	for (let i = 0z; i < len(HIDDEN); i += 1) if (HIDDEN[i] == appid) {
		if (on) return;
		free(HIDDEN[i]);
		delete(HIDDEN[i]);
		save_settings();
		return;
	};
	if (on) {
		append(HIDDEN, strings::dup(appid)!)!;
		save_settings();
	};
};
