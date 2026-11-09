// EPISODER — tests for the tracker's data and its files.
use io;
use memio;
use strings;

@test fn progress_counts() void = {
	test_show();
	let p = progress { ... };
	assert(nseen(&p) == 0 && next_ep(&p) == 0);
	p.seen[0] = 1;
	p.seen[1] = 1;
	p.seen[13] = 1;
	assert(nseen(&p) == 3);
	assert(nseen_part(&p, 0) == 2 && nseen_part(&p, 1) == 1);
	assert(next_ep(&p) == 2);
	for (let i = 0z; i < NEP; i += 1) p.seen[i] = 1;
	assert(next_ep(&p) == NEP);
};

@test fn file_round_trip() void = {
	test_show();
	let p = progress { ... };
	p.seen[0] = 1700000000;
	p.seen[11] = 1700001234;
	set_note(&p, 3, "God episode æøå");
	set_folder(&p, "/home/tux/Videos/Serie");
	let out = memio::dynamic();
	defer io::close(&out)!;
	write(&out, &p)!;
	const text = strings::fromutf8(memio::buffer(&out))!;

	let q = progress { ... };
	parse(&q, text);
	assert(q.seen[0] == 1700000000 && q.seen[11] == 1700001234);
	assert(nseen(&q) == 2);
	assert(note(&q, 3) == "God episode æøå");
	assert(folder(&q) == "/home/tux/Videos/Serie");
	// Rubbish and out-of-range lines are skipped.
	parse(&q, "set 0 5\nset 99 5\nnote x hej\nset 5 abc\n");
	assert(q.seen[4] == 1);
};

@test fn notes_cut_on_characters() void = {
	let buf: [5]u8 = [0...];
	assert(copy_utf8(buf, "abcdæ") == 4);   // æ is two bytes: left out
	assert(copy_utf8(buf, "abc") == 3);
};

@test fn weeks() void = {
	let p = progress { ... };
	const t = now();
	p.seen[0] = t - 60;                     // this week
	p.seen[1] = t - 8 * 24 * 3600;          // last week
	p.seen[2] = t - 30 * 24 * 3600;         // 4 weeks ago
	let w: [8]int = [0...];
	per_week(&p, 8, w);
	assert(w[7] == 1 && w[6] == 1 && w[3] == 1);
};

// A made-up series of 24 episodes in parts of 12.
fn test_show() void = {
	let text = strings::dup("navn Test Serie\nminutter 20\ndel 12\n")!;
	for (let i = 0; i < 24; i += 1) {
		const t = strings::concat(text, "afsnit 1. jan 2000 | Afsnit\n")!;
		free(text);
		text = t;
	};
	parse_show(text);       // the series keeps pointing into text
};

@test fn series_file() void = {
	parse_show("# en kommentar\nnavn Min Serie!\ngenrer Eventyr\når 2024\n"
		"studie Et Studie\nminutter 25\ndel 2\n"
		"afsnit 4. jan 2024 | Den første\nafsnit 11. jan 2024 |  Den anden \n"
		"afsnit 18. jan 2024 | Den tredje\nukendt linje\n");
	assert(SERIES == "Min Serie!" && GENRES == "Eventyr" && YEAR == "2024");
	assert(STUDIO == "Et Studie" && EP_MIN == 25 && PER == 2);
	assert(NEP == 3 && nparts() == 2);
	assert(part_len(0) == 2 && part_len(1) == 1 && part_len(2) == 0);
	assert(EPISODES[1].title == "Den anden" && EPISODES[1].aired == "11. jan 2024");
	assert(strings::hassuffix(progress_path("/x"), "/min-serie"));
};
