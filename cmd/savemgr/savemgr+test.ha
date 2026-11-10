// HPO STEAM SAVE MANAGER — tests of the backup engine, on files in /tmp.
use fmt;
use fs;
use io;
use memio;
use os;
use strings;

def TROOT: str = "/tmp/hpo-savemgr-test";

fn tp(x: str) str = strings::concat(TROOT, x)!;

fn put(p: str, text: str) void = {
	mkparent(p);
	write_file(p, text)!;
};

fn get(p: str) str = match (read_text(p)) {
case let s: str => yield s;
case void => yield strings::dup("(mangler)")!;
};

// A clean test area with one game whose saves are in two folders.
fn setup() void = {
	match (os::rmdirall(TROOT)) {
	case => void;
	};
	os::setenv("XDG_DATA_HOME", TROOT)!;
	data_dir_len = 0;
	free_games();
	put(tp("/game/saves/slot1.sav"), "level 3");
	put(tp("/game/saves/sub/opts.ini"), "volume=7");
	put(tp("/game/more/cloud.dat"), "x");
	add_game("1172380", "Death's Door") as void;
	append(GAMES[0].dirs, strings::dup(tp("/game/saves"))!)!;
	append(GAMES[0].dirs, strings::dup(tp("/game/more"))!)!;
	save_games();
};

@test fn backup_and_restore() void = {
	setup();
	// A backup.
	const s1 = backup_game(0, "") as str;
	let bs = list_backups("1172380");
	assert(len(bs) == 1 && bs[0].stamp == s1 && bs[0].files == 3 && bs[0].version == 1);
	assert(bs[0].sz == 7 + 8 + 1);
	free_backups(bs);
	assert(verify("1172380", s1) is void);
	// The game plays on, the saves change.
	put(tp("/game/saves/slot1.sav"), "level 9 (ødelagt)");
	os::remove(tp("/game/more/cloud.dat"))!;
	put(tp("/game/saves/new.sav"), "ny");
	// Back to the backup.
	const before = restore(0, s1) as str;
	assert(get(tp("/game/saves/slot1.sav")) == "level 3");
	assert(get(tp("/game/saves/sub/opts.ini")) == "volume=7");
	assert(get(tp("/game/more/cloud.dat")) == "x");
	assert(!os::exists(tp("/game/saves/new.sav")));
	// What was there before is a backup of its own, and newest.
	let bs = list_backups("1172380");
	assert(len(bs) == 2 && bs[0].stamp == before && bs[0].note == "før gendannelse");
	assert(bs[0].version == 2);
	free_backups(bs);
	assert(verify("1172380", before) is void);
	// The log tells.
	const lines = log_tail(10);
	assert(len(lines) == 3);
	assert(strings::contains(lines[0], "Save gendannet: Death's Door"));
	assert(strings::contains(lines[2], "Backup oprettet: Death's Door"));
};

@test fn damaged_backups_are_found() void = {
	setup();
	const s = backup_game(0, "") as str;
	const p = fmt::asprintf("{}/game-x", TROOT)!;
	free(p);
	const f = fmt::asprintf("{}/hpo-saves/Saves/Steam/1172380/backups/{}/0/slot1.sav", TROOT, s)!;
	put(f, "level 99");
	assert(verify("1172380", s) is failure);
	// And it isn't restored.
	put(tp("/game/saves/slot1.sav"), "level 5");
	assert(restore(0, s) is failure);
	assert(get(tp("/game/saves/slot1.sav")) == "level 5");
	os::remove(f)!;
	assert(strings::contains(verify("1172380", s) as failure, "mangler"));
};

@test fn nothing_to_back_up() void = {
	setup();
	GAMES[0].dirs[0] = strings::dup(tp("/game/findes-ikke"))!;
	assert(backup_game(0, "") is failure);
	free(GAMES[0].dirs[0]);
	GAMES[0].dirs[0] = strings::dup(tp("/game/tom"))!;
	free(GAMES[0].dirs[1]);
	GAMES[0].dirs[1] = strings::dup(tp("/game/tom"))!;
	os::mkdirs(tp("/game/tom"), fs::mode::USER_RWX)!;
	assert(strings::hasprefix(backup_game(0, "") as failure, "ingen save-filer"));
	assert(len(list_backups("1172380")) == 0);
};

