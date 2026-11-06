// Just enough JSON for talking to OpenRouter: escaping strings for the
// request, and walking the response to pull out one string value.
use encoding::utf8;
use io;
use memio;
use strings;

// Writes s as a quoted JSON string.
fn json_str(out: io::handle, s: str) (void | io::error) = {
	memio::concat(out, "\"")?;
	let it = strings::iter(s);
	for (let r => strings::next(&it)) {
		switch (r) {
		case '"' => memio::concat(out, "\\\"")?;
		case '\\' => memio::concat(out, "\\\\")?;
		case '\n' => memio::concat(out, "\\n")?;
		case '\r' => memio::concat(out, "\\r")?;
		case '\t' => memio::concat(out, "\\t")?;
		case =>
			if (r: u32 < 0x20) {
				const hex = strings::toutf8("0123456789abcdef");
				const c = r: u32;
				memio::concat(out, "\\u00")?;
				memio::appendrune(out, hex[c >> 4]: rune)?;
				memio::appendrune(out, hex[c & 0xf]: rune)?;
			} else {
				memio::appendrune(out, r)?;
			};
		};
	};
	memio::concat(out, "\"")?;
};

type jsonerr = !void;

type parser = struct {
	s: []u8,
	i: size,
};

fn ws(p: *parser) void = {
	for (p.i < len(p.s)) {
		switch (p.s[p.i]) {
		case ' ', '\t', '\n', '\r' => p.i += 1;
		case => return;
		};
	};
};

fn peekc(p: *parser) (u8 | jsonerr) = {
	ws(p);
	if (p.i >= len(p.s)) return jsonerr;
	return p.s[p.i];
};

fn expect(p: *parser, c: u8) (void | jsonerr) = {
	if (peekc(p)? != c) return jsonerr;
	p.i += 1;
};

fn hexval(c: u8) (u32 | jsonerr) = {
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return jsonerr;
};

fn hex4(p: *parser) (u32 | jsonerr) = {
	if (p.i + 4 > len(p.s)) return jsonerr;
	let v = 0u32;
	for (let k = 0z; k < 4; k += 1) v = v << 4 | hexval(p.s[p.i + k])?;
	p.i += 4;
	return v;
};

// Parses a string. With out == null it is only skipped.
fn jstring(p: *parser, out: nullable *memio::stream) (void | jsonerr) = {
	expect(p, '"')?;
	for (true) {
		if (p.i >= len(p.s)) return jsonerr;
		const c = p.s[p.i];
		p.i += 1;
		if (c == '"') return;
		if (c != '\\') {
			match (out) {
			case let o: *memio::stream =>
				io::write(o, [c])!;
			case null => void;
			};
			continue;
		};
		if (p.i >= len(p.s)) return jsonerr;
		const e = p.s[p.i];
		p.i += 1;
		let r: rune = switch (e) {
		case 'n' => yield '\n';
		case 't' => yield '\t';
		case 'r' => yield '\r';
		case 'b' => yield '\b';
		case 'f' => yield '\f';
		case '/' => yield '/';
		case '\\' => yield '\\';
		case '"' => yield '"';
		case 'u' =>
			let v = hex4(p)?;
			// UTF-16 surrogate pair (emoji etc.).
			if (v >= 0xd800 && v < 0xdc00 && p.i + 6 <= len(p.s)
					&& p.s[p.i] == '\\' && p.s[p.i + 1] == 'u') {
				p.i += 2;
				const lo = hex4(p)?;
				v = 0x10000 + ((v - 0xd800) << 10) + (lo - 0xdc00);
			};
			yield v: rune;
		case => return jsonerr;
		};
		match (out) {
		case let o: *memio::stream =>
			io::write(o, utf8::encoderune(r))!;
		case null => void;
		};
	};
};

fn skip(p: *parser) (void | jsonerr) = {
	switch (peekc(p)?) {
	case '"' =>
		return jstring(p, null);
	case '{' =>
		p.i += 1;
		if (peekc(p)? == '}') { p.i += 1; return; };
		for (true) {
			jstring(p, null)?;
			expect(p, ':')?;
			skip(p)?;
			if (peekc(p)? == ',') { p.i += 1; continue; };
			return expect(p, '}');
		};
	case '[' =>
		p.i += 1;
		if (peekc(p)? == ']') { p.i += 1; return; };
		for (true) {
			skip(p)?;
			if (peekc(p)? == ',') { p.i += 1; continue; };
			return expect(p, ']');
		};
	case =>
		// Number, true, false, null.
		for (p.i < len(p.s)) {
			switch (p.s[p.i]) {
			case ',', '}', ']', ' ', '\n', '\r', '\t' => return;
			case => p.i += 1;
			};
		};
	};
};

// With p at an object, moves p to the value of key. Returns false if the
// key does not exist (p is then past the object).
fn key(p: *parser, k: str) (bool | jsonerr) = {
	expect(p, '{')?;
	if (peekc(p)? == '}') { p.i += 1; return false; };
	for (true) {
		let name = memio::dynamic();
		defer io::close(&name)!;
		jstring(p, &name)?;
		expect(p, ':')?;
		if (memio::string(&name)! == k) return true;
		skip(p)?;
		if (peekc(p)? == ',') { p.i += 1; continue; };
		expect(p, '}')?;
		return false;
	};
};

// With p at an array, moves p to its first element.
fn first(p: *parser) (bool | jsonerr) = {
	expect(p, '[')?;
	return peekc(p)? != ']';
};

// Reads the string at p into a new heap string.
fn take_string(p: *parser) (str | jsonerr) = {
	if (peekc(p)? != '"') return jsonerr;
	let out = memio::dynamic();
	match (jstring(p, &out)) {
	case jsonerr =>
		io::close(&out)!;
		return jsonerr;
	case void => void;
	};
	match (memio::string(&out)) {
	case let s: str =>
		return s; // ownership passes to the caller
	case utf8::invalid =>
		io::close(&out)!;
		return jsonerr;
	};
};

// An error message from the API (or about the response).
type apierr = !str;

// Gets choices[0].message.content from an OpenRouter response, or the API's
// error.message. Both results are heap strings owned by the caller.
fn parse_reply(body: []u8) (str | apierr) = {
	match (content(body)) {
	case let s: str => return s;
	case jsonerr => void;
	};
	match (errmsg(body)) {
	case let s: str =>
		// OpenRouter puts the real reason from the provider in
		// error.metadata.raw; show it too when it's there.
		match (errraw(body)) {
		case let raw: str =>
			const both = strings::concat(s, " - ", raw)!;
			free(s);
			free(raw);
			return both: apierr;
		case jsonerr =>
			return s: apierr;
		};
	case jsonerr => void;
	};
	return strings::dup("Uforståeligt svar fra serveren.")!: apierr;
};

fn content(body: []u8) (str | jsonerr) = {
	let p = parser { s = body, ... };
	if (!key(&p, "choices")?) return jsonerr;
	if (!first(&p)?) return jsonerr;
	if (!key(&p, "message")?) return jsonerr;
	if (!key(&p, "content")?) return jsonerr;
	return take_string(&p);
};

fn errmsg(body: []u8) (str | jsonerr) = {
	let p = parser { s = body, ... };
	if (!key(&p, "error")?) return jsonerr;
	if (!key(&p, "message")?) return jsonerr;
	return take_string(&p);
};

fn errraw(body: []u8) (str | jsonerr) = {
	let p = parser { s = body, ... };
	if (!key(&p, "error")?) return jsonerr;
	if (!key(&p, "metadata")?) return jsonerr;
	if (!key(&p, "raw")?) return jsonerr;
	return take_string(&p);
};
