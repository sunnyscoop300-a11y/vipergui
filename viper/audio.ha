// ViperGui — audio. Sounds are mixed in Hare and streamed as raw 16-bit
// mono PCM through a pipe into a small player program (pw-cat on PipeWire,
// else paplay or aplay). No C libraries are linked; if no player is found
// the game simply stays silent.
//
//	const snd = viper::audio_open();
//	const blip = viper::tone(viper::wave::SINE, 600.0, 900.0, 0.1, 0.5, 0.005);
//	viper::play(snd, &blip, 1.0, 1.0);
//	// ...and once per frame:
//	viper::audio_pump(snd);
use endian;
use io;
use math;
use os;
use os::exec;
use rt;
use strings;
use unix::signal;

export def AUDIO_RATE: int = 44100;
def LEAD: u64 = 2646;           // keep ~60 ms buffered ahead of real time
def NVOICES: size = 24;

// A mono sound at AUDIO_RATE, samples in -1.0 .. 1.0.
export type sound = struct {
	samples: []f32,
};

// One playing sound (internal to the mixer).
export type voice = struct {
	snd: nullable *sound,
	pos: f64,
	step: f64,
	vol: f32,
};

export type audio = struct {
	ok: bool,
	proc: exec::process,
	fd: io::file,
	player: size,      // index into players (for falling back)
	start_ms: u64,
	written: u64,      // samples sent to the player
	voices: [NVOICES]voice,
	volume: f32,
	muted: bool,
	buf: [4096]u8,
	// Samples an app streams in (see [[audio_stream]]), played as they come.
	stream: []f32,
	spos: size,
};

// Players tried in order; each reads raw s16le mono 44100 Hz from stdin.
const players: [3][]str = [
	["pw-cat", "--playback", "--raw", "--rate=44100", "--channels=1",
		"--format=s16", "--latency=40ms", "-"],
	["paplay", "--raw", "--format=s16le", "--rate=44100", "--channels=1",
		"--latency-msec=40"],
	["aplay", "-q", "-t", "raw", "-f", "S16_LE", "-r", "44100", "-c", "1",
		"-B", "60000"],
];

// Starts audio output. Never fails: without a player it is silent.
// VIPER_AUDIO_PLAYER=program uses another player (raw PCM on stdin);
// VIPER_AUDIO=off disables sound.
export fn audio_open() *audio = {
	let a = alloc(audio { volume = 0.6, ... })!;
	if (os::tryenv("VIPER_AUDIO", "") == "off") return a;
	// A player that quits must not take the game down with SIGPIPE.
	signal::ignore(signal::sig::PIPE);
	start_player(a, 0);
	return a;
};

fn start_player(a: *audio, from: size) void = {
	a.ok = false;
	match (os::getenv("VIPER_AUDIO_PLAYER")) {
	case let p: str =>
		if (from == 0) {
			const argv: [1]str = [p];
			if (spawn(a, argv)) a.player = len(players);
		};
		return;
	case void => void;
	};
	for (let i = from; i < len(players); i += 1) {
		if (spawn(a, players[i])) {
			a.player = i;
			return;
		};
	};
};

fn spawn(a: *audio, argv: []str) bool = {
	match (exec::lookup(argv[0])) {
	case str => void;
	case => return false;
	};
	const (rd, wr) = exec::pipe();
	let cmd = match (exec::cmd(argv[0], argv[1..]...)) {
	case let c: exec::command => yield c;
	case =>
		match (io::close(rd)) { case => void; };
		match (io::close(wr)) { case => void; };
		return false;
	};
	exec::nullstd(&cmd)!;
	exec::addfile(&cmd, os::stdin_file, rd)!;
	match (exec::start(&cmd)) {
	case let p: exec::process =>
		a.proc = p;
	case exec::error =>
		match (io::close(rd)) { case => void; };
		match (io::close(wr)) { case => void; };
		return false;
	};
	match (io::close(rd)) { case => void; };
	// Never let a full pipe stall the game.
	const fl = match (rt::fcntl(wr: int, rt::F_GETFL, void)) {
	case let f: int => yield f;
	case rt::errno => yield 0;
	};
	match (rt::fcntl(wr: int, rt::F_SETFL, fl | rt::O_NONBLOCK)) {
	case => void;
	};
	a.fd = wr;
	a.ok = true;
	a.start_ms = now_ms();
	a.written = 0;
	return true;
};

// Stops the player.
export fn audio_close(a: *audio) void = {
	free(a.stream);
	if (a.ok) {
		match (io::close(a.fd)) { case => void; };
		match (exec::wait(&a.proc)) { case => void; };
	};
	free(a);
};

