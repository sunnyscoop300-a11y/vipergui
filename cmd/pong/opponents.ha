// Golden Pong 3D — the opponents and the "choose your opponent" menu.
// Each opponent has an animation in assets/pong/<file>-0.png, -1.png, ...
// (any size; they are scaled to PIC x PIC). Missing pictures are drawn as a
// simple face instead.
use fmt;
use viper;

def NOPP: size = 6;          // number of opponents
def MAXFRAMES: size = 9;     // most animation frames an opponent may have
def PIC: int = 108;          // portrait size on the cards
def CARD_W: int = 124;
def CARD_H: int = 190;
def CARD_GAP: int = 8;
def CARD_Y: int = 150;

type opponent = struct {
	name: str,             // shown on the card
	short: str,            // shown in the score line
	level: str,            // difficulty text on the card
	file: str,             // assets/pong/<file>-0.png ...
	frames: size,          // how many animation frames
	frame_t: f64,          // seconds per frame
	speed: f64,            // how fast it moves at level 1
	grow: f64,             // extra speed per level
	sleepy: bool,          // only moves while the ball flies away from you
	pad: viper::color,     // paddle colour
	stripe: viper::color,  // paddle stripes
	card: viper::color,    // card colour in the menu
    wall_a: viper::color,  // tunnel colour 1
	wall_b: viper::color,  // tunnel colour 2
	you_msg: str,          // the referee when you score
	opp_msg: str,          // the referee when the opponent scores
	won: str,              // when the opponent wins the match
};

const OPPONENTS: [NOPP]opponent = [
	opponent {
		name = "OGKY",
		short = "OGKY",
		level = "Miniboss",
		file = "ogky",
		frames = 8,
		frame_t = 0.14,
		speed = 0.5,
		grow = 0.3,
		sleepy = true,
		pad = 0xff7ac83a,
		stripe = 0xff7a2a8a,
		card = 0xff3a5a1a,
		wall_a = 0xff4a7a2a,
		wall_b = 0xff2a3a1a,
		you_msg = "FWEET! Point til dig! OGKY plasker i mudderet!",
		opp_msg = "FWEET! Point til OGKY! Sumpens dronning!",
		won = "OGKY VANDT! SUMPEN REGERER!",
	},

	opponent {
		name = "Zebraen",
		short = "ZEBRA",
		level = "Nem",
		file = "zebra",
		frames = 9,
		frame_t = 0.14,
		speed = 0.6,
		grow = 0.32,
		sleepy = true,
		pad = 0xfff5f5f5,
		stripe = 0xff141414,
		card = 0xff2a6a8a,
		wall_a = 0xffebebeb,
		wall_b = 0xff191919,
		you_msg = "FWEET! Point til dig!",
		opp_msg = "FWEET! Point til zebraen!",
		won = "ZEBRAEN VANDT!",
	},
	opponent {
		name = "Elefanten",
		short = "ELEFANT",
		level = "Mellem",
		file = "elephant",
		frames = 9,
		frame_t = 0.16,
		speed = 0.9,
		grow = 0.35,
		sleepy = false,
		pad = 0xffffcc33,
		stripe = 0xff1a1a1a,
		card = 0xff8a6a1a,
		wall_a = 0xffffd84a,
		wall_b = 0xff2a2a2a,
		you_msg = "FWEET! Point til dig! Elefanten tramper!",
		opp_msg = "FWEET! Point til elefanten! Go, go, go!",
		won = "ELEFANTEN VANDT!",
	},
	opponent {
		name = "Momeno",
		short = "Momeno",
		level = "Svaer",
		file = "Momeno",
		frames = 9,
		frame_t = 0.15,
		speed = 1.3,
		grow = 0.4,
		sleepy = false,
		pad = 0xff8a3ac8,
		stripe = 0xffffd24a,
		card = 0xff5a2a8a,
		wall_a = 0xff9a4ad8,
		wall_b = 0xffffd24a,
		you_msg = "FWEET! Point til dig! Momeno vakler!",
		opp_msg = "FWEET! Point til Momeno! Kickflip!",
		won = "Momeno VANDT!",
	},
	opponent {
		name = "XED",
		short = "XED",
		level = "BOSS",
		file = "xed",
		frames = 6,
		frame_t = 0.18,
		speed = 1.6,
		grow = 0.45,
		sleepy = false,
		pad = 0xff1a1a1a,
		stripe = 0xff7ee63a,
		card = 0xff1f5a2a,
		wall_a = 0xff2f8f9a,
		wall_b = 0xff1b5560,
		you_msg = "FWEET! Point til dig! XED: </> bug fundet!",
		opp_msg = "FWEET! Point til XED! Hacked!",
		won = "XED VANDT! GG EZ </>",
	},
	opponent {
		name = "Gustu",
		short = "GUSTU",
		level = "MEGA BOSS",
		file = "gustu",
		frames = 9,
		frame_t = 0.16,
		speed = 1.9,
		grow = 0.5,
		sleepy = false,
		pad = 0xfff0f6ff,
		stripe = 0xffffcc33,
		card = 0xff4a2a8a,
		wall_a = 0xffbfe6ff,
		wall_b = 0xff5a2a9a,
		you_msg = "FWEET! Point til dig! Gustu smelter!",
		opp_msg = "FWEET! Point til Gustu! Iskoldt!",
		won = "GUSTU VANDT! STAY FROSTY",
	},
];

