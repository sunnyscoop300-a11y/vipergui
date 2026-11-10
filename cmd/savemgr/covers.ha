// HPO STEAM SAVE MANAGER — covers from Steam.
//
// Steam keeps every game's pictures in appcache/librarycache: the poster
// (library_600x900.jpg) and a wide picture (library_hero.jpg). A missing
// one is fetched from Steam's picture server with curl. They are JPG, so
// ImageMagick (convert/magick) or ffmpeg turns them into the PNGs ViperGui
// reads: covers/<AppID>.png and covers/<AppID>-banner.png.
use fmt;
use os;
use strings;

// Steam's folders, on Linux and (through /mnt/c) in WSL.
fn steam_caches() []str = {
	let out: []str = [];
	const home = os::tryenv("HOME", "/root");
	const homes = [
		".steam/steam",
		".steam/debian-installation",
		".local/share/Steam",
		".var/app/com.valvesoftware.Steam/data/Steam",
		"snap/steam/common/.local/share/Steam",
	];
	for (let h .. homes) {
		append(out, fmt::asprintf("{}/{}/appcache/librarycache", home, h)!)!;
	};
	append(out, strings::dup("/mnt/c/Program Files (x86)/Steam/appcache/librarycache")!)!;
	append(out, strings::dup("/mnt/c/Program Files/Steam/appcache/librarycache")!)!;
	return out;
};

// Steam's own copy of a picture: <cache>/<appid>/.../<name> (new Steam)
// or <cache>/<appid>_<name> (old Steam).
fn find_cached(appid: str, name: str) (str | void) = {
	const caches = steam_caches();
	defer strings::freeall(caches);
	const (stem, ext) = strings::rcut(name, ".");
	for (let c .. caches) {
		const old = fmt::asprintf("{}/{}_{}", c, appid, name)!;
		if (os::exists(old)) return old;
		free(old);
		const dir = fmt::asprintf("{}/{}", c, appid)!;
		defer free(dir);
		let list: []str = [];
		defer strings::freeall(list);
		match (walk(dir, "", &list)) {
		case void => void;
		case => continue;
		};
		for (let rel .. list) {
			const (head, tail) = strings::rcut(rel, "/");
			const base = if (len(tail) == 0) head else tail;
			// library_600x900.jpg, or library_600x900_2x.jpg
			if (base == name || (strings::hasprefix(base, stem)
					&& strings::hassuffix(base, ext) && strings::hasprefix(strings::sub(base, len(stem)), "_"))) {
				return strings::concat(dir, "/", rel)!;
			};
		};
	};
};

// Set when the picture server can't be reached; reset by reload.
let offline = false;

// Steam's picture server, newest address first.
fn download(appid: str, name: str, to: str) bool = {
	const urls = [
		"https://shared.cloudflare.steamstatic.com/store_item_assets/steam/apps/{}/{}",
		"https://cdn.cloudflare.steamstatic.com/steam/apps/{}/{}",
		"https://steamcdn-a.akamaihd.net/steam/apps/{}/{}",
	];
	if (offline) return false;
	for (let u .. urls) {
		const url = fmt::asprintf(u, appid, name)!;
		defer free(url);
		match (run("curl", "-fsSL", "--connect-timeout", "4", "--max-time", "15", "-o", to, url)) {
		case let r: ([]u8, bool) =>
			defer free(r.0);
			if (r.1 && os::exists(to)) return true;
			// No net: don't keep the window waiting for every game.
			const e = strings::fromutf8_unsafe(r.0);
			if (strings::contains(e, "resolve") || strings::contains(e, "connect")
					|| strings::contains(e, "timed out")) {
				offline = true;
				return false;
			};
		case void => return false; // no curl
		};
	};
	return false;
};

// JPG to PNG, cut to w x h (0 = keep the size).
fn to_png(from: str, to: str, w: int, h: int) bool = {
	let gb: [32]u8 = [0...];
	const geo = fmt::bsprintf(gb, "{}x{}^", w, h)!;
	let ext: [32]u8 = [0...];
	const ex = fmt::bsprintf(ext, "{}x{}", w, h)!;
	for (let im .. ["magick", "convert"]) {
		const r = if (w == 0) run(im, from, to)
			else run(im, from, "-resize", geo, "-gravity", "center", "-extent", ex, to);
		match (r) {
		case let r: ([]u8, bool) =>
			free(r.0);
			if (r.1 && os::exists(to)) return true;
		case void => void;
		};
	};
	let vf: [96]u8 = [0...];
	const filt = fmt::bsprintf(vf, "scale={}:{}:force_original_aspect_ratio=increase,crop={}:{}", w, h, w, h)!;
	const r = if (w == 0) run("ffmpeg", "-y", "-loglevel", "error", "-i", from, to)
		else run("ffmpeg", "-y", "-loglevel", "error", "-i", from, "-vf", filt, to);
	match (r) {
	case let r: ([]u8, bool) =>
		free(r.0);
		return r.1 && os::exists(to);
	case void => return false;
	};
};

// Gets one picture for a game unless it is there. True if it is there now.
fn get_picture(appid: str, steam_name: str, out: str, w: int, h: int) bool = {
	if (os::exists(out)) return true;
	mkparent(out);
	match (find_cached(appid, steam_name)) {
	case let src: str =>
		defer free(src);
		if (to_png(src, out, w, h)) return true;
	case void => void;
	};
	const tmp = strings::concat(out, ".jpg")!;
	defer free(tmp);
	let ok = false;
	if (download(appid, steam_name, tmp)) ok = to_png(tmp, out, w, h);
	match (os::remove(tmp)) {
	case => void;
	};
	return ok;
};

// The poster and the banner for a game. True if either was new.
fn fetch_covers(appid: str) bool = {
	const poster = fmt::asprintf("covers/{}.png", appid)!;
	defer free(poster);
	const banner = fmt::asprintf("covers/{}-banner.png", appid)!;
	defer free(banner);
	const pp = path(poster), bp = path(banner);
	defer free(pp);
	defer free(bp);
	const had_p = os::exists(pp), had_b = os::exists(bp);
	if (had_p && had_b) return false;
	let new = false;
	if (!had_p && get_picture(appid, "library_600x900.jpg", pp, 300, 450)) new = true;
	if (!had_b) {
		// The wide hero picture, else the store header.
		if (get_picture(appid, "library_hero.jpg", bp, 898, 340)
				|| get_picture(appid, "header.jpg", bp, 898, 340)) new = true;
	};
	if (new) {
		let b: [64]u8 = [0...];
		log(fmt::bsprintf(b, "Cover hentet: {}", appid)!);
	};
	return new;
};