// Mutes or unmutes everything.
export fn set_muted(a: *audio, m: bool) void = a.muted = m;
export fn is_muted(a: *audio) bool = a.muted;

// Plays a sound. vol is 0..1, pitch 1.0 = normal (2.0 = an octave up).
export fn play(a: *audio, s: *sound, vol: f64, pitch: f64) void = {
	if (!a.ok || len(s.samples) == 0) return;
	// A free voice, or else the one closest to finishing.
	let best = 0z, left = 1.0e30;
	for (let i = 0z; i < NVOICES; i += 1) {
		const v = &a.voices[i];
		const rest = match (v.snd) {
		case null => yield -1.0;
		case let sn: *sound => yield (len(sn.samples): f64 - v.pos) / v.step;
		};
		if (rest < left) {
			left = rest;
			best = i;
		};
	};
	a.voices[best] = voice { snd = s, pos = 0.0, step = pitch, vol = vol: f32 };
};

// Streams samples (mono, AUDIO_RATE, -1..1) to be played after what was
// streamed before: for emulators and synthesizers that make their sound as
// they go. Keeps at most a quarter of a second waiting, so a slow frame
// doesn't build up lag.
export fn audio_stream(a: *audio, samples: []f32) void = {
	if (!a.ok) return;
	if (a.spos > 0) {
		delete(a.stream[..a.spos]);
		a.spos = 0;
	};
	append(a.stream, samples...)!;
	const most = AUDIO_RATE: size / 4;
	if (len(a.stream) > most) delete(a.stream[..len(a.stream) - most]);
};

// Feeds the player; call once per frame.
export fn audio_pump(a: *audio) void = {
	if (!a.ok) return;
	// If the player died (e.g. pw-cat without --raw support), try the next.
	match (exec::peek(&a.proc)) {
	case void => void;
	case =>
		match (io::close(a.fd)) { case => void; };
		if (a.player < len(players)) start_player(a, a.player + 1)
		else a.ok = false;
		return;
	};
	const elapsed = (now_ms() - a.start_ms) * AUDIO_RATE: u64 / 1000;
	let target = elapsed + LEAD;
	if (target <= a.written) return;
	// After a long stall don't try to catch up; just carry on.
	if (target - a.written > AUDIO_RATE: u64 / 4) a.written = target - LEAD;

	for (a.written < target) {
		let n = (target - a.written): size;
		if (n > len(a.buf) / 2) n = len(a.buf) / 2;
		mixdown(a, n);
		match (io::write(a.fd, a.buf[..n * 2])) {
		case let w: size =>
			a.written += w: u64 / 2;
			if (w < n * 2) return; // pipe full
		case io::error =>
			return; // EAGAIN (pipe full) or the player is gone
		};
	};
};

fn mixdown(a: *audio, n: size) void = {
	const gain = if (a.muted) 0.0f32 else a.volume;
	for (let i = 0z; i < n; i += 1) {
		let acc = 0.0f32;
		for (let k = 0z; k < NVOICES; k += 1) {
			let v = &a.voices[k];
			const s = match (v.snd) {
			case null => continue;
			case let s: *sound => yield s;
			};
			const p = v.pos: size;
			if (p >= len(s.samples)) {
				v.snd = null;
				continue;
			};
			acc += s.samples[p] * v.vol;
			v.pos += v.step;
		};
		if (a.spos < len(a.stream)) {
			acc += a.stream[a.spos];
			a.spos += 1;
		};
		acc *= gain;
		// Soft limiter, so many sounds at once don't crackle.
		if (acc > 1.0 || acc < -1.0) acc = acc / (0.6 + math::absf32(acc) * 0.4);
		const smp = (acc * 32000.0): i16;
		endian::leputu16(a.buf[i * 2..i * 2 + 2], smp: u16);
	};
};

// ---- Making sounds ----

export type wave = enum { SINE, SQUARE, TRIANGLE, SAW, NOISE };

let noise_state: u32 = 0x12345678;

fn noise() f64 = {
	noise_state ^= noise_state << 13;
	noise_state ^= noise_state >> 17;
	noise_state ^= noise_state << 5;
	return (noise_state: f64 / 4294967295.0) * 2.0 - 1.0;
};

