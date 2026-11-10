// HPO STEAM SAVE MANAGER — finding the installed Steam games.
//
// Steam lists its libraries (also those on other drives) in
// steamapps/libraryfolders.vdf, and each installed game has an
// steamapps/appmanifest_<appid>.acf with its name. Where its saves are is
// guessed: in the game's Proton prefix a folder called SaveGames, Saves,
// Save or SaveData; else Steam Cloud's copy in userdata/<user>/<appid>/remote.
use ascii;
use fmt;
use fs;
use os;
use sort;
use strings;

// Steam's own folders on this machine (the ones that exist).
fn steam_roots() []str = {
	let out: []str = [];
	const home = os::tryenv("HOME", "/root");
	const homes = [
		".steam/debian-installation",
		".steam/steam",
		".local/share/Steam",
		".var/app/com.valvesoftware.Steam/data/Steam",
		"snap/steam/common/.local/share/Steam",
	];
	for (let h .. homes) {
		const p = fmt::asprintf("{}/{}", home, h)!;
		if (os::exists(p)) append(out, p)! else free(p);
	};
	for (let p .. ["/mnt/c/Program Files (x86)/Steam", "/mnt/c/Program Files/Steam"]) {
		if (os::exists(p)) append(out, strings::dup(p)!)!;
	};
	return out;
};

// The quoted strings of a vdf/acf line: "path"  "/media/x" -> path, /media/x.
fn quoted(line: str, out: []str) size = {
	const b = strings::toutf8(line);
	let n = 0z, i = 0z;
	for (n < len(out)) {
		for (i < len(b) && b[i] != '"') i += 1;
		if (i >= len(b)) break;
		i += 1;
		const start = i;
		for (i < len(b) && b[i] != '"') {
			if (b[i] == '\\') i += 1;
			i += 1;
		};
		if (i > len(b)) i = len(b);
		out[n] = strings::fromutf8_unsafe(b[start..i]);
		n += 1;
		i += 1;
	};
	return n;
};

// "D:\\SteamLibrary" -> D:\SteamLibrary
fn unescape(s: str) str = {
	let out: []u8 = [];
	const b = strings::toutf8(s);
	for (let i = 0z; i < len(b); i += 1) {
		if (b[i] == '\\' && i + 1 < len(b)) i += 1;
		append(out, b[i])!;
	};
	return strings::fromutf8_unsafe(out);
};

// Every Steam library: the roots and the folders libraryfolders.vdf names,
// as this machine opens them, without doubles.
fn steam_libraries() []str = {
	let out: []str = [];
	const roots = steam_roots();
	defer strings::freeall(roots);
	for (let r .. roots) {
		add_library(&out, strings::dup(r)!);
		for (let f .. ["steamapps/libraryfolders.vdf", "config/libraryfolders.vdf"]) {
			const p = strings::concat(r, "/", f)!;
			defer free(p);
			const text = match (read_text(p)) {
			case let s: str => yield s;
			case void => continue;
			};
			defer free(text);
			let it = strings::tokenize(text, "\n");
			for (let line => strings::next_token(&it)) {
				let q: [2]str = ["", ""];
				if (quoted(line, q) == 2 && q[0] == "path") {
					const raw = unescape(q[1]);
					defer free(raw);
					add_library(&out, local_path(raw));
				};
			};
		};
	};
	return out;
};

// Adds a library unless it is there (also as a link to one that is).
fn add_library(libs: *[]str, p: str) void = {
	const real = match (os::realpath(p)) {
	case let r: str => yield strings::dup(r)!;
	case => yield strings::dup(p)!;
	};
	free(p);
	for (let l .. *libs) if (l == real) {
		free(real);
		return;
	};
	append(libs, real)!;
};

type found = struct {
	appid: str,
	name: str,
	lib: str,
};

fn free_found(list: []found) void = {
	for (let f .. list) {
		free(f.appid);
		free(f.name);
		free(f.lib);
	};
	free(list);
};

// Steam's own tools, not games.
fn is_tool(appid: str, name: str) bool = {
	for (let p .. ["Proton", "Steam Linux Runtime", "Steamworks Common", "Steam Runtime"]) {
		if (strings::hasprefix(name, p)) return true;
	};
	for (let id .. ["228980", "1070560", "1391110", "1628350", "1493710", "2180100", "961940",
			"1580130", "2348590", "2805730", "3658110", "1887720", "1826330"]) {
		if (appid == id) return true;
	};
	return false;
};

