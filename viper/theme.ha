// ViperGui — themes. Set one with `win.theme = viper::night;`
// or build your own theme struct.

export type theme = struct {
	bg: color,
	panel: color,
	border: color,
	text: color,
	text_dim: color,
	widget: color,
	widget_hot: color,
	accent: color,
	accent_hot: color,
	accent_active: color,
};

// Jade Palace: Viper's green on warm parchment.
export const jade: theme = theme {
	bg = 0xffefe4cc,
	panel = 0xfffaf3e3,
	border = 0xff8c6a43,
	text = 0xff2d2418,
	text_dim = 0xff7d6b52,
	widget = 0xffe2d3b2,
	widget_hot = 0xffd6c49c,
	accent = 0xff3f8f4f,
	accent_hot = 0xff4fa860,
	accent_active = 0xff2c6b39,
};

// Night in the Valley of Peace: dark with Viper's green and lantern red.
export const night: theme = theme {
	bg = 0xff13161c,
	panel = 0xff1d222b,
	border = 0xff3a4250,
	text = 0xffe8e3d6,
	text_dim = 0xff8b93a1,
	widget = 0xff2a313d,
	widget_hot = 0xff353e4d,
	accent = 0xff4fbf6a,
	accent_hot = 0xff66d482,
	accent_active = 0xff3a9a52,
};
