// SAMLING — tests for samling.txt, the progress file and MEGA's table.
use io;
use memio;
use strings;

const TEST: str = "# en kommentar\n"
	"navn Lynholdet\ntitel Lynholdet Tracker\nminutter 20\n"
	"serie Lynholdet | 2020\nsæson 1\n"
	"afsnit 4. jan 2020 | Første lyn | Om noget\nafsnit 11. jan 2020 | Anden\n"
	"sæson Special\nafsnit 24. dec 2020 | Jul\n"
	"film Filmen | 2022 | 3. jun 2022 | 88\n"
	"serie Tom serie | 2023\n"
	"serie Lynholdet: Nye Helte | 2024\nafsnit 6. jan 2024 | Uden sæson\n"
	"ukendt linje\n";

@test fn collection() void = {
	parse_collection(TEST);
	assert(NAME == "Lynholdet" && TITLE == "Lynholdet Tracker" && EP_MIN == 20);
	assert(len(ENTRIES) == 3);     // the empty series is dropped
	const s = ENTRIES[0];
	assert(!s.film && s.year == "2020" && len(s.seasons) == 2 && len(s.eps) == 3);
	assert(s.eps[0].title == "Første lyn" && s.eps[0].desc == "Om noget");
	assert(s.eps[1].desc == "" && s.eps[2].aired == "24. dec 2020");
	assert(s.seasons[1].label == "Special" && s.seasons[1].first == 2 && s.seasons[1].n == 1);
	assert(ENTRIES[1].film && ENTRIES[1].minutes == 88 && ENTRIES[1].aired == "3. jun 2022");
	assert(nep(1) == 1);
	assert(len(ENTRIES[2].seasons) == 1 && ENTRIES[2].seasons[0].label == "1");
	assert(season_of(0, 2) == 1 && season_of(0, 1) == 0);
	let b: [32]u8 = [0...];
	assert(season_name(b, "2") == "Sæson 2" && season_name(b, "Special") == "Special");
	assert(side_name(0) == "Lynholdet (Serie)" && side_name(2) == "Nye Helte");
};

@test fn progress_round_trip() void = {
	parse_collection(TEST);
	let p = progress { ... };
	p.seen[0][0] = 1700000000;
	p.seen[0][2] = 1700000500;     // the special
	p.seen[1][0] = 1700001000;     // the film
	p.synced = 1700002000;
	assert(nseen(&p, 0) == 2 && nseen_season(&p, 0, 0) == 1 && next_ep(&p, 0) == 1);
	assert(minutes_seen(&p) == 2 * 20 + 88);
	let out = memio::dynamic();
	defer io::close(&out)!;
	write(&out, &p)!;
	const text = strings::fromutf8(memio::buffer(&out))!;
	assert(strings::contains(text, "set 1700000500 | Lynholdet | Jul\n"));
	assert(strings::contains(text, "film 1700001000 | Filmen\n"));
	let q = progress { ... };
	parse(&q, text);
	assert(q.seen[0][0] == 1700000000 && q.seen[0][2] == 1700000500);
	assert(q.seen[1][0] == 1700001000 && q.synced == 1700002000);
	// Old lines (by position) that don't fit the collection are skipped.
	parse(&q, "set 1 9 1 5\nset 9 1 1 5\nset 1 1 7 5\nfilm 1 5\n");
	assert(nseen(&q, 0) == 2);
	// Old lines that fit are read.
	let o = progress { ... };
	parse(&o, "set 1 2 1 77\nfilm 2 88\n");
	assert(o.seen[0][2] == 77 && o.seen[1][0] == 88);
};

@test fn marks_follow_titles() void = {
	parse_collection(TEST);
	let p = progress { ... };
	p.seen[0][1] = 11;             // "Anden"
	p.seen[0][2] = 22;             // "Jul"
	let out = memio::dynamic();
	defer io::close(&out)!;
	write(&out, &p)!;
	const text = strings::fromutf8(memio::buffer(&out))!;
	// samling.txt reordered: Jul first, Anden renamed a little, and a
	// title that is gone.
	parse_collection("navn Lynholdet\nserie Lynholdet | 2020\nsæson 1\n"
		"afsnit x | Jul\nafsnit x | Første lyn\nafsnit x | ANDEN!\n");
	let q = progress { ... };
	parse(&q, text);
	assert(q.seen[0][0] == 22 && q.seen[0][1] == 0 && q.seen[0][2] == 11);
	parse(&q, "set 33 | Lynholdet | Væk nu\nset 44 | Ukendt serie | Jul\n");
	assert(len(q.extra) == 2);
	// The marks samling.txt can't place are kept in the file.
	let out2 = memio::dynamic();
	defer io::close(&out2)!;
	write(&out2, &q)!;
	const text2 = strings::fromutf8(memio::buffer(&out2))!;
	assert(strings::contains(text2, "set 33 | Lynholdet | Væk nu\n"));
	// Two episodes with the same title: two marks, both found.
	parse_collection("navn L\nserie L | 1\nafsnit x | Del\nafsnit x | Del\n");
	let d = progress { ... };
	parse(&d, "set 1 | L | Del\nset 2 | L | Del\n");
	assert(d.seen[0][0] == 1 && d.seen[0][1] == 2);
	assert(same_name("Æble: Del 1!", "æble del 1") == false);
	assert(same_name("Phoebe vs. Max", "phoebe VS max"));
};

@test fn mega_table() void = {
	const t = "ID          LOCALPATH                 REMOTEPATH RUN_STATE STATUS  ERROR SIZE\n"
		"PSXVzmD1Odw /home/tux/.local/share/samling /Mit  Running   Synced NO    2.14 MB\n";
	let b: [48]u8 = [0...];
	assert(sync_state(b, t, "/home/tux/.local/share/samling") == "Synced");
	assert(sync_state(b, t, "/andet") == "mappen synkroniseres ikke");
	const short = "ID LOCALPATH REMOTEPATH RUN_STATE STATUS\n"
		"Ab1 /home/tux/.local/...re/samling /Andet Running Pending NO\n";
	assert(sync_state(b, short, "/home/tux/.local/share/samling") == "Pending");
	const remote = "Ab1 /x/y /Samling Running Synced NO\n";
	assert(sync_state(b, remote, "/home/tux/.local/share/samling") == "Synced");
	assert(!same_path("/home/...zzz", "/home/tux/samling"));
};

@test fn wrapping() void = {
	let l: [3]str = [""...];
	assert(wrap("Lynholdet Nord (Serie)", 120, l) == 2);
	assert(l[0] == "Lynholdet Nord" && l[1] == "(Serie)");
	assert(wrap("  ", 120, l) == 0);
	assert(wrap("Superkalifragilistiskekspialidoes", 40, l) == 1);
	assert(slug("Lynholdet: Nye Helte!") == "lynholdet-nye-helte");
};

@test fn mega_answers() void = {
	let b: [64]u8 = [0...];
	assert(last_line(b, "noget\n[2026-11-09_22-07-02.594221 cmd ERR  Not logged in.]\n\n")
		== "Not logged in.");
	assert(last_line(b, "Invalid email or password\n") == "Invalid email or password");
	assert(last_line(b, "") == "intet svar");
};
