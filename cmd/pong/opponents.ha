// Golden Pong 3D — the opponents and the "choose your opponent" menu.
// Each opponent has 9 animation frames in assets/pong/<file>-0.png .. -8.png
// (180 x 180). Missing pictures are drawn as a simple face instead.
use fmt;
use viper;

def FRAMES: size = 9;        // animation frames per opponent
def FRAME_T: f64 = 0.14;     // seconds per frame (same speed as the gifs)
def CARD_W: int = 220;
def CARD_H: int = 300;
def CARD_GAP: int = 30;
def CARD_Y: int = 150;

type opponent = struct {
	name: str,             // shown on the card
	short: str,            // shown in the score line
	level: str,            // difficulty text on the card
	file: str,             // assets/pong/<file>-0.png ...
	speed: f64,            // how fast it moves at level 1
	grow: f64,             // extra speed per level
	sleepy: bool,          // only moves while the ball flies away from you
	pad: viper::color,     // paddle colour
	stripe: viper::color,  // paddle stripes
	card: viper::color,    // card colour in the menu
	you_msg: str,          // the referee when you score
	opp_msg: str,          // the referee when the opponent scores
	won: str,              // when the opponent wins the match
};

const OPPONENTS: [3]opponent = [
	opponent {
		name = "Zebraen",
		short = "ZEBRA",
		level = "Nem",
		file = "zebra",
		speed = 0.6,
		grow = 0.32,
		sleepy = true,
		pad = 0xfff5f5f5,
		stripe = 0xff141414,
		card = 0xff2a6a8a,
		you_msg = "FWEET! Point til dig!",
		opp_msg = "FWEET! Point til zebraen!",
		won = "ZEBRAEN VANDT!",
	},
	opponent {
		name = "Elefanten",
		short = "ELEFANT",
		level = "Mellem",
		file = "elephant",
		speed = 0.9,
		grow = 0.35,
		sleepy = false,
		pad = 0xffffcc33,
		stripe = 0xff1a1a1a,
		card = 0xff8a6a1a,
		you_msg = "FWEET! Point til dig! Elefanten tramper!",
		opp_msg = "FWEET! Point til elefanten! Go, go, go!",
		won = "ELEFANTEN VANDT!",
	},
	opponent {
		name = "Giraffen",
		short = "GIRAF",
		level = "Boss",
		file = "giraffe",
		speed = 1.3,
		grow = 0.4,
		sleepy = false,
		pad = 0xff8a3ac8,
		stripe = 0xffffd24a,
		card = 0xff5a2a8a,
		you_msg = "FWEET! Point til dig! Giraffen vakler!",
		opp_msg = "FWEET! Point til giraffen! Kickflip!",
		won = "GIRAFFEN VANDT!",
	},
];

// All the animation frames, loaded once at start.
type portraits = struct {
	img: [3][9]viper::image,
	ok: [3][9]bool,
};

fn load_portraits(p: *portraits) void = {
	let buf: [128]u8 = [0...];
	for (let o = 0z; o < len(OPPONENTS); o += 1) {
		for (let f = 0z; f < FRAMES; f += 1) {
			const path = fmt::bsprintf(buf, "assets/pong/{}-{}.png",
				OPPONENTS[o].file, f)!;
			match (viper::load_png(path)) {
			case let img: viper::image =>
				p.img[o][f] = img;
				p.ok[o][f] = true;
			case viper::imgerror => void;
			};
		};
	};
};

fn free_portraits(p: *portraits) void = {
	for (let o = 0z; o < len(OPPONENTS); o += 1) {
		for (let f = 0z; f < FRAMES; f += 1) {
			if (p.ok[o][f]) viper::image_free(&p.img[o][f]);
		};
	};
};

// Left edge of card number i.
fn card_x(i: size) int =
	(W - 3 * CARD_W - 2 * CARD_GAP) / 2 + i: int * (CARD_W + CARD_GAP);

// Which card is at x, y, or -1.
fn card_at(x: int, y: int) int = {
	if (y < CARD_Y || y >= CARD_Y + CARD_H) return -1;
	for (let i = 0z; i < len(OPPONENTS); i += 1) {
		const cx = card_x(i);
		if (x >= cx && x < cx + CARD_W) return i: int;
	};
	return -1;
};

// Arrow keys or the mouse pick a card; Enter, Space or a click starts the
// match. Returns true when an opponent has been chosen.
fn menu_input(win: *viper::window, sel: *size) bool = {
	static let last_x = -1, last_y = -1;
	const n = len(OPPONENTS);
	if (viper::key_pressed(win, viper::key::LEFT)) *sel = (*sel + n - 1) % n;
	if (viper::key_pressed(win, viper::key::RIGHT)) *sel = (*sel + 1) % n;
	// The mouse only picks a card when it moves, so the arrow keys still work.
	const hover = card_at(win.mouse_x, win.mouse_y);
	if (hover >= 0 && (win.mouse_x != last_x || win.mouse_y != last_y)) {
		*sel = hover: size;
	};
	last_x = win.mouse_x;
	last_y = win.mouse_y;
	if (viper::mouse_pressed(win) && hover >= 0) {
		*sel = hover: size;
		return true;
	};
	return viper::key_pressed(win, viper::key::SPACE)
		|| viper::key_pressed(win, viper::key::RETURN);
};

fn draw_menu(win: *viper::window, p: *portraits, sel: size, t: f64) void = {
	const gold = viper::rgb(255, 205, 60);
	const white = viper::rgb(240, 240, 240);
	viper::clear(win, viper::rgb(10, 10, 14));
	centered(win, 40, "GOLDEN PONG 3D", 4, gold);
	centered(win, 100, "Vaelg din modstander", 2, white);

	const frame = (t / FRAME_T): size % FRAMES;
	for (let i = 0z; i < len(OPPONENTS); i += 1) {
		const o = OPPONENTS[i];
		const x = card_x(i), y = CARD_Y;
		if (i == sel) {
			viper::round_rect(win, x - 5, y - 5, CARD_W + 10, CARD_H + 10, 18, gold);
		};
		viper::round_rect(win, x, y, CARD_W, CARD_H, 14, o.card);
		// The portrait: only the picked opponent is animated.
		const f = if (i == sel) frame else 0z;
		const px = x + (CARD_W - 180) / 2, py = y + 14;
		viper::round_rect(win, px - 4, py - 4, 188, 188, 10, 0xffffffff);
		if (p.ok[i][f]) {
			viper::draw_image(win, &p.img[i][f], px, py);
		} else {
			// No picture yet: a simple face in the paddle colours.
			viper::circle(win, px + 90, py + 90, 60, o.pad);
			viper::circle(win, px + 70, py + 75, 8, o.stripe);
			viper::circle(win, px + 110, py + 75, 8, o.stripe);
		};
		viper::text_scaled(win, x + (CARD_W - viper::text_width(o.name, 2)) / 2,
			y + 212, o.name, white, 2);
		viper::text_scaled(win, x + (CARD_W - viper::text_width(o.level, 2)) / 2,
			y + 250, o.level, gold, 2);
	};
	centered(win, 490, "Pile / mus: vaelg    Enter / klik: spil    Esc: afslut", 1, white);
};
