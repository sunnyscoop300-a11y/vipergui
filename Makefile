HARE = hare

# Default: Wayland (pure Hare) + SDL2 fallback for X11.
# `make HARE_ONLY=1` builds static, Hare-only binaries without SDL2.
ifdef HARE_ONLY
FLAGS = -T +nosdl
else
FLAGS = -lSDL2
endif

all: vipergui-demo flappy-crane mastodon bines

vipergui-demo: viper/*.ha cmd/demo/*.ha
	$(HARE) build $(FLAGS) -o $@ cmd/demo/

flappy-crane: viper/*.ha cmd/flappy/*.ha
	$(HARE) build $(FLAGS) -o $@ cmd/flappy/

mastodon: viper/*.ha cmd/mastodon/*.ha
	$(HARE) build $(FLAGS) -o $@ cmd/mastodon/

bines: viper/*.ha cmd/bines/*.ha
	$(HARE) build $(FLAGS) -o $@ cmd/bines/

play: bines
	./bines

run: vipergui-demo
	./vipergui-demo

flappy: flappy-crane
	./flappy-crane

chat: mastodon
	./mastodon

test:
	$(HARE) test -T +nosdl viper

clean:
	rm -f vipergui-demo flappy-crane mastodon bines

# ---- Desktop integration (KDE/GNOME menu + icons), per user, no sudo ----
APPS = $(HOME)/.local/share/applications
ICONS = $(HOME)/.local/share/icons/hicolor
SIZES = 16 32 48 64 128 256

desktop: all
	@mkdir -p $(APPS)
	@for s in $(SIZES); do \
		mkdir -p $(ICONS)/$${s}x$${s}/apps; \
		cp assets/logo/vipergui-icon-$$s.png $(ICONS)/$${s}x$${s}/apps/vipergui.png; \
		cp assets/crane/flappy-crane-$$s.png $(ICONS)/$${s}x$${s}/apps/flappy-crane.png; \
		cp assets/bines/bines-icon-$$s.png $(ICONS)/$${s}x$${s}/apps/bines.png; \
	done
	@mkdir -p $(ICONS)/scalable/apps
	@cp assets/logo/vipergui-icon.svg $(ICONS)/scalable/apps/vipergui.svg
	$(call entry,vipergui-demo,ViperGui Demo,Widgets and Viper vs. Dumplings,vipergui,Development;)
	$(call entry,flappy-crane,Flappy Crane,Fly Crane through the bamboo,flappy-crane,Game;ArcadeGame;)
	$(call entry,mastodon,Mastodon,Chat with Mastodon (OpenRouter),vipergui,Network;Chat;)
	$(call entry,bines,Bines,Match Three - Make Magic!,bines,Game;LogicGame;)
	@command -v update-desktop-database >/dev/null && update-desktop-database $(APPS) || true
	@command -v kbuildsycoca6 >/dev/null && kbuildsycoca6 >/dev/null 2>&1 || true
	@echo "Installed. Look for the apps in your menu."

# $(call entry,binary,Name,Comment,Icon,Categories)
define entry
	@printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=$(2)' \
		'Comment=$(3)' 'Exec=$(CURDIR)/$(1)' 'Path=$(CURDIR)' 'Icon=$(4)' \
		'Terminal=false' 'Categories=$(5)' 'StartupWMClass=$(1)' \
		> $(APPS)/$(1).desktop
endef

undesktop:
	rm -f $(APPS)/vipergui-demo.desktop $(APPS)/flappy-crane.desktop $(APPS)/mastodon.desktop $(APPS)/bines.desktop
	for s in $(SIZES); do \
		rm -f $(ICONS)/$${s}x$${s}/apps/vipergui.png $(ICONS)/$${s}x$${s}/apps/flappy-crane.png $(ICONS)/$${s}x$${s}/apps/bines.png; \
	done
	rm -f $(ICONS)/scalable/apps/vipergui.svg

.PHONY: all run flappy chat play test clean desktop undesktop
