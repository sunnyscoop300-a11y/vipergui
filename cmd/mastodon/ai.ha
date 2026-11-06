// Talking to OpenRouter. curl runs as a background process so the window
// keeps animating while Mastodon "thinks"; each frame we peek to see if
// it has finished.
use fmt;
use fs;
use io;
use memio;
use os;
use os::exec;
use strings;
use temp;

def DEFAULT_MODEL: str = "google/gemini-4-argon";
def DEFAULT_URL: str = "https://openrouter.ai/api/v1/chat/completions";

// Format rules always sent along with the persona.
def RULES: str = "Svar altid i ren tekst: ingen markdown, ingen stjerner, "
	"ingen lister og ingen emojis. Hold svarene korte og levende, "
	"højst omkring 80 ord, medmindre brugeren beder om mere.";

// Only the newest messages are sent, to keep requests small.
def MAX_HISTORY: size = 30;

type request = struct {
	proc: exec::process,
	outpath: [256]u8,
	outlen: size,
	hdrpath: [256]u8,
	hdrlen: size,
	reqpath: [256]u8,
	reqlen: size,
};

fn keep(buf: *[256]u8, n: *size, s: str) void = {
	const b = strings::toutf8(s);
	buf[..len(b)] = b;
	*n = len(b);
};

fn keep_fmt(buf: *[256]u8, n: *size, base: str, ext: str) void = {
	const s = strings::concat(base, ext)!;
	defer free(s);
	keep(buf, n, s);
};

fn path_of(buf: *[256]u8, n: size) str = strings::fromutf8_unsafe(buf[..n]);

// Writes a file only the user can read (it may contain the API key).
fn write_private(path: str, data: []u8) (void | fs::error | io::error) = {
	const f = os::create(path, fs::mode::USER_RW)?;
	defer io::close(f)!;
	io::writeall(f, data)?;
};

// Starts a chat completion for the conversation. Returns an error message
// on failure.
fn ai_start(c: *chat, apikey: str) (request | str) = {
	const model = os::tryenv("MASTODON_MODEL", DEFAULT_MODEL);
	const url = os::tryenv("MASTODON_API_URL", DEFAULT_URL);

	// Request body.
	let body = memio::dynamic();
	defer io::close(&body)!;
	fmt::fprint(&body, "{\"model\":")!;
	json_str(&body, model)!;
	fmt::fprint(&body, ",\"messages\":[{\"role\":\"system\",\"content\":")!;
	let sys = memio::dynamic();
	defer io::close(&sys)!;
	memio::concat(&sys, c.persona, "\n\n", RULES)!;
	json_str(&body, memio::string(&sys)!)!;
	fmt::fprint(&body, "}")!;

	const from = if (len(c.msgs) > MAX_HISTORY) len(c.msgs) - MAX_HISTORY else 0z;
	let seen_user = false;
	for (let m .. c.msgs[from..]) {
		if (m.kind == kind::INFO) continue;
		// Gemini wants the conversation to start with the user, so skip
		// Mastodon's greeting (and anything else before the first question).
		if (m.kind == kind::USER) seen_user = true;
		if (!seen_user) continue;
		// memio::concat, not fmt::fprint: fprint puts spaces between
		// its arguments, which would send the role " user ".
		memio::concat(&body, ",{\"role\":\"",
			if (m.kind == kind::USER) "user" else "assistant",
			"\",\"content\":")!;
		json_str(&body, m.text)!;
		fmt::fprint(&body, "}")!;
	};
	fmt::fprint(&body, "]}")!;

	// Temp files: headers (with the key), body, and the response.
	let r = request { ... };
	const base = fmt::asprintf("{}/mastodon-{}-{}", temp::dir(),
		exec::self(): int, c.nrequests)!;
	defer free(base);
	c.nrequests += 1;
	keep_fmt(&r.hdrpath, &r.hdrlen, base, ".hdr");
	keep_fmt(&r.reqpath, &r.reqlen, base, ".json");
	keep_fmt(&r.outpath, &r.outlen, base, ".out");
	const hdr = path_of(&r.hdrpath, r.hdrlen);
	const req = path_of(&r.reqpath, r.reqlen);
	const out = path_of(&r.outpath, r.outlen);

	let hdrs = memio::dynamic();
	defer io::close(&hdrs)!;
	fmt::fprintf(&hdrs, "Authorization: Bearer {}\n"
		"Content-Type: application/json\n"
		"X-Title: Mastodon (ViperGui)\n", apikey)!;
	match (write_private(hdr, memio::buffer(&hdrs))) {
	case void => void;
	case => return "kunne ikke skrive temp-fil";
	};
	// MASTODON_DEBUG=1 saves the request (without the key) for inspection.
	if (os::getenv("MASTODON_DEBUG") is str) {
		match (os::remove("mastodon-request.json")) { case => void; };
		match (write_private("mastodon-request.json", memio::buffer(&body))) {
		case => void;
		};
	};
	match (write_private(req, memio::buffer(&body))) {
	case void => void;
	case => cleanup(&r); return "kunne ikke skrive temp-fil";
	};

	const harg = strings::concat("@", hdr)!;
	defer free(harg);
	const darg = strings::concat("@", req)!;
	defer free(darg);
	let cmd = match (exec::cmd("curl", "-sS", "--max-time", "90",
			"-H", harg, "--data-binary", darg, "-o", out, url)) {
	case let cmd: exec::command =>
		yield cmd;
	case =>
		cleanup(&r);
		return "curl blev ikke fundet (sudo apt install curl)";
	};
	exec::nullstd(&cmd)!;
	match (exec::start(&cmd)) {
	case let p: exec::process =>
		r.proc = p;
	case let e: exec::error =>
		cleanup(&r);
		return "kunne ikke starte curl";
	};
	return r;
};

// Checks whether the request has finished. Returns void while it is still
// running, otherwise the reply (or an error message, as apierr).
fn ai_poll(r: *request) (void | str | apierr) = {
	match (exec::peek(&r.proc)) {
	case void =>
		return;
	case let st: exec::status =>
		const out = path_of(&r.outpath, r.outlen);
		const ok = exec::check(&st) is void;
		const data = match (os::open(out)) {
		case let f: io::file =>
			defer io::close(f)!;
			yield match (io::drain(f)) {
			case let d: []u8 => yield d;
			case io::error => yield []: []u8;
			};
		case =>
			yield []: []u8;
		};
		defer free(data);
		cleanup(r);
		if (!ok || len(data) == 0) {
			return strings::dup("Ingen forbindelse til OpenRouter "
				"(tjek internet eller MASTODON_API_URL).")
				: apierr;
		};
		return parse_reply(data);
	case exec::error =>
		cleanup(r);
		return strings::dup("Fejl mens jeg ventede på curl."): apierr;
	};
};

// Stops a running request (e.g. when the window closes).
fn ai_cancel(r: *request) void = {
	match (exec::kill(r.proc)) { case => void; };
	match (exec::wait(&r.proc)) { case => void; };
	cleanup(r);
};

fn cleanup(r: *request) void = {
	match (os::remove(path_of(&r.hdrpath, r.hdrlen))) { case => void; };
	match (os::remove(path_of(&r.reqpath, r.reqlen))) { case => void; };
	match (os::remove(path_of(&r.outpath, r.outlen))) { case => void; };
};
