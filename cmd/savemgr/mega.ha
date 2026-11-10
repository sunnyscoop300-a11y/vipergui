// HPO STEAM SAVE MANAGER — running other programs: MEGAcmd for the cloud,
// and tasklist.exe (WSL) or pgrep (Linux) to see if a game is running.
use ascii;
use fs;
use io;
use os;
use os::exec;
use strings;

// Runs a program and returns what it wrote (stdout and stderr) and whether
// it went well, or void when there is no such program.
fn run(name: str, args: str...) (([]u8, bool) | void) = {
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
	const ok = match (exec::wait(&proc)) {
	case let s: exec::status =>
		yield match (exec::check(&s)) {
		case void => yield true;
		case => yield false;
		};
	case => yield false;
	};
	return (data, ok);
};

// Is the game's program running? On WSL Windows' tasklist.exe is asked,
// on Linux pgrep. Without a program name we can't tell, so: no.
fn running(proc: str) bool = {
	if (len(proc) == 0) return false;
	const filter = strings::concat("IMAGENAME eq ", proc)!;
	defer free(filter);
	match (run("tasklist.exe", "/FI", filter, "/NH")) {
	case let r: ([]u8, bool) =>
		defer free(r.0);
		const out = ascii::strlower(strings::fromutf8_unsafe(r.0))!;
		defer free(out);
		const p = ascii::strlower(proc)!;
		defer free(p);
		return strings::contains(out, p);
	case void => void;
	};
	match (run("pgrep", "-if", proc)) {
	case let r: ([]u8, bool) =>
		free(r.0);
		return r.1;
	case void => return false;
	};
};

// ---- MEGA ----

def NO_MEGA: str = "MEGAcmd er ikke installeret";
def NOT_LOGGED_IN: str = "ikke logget ind";
def NOT_SYNCED: str = "mappen synkroniseres ikke";
def MEGA_DIR: str = "/HPO/Saves";

// How the Saves folder's sync is doing: "Synced", "Pending", ... or why
// we can't tell.
fn mega_status(out: []u8) str = {
	const dir = saves_dir();
	defer free(dir);
	const r = match (run("mega-sync")) {
	case let r: ([]u8, bool) => yield r;
	case void => return NO_MEGA;
	};
	defer free(r.0);
	const text = strings::fromutf8_unsafe(r.0);
	if (strings::contains(text, "Not logged in")) return NOT_LOGGED_IN;
	return sync_state(out, text, dir);
};

// Finds the folder's line in mega-sync's table and returns its STATUS.
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
		if (n >= 5 && (same_path(w[1], dir) || w[2] == MEGA_DIR)) {
			const k = copy_utf8(out, w[4]);
			return strings::fromutf8_unsafe(out[..k]);
		};
	};
	return NOT_SYNCED;
};

// MEGAcmd shortens long paths ("/home/tux/.local/...hpo-saves/Saves").
fn same_path(shown: str, dir: str) bool = {
	if (strings::trimsuffix(shown, "/") == dir) return true;
	match (strings::index(shown, "...")) {
	case let i: size =>
		const head = strings::sub(shown, 0, i);
		const tail = strings::sub(shown, i + 3, strings::end);
		return len(head) + len(tail) < len(dir)
			&& strings::hasprefix(dir, head) && strings::hassuffix(dir, tail);
	case void => return false;
	};
};

// Logs in. Void when it went well, else what MEGA said.
fn mega_login(out: []u8, mail: str, password: str) (void | str) = {
	const r = match (run("mega-login", mail, password)) {
	case let r: ([]u8, bool) => yield r;
	case void => return NO_MEGA;
	};
	defer free(r.0);
	const text = strings::fromutf8_unsafe(r.0);
	if (strings::contains(text, "Login complete") || strings::contains(text, "Already logged in")) {
		return;
	};
	return last_line(out, text);
};

