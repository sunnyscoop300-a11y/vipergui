// ViperGui — stand-in for the SDL2 backend in Hare-only builds
// (`hare build -T +nosdl`). Only the Wayland backend is available then.

// Internal to ViperGui.
export type sdl_backend = struct { unused: int };

fn sdl_open(title: str, width: int, height: int) (*sdl_backend | error | nomem) =
	"no Wayland session found, and this ViperGui build has no SDL2 "
	"fallback (it was built with -T +nosdl)": error;

fn sdl_close(be: *sdl_backend) void = void;
fn sdl_poll(win: *window, be: *sdl_backend) bool = false;
fn sdl_present(win: *window, be: *sdl_backend) void = void;
fn sdl_icon(be: *sdl_backend, img: *image) void = void;
fn sdl_cursor(be: *sdl_backend, on: bool) void = void;