// All the animation frames, loaded once at start.
type portraits = struct {
	img: [NOPP][MAXFRAMES]viper::image,
	ok: [NOPP][MAXFRAMES]bool,
};

fn load_portraits(p: *portraits) void = {
	let buf: [128]u8 = [0...];
	for (let o = 0z; o < NOPP; o += 1) {
		for (let f = 0z; f < OPPONENTS[o].frames && f < MAXFRAMES; f += 1) {
			const path = fmt::bsprintf(buf, "assets/pong/{}-{}.png",
				OPPONENTS[o].file, f)!;
			match (viper::load_png(path)) {
			case let loaded: viper::image =>
				let big = loaded;
				// Scale every picture to the same card size.
				match (viper::resize(&big, PIC, PIC)) {
				case let small: viper::image =>
					p.img[o][f] = small;
					p.ok[o][f] = true;
				case nomem => void;
				};
				viper::image_free(&big);
			case viper::imgerror => void;
			};
		};
	};
};

fn free_portraits(p: *portraits) void = {
	for (let o = 0z; o < NOPP; o += 1) {
		for (let f = 0z; f < MAXFRAMES; f += 1) {
			if (p.ok[o][f]) viper::image_free(&p.img[o][f]);
		};
	};
};

// Left edge of card number i.
fn card_x(i: size) int = {
	const n = NOPP: int;
	return (W - n * CARD_W - (n - 1) * CARD_GAP) / 2 + i: int * (CARD_W + CARD_GAP);
};

// Which card is at x, y, or -1.
fn card_at(x: int, y: int) int = {
	if (y < CARD_Y || y >= CARD_Y + CARD_H) return -1;
	for (let i = 0z; i < NOPP; i += 1) {
		const cx = card_x(i);
		if (x >= cx && x < cx + CARD_W) return i: int;
	};
	return -1;
};

// Arrow keys or the mouse pick a card; Enter, Space or a click starts the
// match. Returns true when an opponent has been chosen.
fn menu_input(win: *viper::window, sel: *size) bool = {
	static let last_x = -1, last_y = -1;
	if (viper::key_pressed(win, viper::key::LEFT)) *sel = (*sel + NOPP - 1) % NOPP;
	if (viper::key_pressed(win, viper::key::RIGHT)) *sel = (*sel + 1) % NOPP;
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

	for (let i = 0z; i < NOPP; i += 1) {
		const o = OPPONENTS[i];
		const x = card_x(i), y = CARD_Y;
		if (i == sel) {
			viper::round_rect(win, x - 5, y - 5, CARD_W + 10, CARD_H + 10, 18, gold);
		};
		viper::round_rect(win, x, y, CARD_W, CARD_H, 14, o.card);
		// The portrait: only the picked opponent is animated.
		const f = if (i == sel) (t / o.frame_t): size % o.frames else 0z;
		const px = x + (CARD_W - PIC) / 2, py = y + 12;
		viper::round_rect(win, px - 4, py - 4, PIC + 8, PIC + 8, 10, 0xffffffff);
		if (p.ok[i][f]) {
			viper::draw_image(win, &p.img[i][f], px, py);
		} else {
			// No picture yet: a simple face in the paddle colours.
			viper::circle(win, px + PIC / 2, py + PIC / 2, PIC / 3, o.pad);
			viper::circle(win, px + PIC / 2 - 18, py + PIC / 2 - 12, 7, o.stripe);
			viper::circle(win, px + PIC / 2 + 18, py + PIC / 2 - 12, 7, o.stripe);
		};
			const ns = if (viper::text_width(o.name, 2) <= CARD_W - 8) 2 else 1;
		viper::text_scaled(win, x + (CARD_W - viper::text_width(o.name, ns)) / 2,
			y + 130, o.name, white, ns);
		const ls = if (viper::text_width(o.level, 2) <= CARD_W - 8) 2 else 1;
		viper::text_scaled(win, x + (CARD_W - viper::text_width(o.level, ls)) / 2,
			y + 162, o.level, gold, ls);
	};
	centered(win, 460, "Pile / mus: vaelg    Enter / klik: spil    Esc: afslut", 1, white);
};