@test fn games_file() void = {
	setup();
	load_games();
	assert(len(GAMES) == 1 && GAMES[0].name == "Death's Door" && len(GAMES[0].dirs) == 2);
	assert(add_game("1172380", "igen") is str);
	assert(add_game("abc", "x") is str);
	assert(add_game("", "x") is str);
	add_game("  242050 ", "") as void;
	assert(GAMES[1].appid == "242050" && GAMES[1].name == "242050");
	GAMES[1].star = true;
	GAMES[1].proc = strings::dup("Rayman.exe")!;
	save_games();
	load_games();
	assert(len(GAMES) == 2 && GAMES[1].star && GAMES[1].proc == "Rayman.exe");
};

@test fn paths() void = {
	assert(local_path("C:\\Users\\Bossun\\AppData\\LocalLow\\Acid Nerve\\Death's Door\\")
		== "/mnt/c/Users/Bossun/AppData/LocalLow/Acid Nerve/Death's Door");
	assert(local_path("/home/tux/x") == "/home/tux/x");
	assert(!safe_target("/"));
	assert(!safe_target("/mnt/c"));
	assert(!safe_target("/mnt/c/Users"));
	assert(!safe_target("/home/tux/../tux/a/b"));
	assert(safe_target("/mnt/c/Users/Bossun/AppData"));
	let b: [32]u8 = [0...];
	assert(size_text(b, 512) == "512 B");
	assert(size_text(b, 13002342) == "12.4 MB");
	assert(size_text(b, 1536) == "1.5 KB");
};

@test fn mega_answers() void = {
	let b: [64]u8 = [0...];
	const (s, f) = parse_df(b, "Account balance:\nUSED STORAGE:    312.62 GB  31.26% of 1.00 TB\n");
	assert(s == "312.62 GB / 1.00 TB (31%)" && f > 0.312 && f < 0.313);
	const t = "ID LOCALPATH REMOTEPATH RUN_STATE STATUS\n"
		"Ab1 /home/tux/.local/...hpo-saves/Saves /HPO/Saves Running Synced NO\n";
	assert(sync_state(b, t, "/home/tux/.local/share/hpo-saves/Saves") == "Synced");
	assert(sync_state(b, "ID LOCALPATH\n", "/x") == NOT_SYNCED);
	assert(last_line(b, "x\n[2026 cmd ERR  Not logged in.]\n") == "Not logged in.");
};

@test fn steam_cache() void = {
	setup();
	os::setenv("HOME", tp("/home"))!;
	const lc = tp("/home/.steam/steam/appcache/librarycache");
	put(strings::concat(lc, "/242550/a1b2/library_hero.jpg")!, "hero");
	put(strings::concat(lc, "/242550/library_600x900_2x.jpg")!, "poster");
	put(strings::concat(lc, "/229540_library_600x900.jpg")!, "old");
	assert(strings::hassuffix(find_cached("242550", "library_hero.jpg") as str, "/242550/a1b2/library_hero.jpg"));
	assert(strings::hassuffix(find_cached("242550", "library_600x900.jpg") as str, "/library_600x900_2x.jpg"));
	assert(strings::hassuffix(find_cached("229540", "library_600x900.jpg") as str, "/229540_library_600x900.jpg"));
	assert(find_cached("229540", "header.jpg") is void);
	// New Steam: the poster is library_capsule in a hashed folder, and the
	// blurred hero is not the hero.
	put(strings::concat(lc, "/2467880/91aac599/library_capsule.jpg")!, "capsule");
	put(strings::concat(lc, "/2467880/18/library_hero_blur.jpg")!, "blur");
	assert(strings::hassuffix(find_cached("2467880", "library_capsule.jpg") as str, "/91aac599/library_capsule.jpg"));
	assert(find_cached("2467880", "library_hero.jpg") is void);
	assert(find_cached("1", "header.jpg") is void);
};