// The installed games of every library, by name.
fn installed_games() []found = {
	let out: []found = [];
	const libs = steam_libraries();
	defer strings::freeall(libs);
	for (let lib .. libs) {
		const dir = strings::concat(lib, "/steamapps")!;
		defer free(dir);
		const ents = match (os::readdir(dir)) {
		case let e: []fs::dirent => yield e;
		case => continue;
		};
		defer fs::dirents_free(ents);
		for (let e .. ents) {
			if (!strings::hasprefix(e.name, "appmanifest_") || !strings::hassuffix(e.name, ".acf")) continue;
			const p = strings::concat(dir, "/", e.name)!;
			defer free(p);
			const text = match (read_text(p)) {
			case let s: str => yield s;
			case void => continue;
			};
			defer free(text);
			let appid = "", name = "";
			let it = strings::tokenize(text, "\n");
			for (let line => strings::next_token(&it)) {
				let q: [2]str = ["", ""];
				if (quoted(line, q) != 2) continue;
				if (q[0] == "appid" && len(appid) == 0) appid = q[1];
				if (q[0] == "name" && len(name) == 0) name = q[1];
			};
			if (len(appid) == 0 || is_tool(appid, name)) continue;
			let dup = false;
			for (let f .. out) if (f.appid == appid) dup = true;
			if (dup) continue;
			append(out, found {
				appid = strings::dup(appid)!,
				name = unescape(if (len(name) > 0) name else appid),
				lib = strings::dup(lib)!,
			})!;
		};
	};
	sort::sort(out, size(found), &by_found_name)!;
	return out;
};

fn by_found_name(a: const *opaque, b: const *opaque) int = {
	const a = a: const *found, b = b: const *found;
	return strings::compare(a.name, b.name);
};

// Folder names that hold saves, any case: SaveGames, Saves, SAVEDATA ...
fn save_name(n: str) bool = {
	const l = ascii::strlower(n)!;
	defer free(l);
	for (let s .. ["savegames", "saves", "save", "savedata", "savedgames", "savegame", "saved_games"]) {
		if (l == s) return true;
	};
	return false;
};

// A save slot: Save1, save_2, Slot3 ...; its parent holds all the slots.
fn slot_name(n: str) bool = {
	const l = ascii::strlower(n)!;
	defer free(l);
	for (let p .. ["save", "slot", "profile"]) {
		if (!strings::hasprefix(l, p)) continue;
		const rest = strings::ltrim(strings::sub(l, len(p)), '_', ' ', '-');
		if (len(rest) == 0) continue;
		let digits = true;
		for (let c .. strings::toutf8(rest)) if (!ascii::isdigit(c: rune)) digits = false;
		if (digits) return true;
	};
	return false;
};

// Windows', Proton's and engines' own folders, never a game's saves.
fn junk_dir(n: str) bool = {
	const l = ascii::strlower(n)!;
	defer free(l);
	for (let j .. ["microsoft", "temp", "packages", "d3dscache", "nvidia", "nvidia corporation",
			"cache", "crashdumps", "crashreportclient", "logs", "config", "webcache", "steam",
			"public", "application data", "local settings", "desktop", "downloads", "music",
			"pictures", "videos", "templates", "start menu", "dxvk", "vkd3d", "mesa_shader_cache",
			"unity", "_debuginfo", "programs", "history", "openal", "my documents",
			"intel", "amd", "fontcache", "gamedvr", "unreal engine", "epicgameslauncher"]) {
		if (l == j) return true;
	};
	return false;
};

// Looks for a save folder under dir, depth levels down.
fn find_save_dir(dir: str, depth: int) (str | void) = {
	if (depth < 0) return;
	const ents = match (os::readdir(dir)) {
	case let e: []fs::dirent => yield e;
	case => return;
	};
	defer fs::dirents_free(ents);
	for (let e .. ents) {
		if (!fs::isdir(e.ftype) || e.name == "." || e.name == "..") continue;
		if (save_name(e.name)) return strings::concat(dir, "/", e.name)!;
		// Save1, Save2 ...: the folder they are in.
		if (slot_name(e.name) && depth < 4) return strings::dup(dir)!;
	};
	for (let e .. ents) {
		if (!fs::isdir(e.ftype) || e.name == "." || e.name == ".." || junk_dir(e.name)) continue;
		const sub = strings::concat(dir, "/", e.name)!;
		defer free(sub);
		match (find_save_dir(sub, depth - 1)) {
		case let s: str => return s;
		case void => void;
		};
	};
};

