# Local test entry points (CI runs the same commands, see .github/workflows/ci.yml).
# Lua specs run with lua5.4 directly: Arch's `busted` binary targets Lua 5.5, where lgi is broken.
LUA ?= lua5.4

.PHONY: test test-js test-lua lint test-e2e test-docker test-e2e-docker release

test: test-js lint test-lua

test-js:
	npm test

test-lua:
	$(LUA) -e 'require("busted.runner")({ standalone = false })'

lint:
	luacheck awesome/ spec/ demo/ e2e/

# Installer -> hook -> renderer in a throwaway HOME; LUAS lists the Luas to draw with (each needs lgi).
LUAS ?= lua5.4
test-e2e:
	e2e/run.sh $(LUAS)

# Lint + Lua specs in the same Arch container as CI, without installing busted/luacheck locally.
test-docker:
	docker run --rm -v "$(CURDIR)":/src:ro -w /src archlinux:latest bash -c '\
	  pacman -Syu --noconfirm --needed lua54 lua54-lgi lua54-busted luacheck cairo gdk-pixbuf2 >/dev/null && \
	  luacheck awesome/ spec/ demo/ e2e/ && lua5.4 -e "require(\"busted.runner\")({ standalone = false })"'

# The e2e test under Lua 5.4, 5.1 and LuaJIT, as in CI.
test-e2e-docker:
	docker run --rm -v "$(CURDIR)":/src:ro -w /src archlinux:latest bash -c '\
	  pacman -Syu --noconfirm --needed nodejs lua54 lua54-lgi lua51 lua51-lgi luajit cairo gdk-pixbuf2 >/dev/null && \
	  e2e/run.sh lua5.4 lua5.1 luajit'

# make release V=patch|minor|major|X.Y.Z  (add DRY=1 to preview). See scripts/release.js.
release:
	node scripts/release.js $(V) $(if $(DRY),--dry-run)