// Makes /HPO/Saves on MEGA and syncs the Saves folder with it.
fn mega_setup(out: []u8) (void | str) = {
	const dir = saves_dir();
	defer free(dir);
	match (os::mkdirs(dir, fs::mode::USER_RWX)) {
	case => void;
	};
	match (run("mega-mkdir", "-p", MEGA_DIR)) {
	case let r: ([]u8, bool) => free(r.0);
	case void => return NO_MEGA;
	};
	const r = match (run("mega-sync", dir, MEGA_DIR)) {
	case let r: ([]u8, bool) => yield r;
	case void => return NO_MEGA;
	};
	defer free(r.0);
	const text = strings::fromutf8_unsafe(r.0);
	if (strings::contains(text, "Added sync") || strings::contains(text, "already")) return;
	return last_line(out, text);
};

// "312.6 GB / 1 TB (31%)" from mega-df, or "".
fn mega_storage(out: []u8) (str, f64) = {
	const r = match (run("mega-df")) {
	case let r: ([]u8, bool) => yield r;
	case void => return ("", 0.0);
	};
	defer free(r.0);
	return parse_df(out, strings::fromutf8_unsafe(r.0));
};

// mega-df says: "USED STORAGE:   312.62 GB  31.26% of 1.00 TB"
fn parse_df(out: []u8, text: str) (str, f64) = {
	let it = strings::tokenize(text, "\n");
	for (let line => strings::next_token(&it)) {
		if (!strings::contains(line, "USED STORAGE")) continue;
		const (_, rest) = strings::cut(line, ":");
		let w: [8]str = [""...];
		let n = 0z;
		let words = strings::tokenize(rest, " ");
		for (let x => strings::next_token(&words)) {
			if (len(x) == 0) continue;
			if (n == len(w)) break;
			w[n] = x;
			n += 1;
		};
		// used unit pct "of" total unit
		if (n < 6) continue;
		const pct = strings::trimsuffix(w[2], "%");
		const f = match (strconv_f64(pct)) {
		case let v: f64 => yield v / 100.0;
		case void => yield 0.0;
		};
		let k = copy_utf8(out, w[0]);
		k += copy_utf8(out[k..], " ");
		k += copy_utf8(out[k..], w[1]);
		k += copy_utf8(out[k..], " / ");
		k += copy_utf8(out[k..], w[4]);
		k += copy_utf8(out[k..], " ");
		k += copy_utf8(out[k..], w[5]);
		k += copy_utf8(out[k..], " (");
		const (whole, _) = strings::cut(pct, ".");
		k += copy_utf8(out[k..], whole);
		k += copy_utf8(out[k..], "%)");
		return (strings::fromutf8_unsafe(out[..k]), f);
	};
	return ("", 0.0);
};

fn strconv_f64(s: str) (f64 | void) = {
	// Only "31.26" style: whole part and up to a few decimals.
	const (a, b) = strings::cut(s, ".");
	let v = 0.0;
	for (let c .. strings::toutf8(a)) {
		if (c < '0' || c > '9') return;
		v = v * 10.0 + (c - '0'): f64;
	};
	let scale = 0.1;
	for (let c .. strings::toutf8(b)) {
		if (c < '0' || c > '9') return;
		v += (c - '0'): f64 * scale;
		scale /= 10.0;
	};
	return v;
};

// The account's mail, from mega-whoami ("Account e-mail: x").
fn mega_whoami(out: []u8) str = {
	const r = match (run("mega-whoami")) {
	case let r: ([]u8, bool) => yield r;
	case void => return "";
	};
	defer free(r.0);
	const text = strings::fromutf8_unsafe(r.0);
	match (strings::index(text, "e-mail:")) {
	case let i: size =>
		const rest = strings::trim(strings::sub(text, i + 7, strings::end));
		const (mail, _) = strings::cut(rest, "\n");
		const n = copy_utf8(out, strings::trim(mail));
		return strings::fromutf8_unsafe(out[..n]);
	case void => return "";
	};
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