// A tone sliding from f0 to f1 Hz over dur seconds, with a short attack
// and an exponential fade-out.
export fn tone(w: wave, f0: f64, f1: f64, dur: f64, vol: f64, attack: f64) sound = {
	const n = (dur * AUDIO_RATE: f64): size;
	let out: []f32 = alloc([0.0f32...], n)!;
	let phase = 0.0;
	let lp = 0.0; // gentle low-pass for noise
	for (let i = 0z; i < n; i += 1) {
		const t = i: f64 / n: f64;
		const f = f0 * math::powf64(f1 / f0, t);
		phase += f / AUDIO_RATE: f64;
		phase -= math::floorf64(phase);
		const v = switch (w) {
		case wave::SINE => yield math::sinf64(phase * 2.0 * math::PI);
		case wave::SQUARE => yield if (phase < 0.5) 0.6 else -0.6;
		case wave::TRIANGLE => yield 1.0 - 4.0 * math::absf64(phase - 0.5);
		case wave::SAW => yield (2.0 * phase - 1.0) * 0.7;
		case wave::NOISE =>
			// Higher "frequency" = brighter noise.
			const k = f / 8000.0;
			lp += (noise() - lp) * (if (k > 1.0) 1.0 else k);
			yield lp * 1.4;
		};
		const secs = i: f64 / AUDIO_RATE: f64;
		const env = (if (secs < attack) secs / attack else 1.0)
			* math::expf64(-4.0 * t) * (1.0 - t * t * t);
		out[i] = (v * env * vol): f32;
	};
	return sound { samples = out };
};

// Adds src into dst at time `at` (seconds), growing dst as needed.
export fn sound_add(dst: *sound, src: *sound, at: f64, gain: f64) void = {
	const off = (at * AUDIO_RATE: f64): size;
	const need = off + len(src.samples);
	if (need > len(dst.samples)) {
		append(dst.samples, [0.0f32...], need - len(dst.samples))!;
	};
	for (let i = 0z; i < len(src.samples); i += 1) {
		dst.samples[off + i] += src.samples[i] * gain: f32;
	};
};

// Builds a little tune: notes (Hz, 0 = rest) of equal length.
export fn melody(w: wave, notes: []f64, each: f64, vol: f64) sound = {
	let s = sound { samples = [] };
	for (let i = 0z; i < len(notes); i += 1) {
		if (notes[i] <= 0.0) continue;
		const last = i + 1 == len(notes);
		let t = tone(w, notes[i], notes[i], if (last) each * 3.0 else each * 1.6, vol, 0.004);
		sound_add(&s, &t, i: f64 * each, 1.0);
		sound_free(&t);
	};
	return s;
};

export fn sound_free(s: *sound) void = {
	free(s.samples);
	s.samples = [];
};

// Loads a 16-bit PCM WAV file (mono or stereo, any sample rate).
export fn load_wav(path: str) (sound | imgerror) = {
	const f = match (os::open(path)) {
	case let f: io::file => yield f;
	case => return path: fs_error;
	};
	defer io::close(f)!;
	const d = io::drain(f)?;
	defer free(d);
	if (len(d) < 12 || !bytes_eq(d[0..4], strings::toutf8("RIFF"))
			|| !bytes_eq(d[8..12], strings::toutf8("WAVE"))) {
		return "not a WAV file": badpng;
	};
	let channels = 0u16, rate = 0u32, bits = 0u16;
	let pos = 12z;
	for (pos + 8 <= len(d)) {
		const id = d[pos..pos + 4];
		const n = endian::legetu32(d[pos + 4..pos + 8]): size;
		const body = pos + 8;
		if (body + n > len(d)) break;
		if (bytes_eq(id, strings::toutf8("fmt "))) {
			if (endian::legetu16(d[body..body + 2]) != 1) {
				return "only uncompressed PCM WAV is supported": badpng;
			};
			channels = endian::legetu16(d[body + 2..body + 4]);
			rate = endian::legetu32(d[body + 4..body + 8]);
			bits = endian::legetu16(d[body + 14..body + 16]);
		} else if (bytes_eq(id, strings::toutf8("data"))) {
			if (bits != 16 || channels == 0) return "only 16-bit WAV is supported": badpng;
			const frames = n / (2 * channels: size);
			const outn = (frames: f64 * AUDIO_RATE: f64 / rate: f64): size;
			let out: []f32 = alloc([0.0f32...], outn)!;
			for (let i = 0z; i < outn; i += 1) {
				const src = (i: f64 * rate: f64 / AUDIO_RATE: f64): size;
				if (src >= frames) break;
				let acc = 0.0f32;
				for (let c = 0z; c < channels; c += 1) {
					const o = body + (src * channels + c) * 2;
					acc += endian::legetu16(d[o..o + 2]): i16: f32 / 32768.0;
				};
				out[i] = acc / channels: f32;
			};
			return sound { samples = out };
		};
		pos = body + n + (n & 1);
	};
	return "WAV has no data": badpng;
};
