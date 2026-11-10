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

@test fn deleting_backups() void = {
	setup();
	let stamps: []str = [];
	defer strings::freeall(stamps);
	for (let i = 0; i < 4; i += 1) {
		put(tp("/game/saves/slot1.sav"), "x");
		append(stamps, backup_game(0, "") as str)!;
	};
	assert(len(stamps) == 4);
	// One by hand.
	assert(delete_backup("1172380", stamps[1]) is void);
	assert(delete_backup("1172380", stamps[1]) is failure);
	assert(delete_backup("1172380", "../x") is failure);
	assert(delete_backup("1172380", "") is failure);
	let bs = list_backups("1172380");
	assert(len(bs) == 3);
	free_backups(bs);
	const gone = fmt::asprintf("{}/hpo-saves/Saves/Steam/1172380/backups/{}", TROOT, stamps[1])!;
	defer free(gone);
	assert(!os::exists(gone));
	// Keep the newest two; 0 keeps all.
	assert(prune("1172380", 0) == 0);
	assert(prune("1172380", 2) == 1);
	let bs = list_backups("1172380");
	defer free_backups(bs);
	assert(len(bs) == 2 && bs[0].stamp == stamps[3] && bs[1].stamp == stamps[2]);
	assert(verify("1172380", stamps[3]) is void);
	// Settings.
	KEEP = 5;
	save_settings();
	KEEP = 10;
	load_settings();
	assert(KEEP == 5);
};

fn acf(lib: str, id: str, name: str) void = {
	put(fmt::asprintf("{}/steamapps/appmanifest_{}.acf", lib, id)!, fmt::asprintf(
		"\"AppState\"\n{{\n\t\"appid\"\t\t\"{}\"\n\t\"name\"\t\t\"{}\"\n\t\"installdir\"\t\t\"x\"\n}}\n", id, name)!);
};

@test fn finding_steam_games() void = {
	setup();
	free_games();
	save_games();
	os::setenv("HOME", tp("/home"))!;
	const root = tp("/home/.steam/debian-installation");
	const usb = tp("/media/tux/MONOHOSHIZAO21/SteamLibrary");
	put(strings::concat(root, "/steamapps/libraryfolders.vdf")!, fmt::asprintf(
		"\"libraryfolders\"\n{{\n\t\"0\"\n\t{{\n\t\t\"path\"\t\t\"{}\"\n\t}}\n"
		"\t\"1\"\n\t{{\n\t\t\"path\"\t\t\"{}\"\n\t\t\"apps\"\n\t\t{{\n\t\t\t\"2467880\"\t\t\"1\"\n\t\t}}\n\t}}\n}}\n",
		root, usb)!);
	acf(root, "2224740", "DreamWorks All-Star Kart Racing");
	acf(root, "1493710", "Proton Experimental");
	acf(usb, "2467880", "Fading Echo");
	acf(usb, "3525790", "PAW Patrol: Dino World");
	// Saves: Unreal in the Proton prefix on the USB disk, Steam Cloud for one.
	put(fmt::asprintf("{}/steamapps/compatdata/2467880/pfx/drive_c/users/steamuser/AppData/Local/FadingEcho/Saved/SaveGames/s.sav", usb)!, "x");
	put(fmt::asprintf("{}/steamapps/compatdata/2467880/pfx/drive_c/users/steamuser/AppData/Local/Microsoft/Saves/no.sav", usb)!, "x");
	put(strings::concat(root, "/userdata/12345/2224740/remote/a.sav")!, "x");
	const libs = steam_libraries();
	assert(len(libs) == 2);
	strings::freeall(libs);
	const fl = installed_games();
	assert(len(fl) == 3 && fl[0].name == "DreamWorks All-Star Kart Racing" && fl[1].name == "Fading Echo");
	free_found(fl);
	const (added, with_dir) = import_steam();
	assert(added == 3 && with_dir == 2);
	const i = find_game("2467880") as size;
	assert(strings::hassuffix(GAMES[i].dirs[0], "/AppData/Local/FadingEcho/Saved/SaveGames"));
	assert(strings::hasprefix(GAMES[i].dirs[0], "/tmp/"));
	const j = find_game("2224740") as size;
	assert(GAMES[j].dirs[0] == "~/.steam/debian-installation/userdata/12345/2224740/remote");
	assert(len(GAMES[find_game("3525790") as size].dirs) == 0);
	// Again: nothing new. Removed: not found again, until added by hand.
	assert(import_steam().0 == 0);
	remove_game(find_game("3525790") as size);
	load_settings();
	assert(hidden("3525790"));
	assert(import_steam().0 == 0 && find_game("3525790") is void);
	add_game("3525790", "PAW") as void;
	assert(!hidden("3525790"));
};

@test fn guessing_save_folders() void = {
	setup();
	os::setenv("HOME", tp("/home"))!;
	const lib = tp("/media/lib");
	const u = fmt::asprintf("{}/steamapps/compatdata", lib)!;
	const p = "pfx/drive_c/users/steamuser";
	// Death's Door: SAVEDATA, next to Unity.
	put(fmt::asprintf("{}/894020/{}/AppData/LocalLow/Acid Nerve/DeathsDoor/Unity/x", u, p)!, "x");
	put(fmt::asprintf("{}/894020/{}/AppData/LocalLow/Acid Nerve/DeathsDoor/SAVEDATA/s", u, p)!, "x");
	put(fmt::asprintf("{}/894020/{}/AppData/Local/dxvk/c", u, p)!, "x");
	// Another Crab's Treasure: Save1 -> its folder.
	put(fmt::asprintf("{}/1887840/{}/AppData/LocalLow/Aggro Crab/AnotherCrabsTreasure/Save1/s", u, p)!, "x");
	// Trash Goblin: Unity, no save name.
	put(fmt::asprintf("{}/2407830/{}/AppData/LocalLow/Spilt Milk Studios/TrashGoblin/data.json", u, p)!, "x");
	// Blades of Time: Local/<game>, beside dxvk.
	put(fmt::asprintf("{}/208670/{}/AppData/Local/BladesOfTime/_debuginfo/x", u, p)!, "x");
	put(fmt::asprintf("{}/208670/{}/AppData/Local/BladesOfTime/profile.sav", u, p)!, "x");
	put(fmt::asprintf("{}/208670/{}/AppData/Local/dxvk/c", u, p)!, "x");
	put(fmt::asprintf("{}/208670/{}/Documents/Music/.keep", u, p)!, "x");
	// Pumpkin Jack: nothing.
	os::mkdirs(fmt::asprintf("{}/1186640/{}/AppData/Local", u, p)!, fs::mode::USER_RWX)!;
	const want = [
		("894020", "/AppData/LocalLow/Acid Nerve/DeathsDoor/SAVEDATA"),
		("1887840", "/AppData/LocalLow/Aggro Crab/AnotherCrabsTreasure"),
		("2407830", "/AppData/LocalLow/Spilt Milk Studios/TrashGoblin"),
		("208670", "/AppData/Local/BladesOfTime"),
	];
	for (let w .. want) {
		const got = guess_saves(w.0, lib) as str;
		assert(strings::hassuffix(got, w.1));
		free(got);
	};
	assert(guess_saves("1186640", lib) is void);
	assert(slot_name("Save1") && slot_name("save_02") && slot_name("Slot3") && !slot_name("Saves") && !slot_name("Save"));
	assert(save_name("SAVEDATA") && save_name("SaveGames") && !save_name("Saved"));
};
