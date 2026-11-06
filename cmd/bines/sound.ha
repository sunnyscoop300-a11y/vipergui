// BINES — sound effects, all synthesized at startup (no sound files).
use viper;

type sfx = enum { SWAP, BONK, POP, SPARKLE, WHOOSH, BOOM, RAINBOW, LEVELUP,
	THIEF_IN, STEAL, FLEE, ESCAPE, CHIME, LAST };

type bank = [sfx::LAST]viper::sound;

fn make_bank() bank = {
	let b: bank = [viper::sound { samples = [] }...];
	b[sfx::SWAP] = viper::tone(viper::wave::TRIANGLE, 700.0, 1000.0, 0.05, 0.3, 0.002);
	b[sfx::BONK] = viper::tone(viper::wave::SQUARE, 200.0, 130.0, 0.14, 0.25, 0.002);

	// A bubbly "plop" with a little sparkle on top.
	b[sfx::POP] = viper::tone(viper::wave::SINE, 520.0, 900.0, 0.11, 0.55, 0.002);
	let top = viper::tone(viper::wave::SINE, 1300.0, 1500.0, 0.05, 0.2, 0.002);
	viper::sound_add(&b[sfx::POP], &top, 0.02, 1.0);
	viper::sound_free(&top);

	const sparkle: [3]f64 = [1319.0, 1568.0, 2093.0];
	b[sfx::SPARKLE] = viper::melody(viper::wave::SINE, sparkle, 0.05, 0.3);

	// Honey stripe: a bright noise sweep with a rising tone.
	b[sfx::WHOOSH] = viper::tone(viper::wave::NOISE, 1500.0, 6000.0, 0.35, 0.45, 0.01);
	let rise = viper::tone(viper::wave::SINE, 300.0, 1400.0, 0.3, 0.25, 0.01);
	viper::sound_add(&b[sfx::WHOOSH], &rise, 0.0, 1.0);
	viper::sound_free(&rise);

	// Honey bomb: a deep thump plus a rumble.
	b[sfx::BOOM] = viper::tone(viper::wave::SINE, 130.0, 35.0, 0.5, 0.9, 0.003);
	let rumble = viper::tone(viper::wave::NOISE, 3000.0, 300.0, 0.4, 0.55, 0.002);
	viper::sound_add(&b[sfx::BOOM], &rumble, 0.0, 1.0);
	viper::sound_free(&rumble);

	const arp: [6]f64 = [523.25, 659.25, 783.99, 1046.5, 1318.5, 1568.0];
	b[sfx::RAINBOW] = viper::melody(viper::wave::TRIANGLE, arp, 0.045, 0.35);

	const fanfare: [4]f64 = [523.25, 659.25, 783.99, 1046.5];
	b[sfx::LEVELUP] = viper::melody(viper::wave::SQUARE, fanfare, 0.1, 0.22);

	// The thief: a sneaky pizzicato creeping downwards.
	const sneak: [6]f64 = [329.6, 0.0, 311.1, 0.0, 293.7, 277.2];
	b[sfx::THIEF_IN] = viper::melody(viper::wave::TRIANGLE, sneak, 0.11, 0.45);
	b[sfx::STEAL] = viper::tone(viper::wave::SAW, 900.0, 300.0, 0.15, 0.25, 0.002);
	const yay: [5]f64 = [523.25, 659.25, 783.99, 1046.5, 1318.5];
	b[sfx::FLEE] = viper::melody(viper::wave::TRIANGLE, yay, 0.07, 0.4);
	// He got away: a sad trombone.
	b[sfx::ESCAPE] = viper::tone(viper::wave::SAW, 233.0, 220.0, 0.28, 0.35, 0.01);
	let t2 = viper::tone(viper::wave::SAW, 220.0, 207.0, 0.28, 0.35, 0.01);
	let t3 = viper::tone(viper::wave::SAW, 207.0, 185.0, 0.8, 0.35, 0.01);
	viper::sound_add(&b[sfx::ESCAPE], &t2, 0.3, 1.0);
	viper::sound_add(&b[sfx::ESCAPE], &t3, 0.6, 1.0);
	viper::sound_free(&t2);
	viper::sound_free(&t3);

	b[sfx::CHIME] = viper::tone(viper::wave::SINE, 1046.5, 1046.5, 0.7, 0.35, 0.003);
	let c2 = viper::tone(viper::wave::SINE, 1318.5, 1318.5, 0.7, 0.3, 0.003);
	viper::sound_add(&b[sfx::CHIME], &c2, 0.06, 1.0);
	viper::sound_free(&c2);
	return b;
};

// Plays a sound effect (no-op in tests, where there is no audio).
fn play_sfx(g: *game, which: sfx, vol: f64, pitch: f64) void = {
	const a = match (g.snd) {
	case let a: *viper::audio => yield a;
	case null => return;
	};
	const b = match (g.bank) {
	case let b: *bank => yield b;
	case null => return;
	};
	viper::play(a, &b[which], vol, pitch);
};
