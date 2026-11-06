// JADE — sound effects, synthesized at startup. A pentatonic scale gives
// them a temple-garden feel.
use viper;

type sfx = enum { EAT, GOLD, TURN, CRASH, CLEAR, START, LAST };

type bank = [sfx::LAST]viper::sound;

fn make_bank() bank = {
	let b: bank = [viper::sound { samples = [] }...];
	// A plucked "pling", like a guzheng string.
	b[sfx::EAT] = viper::tone(viper::wave::TRIANGLE, 784.0, 784.0, 0.25, 0.45, 0.002);
	let o = viper::tone(viper::wave::SINE, 1568.0, 1568.0, 0.15, 0.15, 0.002);
	viper::sound_add(&b[sfx::EAT], &o, 0.0, 1.0);
	viper::sound_free(&o);
	const gold: [5]f64 = [587.3, 659.3, 784.0, 880.0, 1174.7];
	b[sfx::GOLD] = viper::melody(viper::wave::TRIANGLE, gold, 0.06, 0.4);
	b[sfx::TURN] = viper::tone(viper::wave::SINE, 420.0, 380.0, 0.03, 0.12, 0.001);
	// A gong.
	b[sfx::CRASH] = viper::tone(viper::wave::SINE, 110.0, 98.0, 1.4, 0.8, 0.002);
	let n = viper::tone(viper::wave::NOISE, 2500.0, 400.0, 0.5, 0.35, 0.002);
	let h = viper::tone(viper::wave::SINE, 277.0, 262.0, 1.0, 0.25, 0.002);
	viper::sound_add(&b[sfx::CRASH], &n, 0.0, 1.0);
	viper::sound_add(&b[sfx::CRASH], &h, 0.0, 1.0);
	viper::sound_free(&n);
	viper::sound_free(&h);
	const clear: [7]f64 = [392.0, 440.0, 523.3, 587.3, 659.3, 784.0, 1046.5];
	b[sfx::CLEAR] = viper::melody(viper::wave::TRIANGLE, clear, 0.08, 0.4);
	const start: [3]f64 = [523.3, 659.3, 784.0];
	b[sfx::START] = viper::melody(viper::wave::SINE, start, 0.07, 0.35);
	return b;
};