// The only real folder in dir (none or several: void).
fn only_dir(dir: str) (str | void) = {
	const ents = match (os::readdir(dir)) {
	case let e: []fs::dirent => yield e;
	case => return;
	};
	defer fs::dirents_free(ents);
	let one: (str | void) = void;
	for (let e .. ents) {
		if (!fs::isdir(e.ftype) || e.name == "." || e.name == ".." || junk_dir(e.name)) continue;
		if (one is str) {
			free(one as str);
			return;
		};
		one = strings::concat(dir, "/", e.name)!;
	};
	return one;
};

// When no folder is called save: a game's own folder. Unity games use
// LocalLow/<company>/<game>, others Local/<game> or Roaming/<game>, or
// Documents/My Games/<game>.
fn own_dir(user: str) (str | void) = {
	const ll = strings::concat(user, "/AppData/LocalLow")!;
	defer free(ll);
	match (only_dir(ll)) {
	case let company: str =>
		match (only_dir(company)) {
		case let g: str =>
			free(company);
			return g;
		case void => return company;
		};
	case void => void;
	};
	for (let sub .. ["AppData/Local", "AppData/Roaming", "Documents/My Games", "Saved Games"]) {
		const d = strings::concat(user, "/", sub)!;
		defer free(d);
		match (only_dir(d)) {
		case let g: str => return g;
		case void => void;
		};
	};
};

// A guess at where a game keeps its saves, or void.
fn guess_saves(appid: str, lib: str) (str | void) = {
	// The Proton prefix is in the game's library or Steam's own.
	let places: []str = [];
	defer strings::freeall(places);
	append(places, strings::dup(lib)!)!;
	const roots = steam_roots();
	defer strings::freeall(roots);
	for (let r .. roots) append(places, strings::dup(r)!)!;
	for (let p .. places) {
		const user = fmt::asprintf("{}/steamapps/compatdata/{}/pfx/drive_c/users/steamuser", p, appid)!;
		defer free(user);
		if (!os::exists(user)) continue;
		for (let sub .. ["AppData/LocalLow", "AppData/Local", "AppData/Roaming",
				"Documents", "Saved Games"]) {
			const d = strings::concat(user, "/", sub)!;
			defer free(d);
			match (find_save_dir(d, 4)) {
			case let s: str => return s;
			case void => void;
			};
		};
		match (own_dir(user)) {
		case let s: str => return s;
		case void => void;
		};
	};
	// Steam Cloud's copy.
	for (let r .. roots) {
		const ud = strings::concat(r, "/userdata")!;
		defer free(ud);
		const ents = match (os::readdir(ud)) {
		case let e: []fs::dirent => yield e;
		case => continue;
		};
		defer fs::dirents_free(ents);
		for (let e .. ents) {
			if (e.name == "." || e.name == "..") continue;
			const rem = fmt::asprintf("{}/{}/{}/remote", ud, e.name, appid)!;
			if (os::exists(rem)) return rem;
			free(rem);
		};
	};
};

// Writes a path with $HOME as ~, so games.txt reads well.
fn tilde(p: str) str = {
	const home = os::tryenv("HOME", "");
	if (len(home) > 1 && strings::hasprefix(p, home) && strings::hasprefix(strings::sub(p, len(home)), "/")) {
		return strings::concat("~", strings::sub(p, len(home)))!;
	};
	return strings::dup(p)!;
};

// Adds the installed games that aren't in games.txt (or hidden), with a
// guessed save folder. Returns how many were added and how many of those
// got a folder.
fn import_steam() (size, size) = {
	const list = installed_games();
	defer free_found(list);
	let added = 0z, with_dir = 0z;
	let changed = false;
	for (let f .. list) {
		// A known game without a save folder: guess again.
		match (find_game(f.appid)) {
		case let i: size =>
			if (len(GAMES[i].dirs) == 0) match (guess_saves(f.appid, f.lib)) {
			case let s: str =>
				append(GAMES[i].dirs, tilde(s))!;
				free(s);
				changed = true;
			case void => void;
			};
			continue;
		case void => void;
		};
		if (hidden(f.appid)) continue;
		append(GAMES, game {
			appid = strings::dup(f.appid)!,
			name = strings::dup(f.name)!,
			proc = "",
			...
		})!;
		match (guess_saves(f.appid, f.lib)) {
		case let s: str =>
			append(GAMES[len(GAMES) - 1].dirs, tilde(s))!;
			free(s);
			with_dir += 1;
		case void => void;
		};
		added += 1;
	};
	if (added > 0 || changed) save_games();
	if (added > 0) {
		let b: [96]u8 = [0...];
		log(fmt::bsprintf(b, "Steam-spil fundet: {} nye ({} med save-mappe)", added, with_dir)!);
	};
	return (added, with_dir);
};
