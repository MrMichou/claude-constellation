# Local test entry points (CI runs the same commands, see .github/workflows/ci.yml).
# Lua specs run with lua5.4 directly: Arch's `busted` binary targets Lua 5.5, where lgi is broken.
LUA ?= lua5.4

.PHONY: test test-js test-lua lint test-docker release

test: test-js lint test-lua

test-js:
	npm test

test-lua:
	$(LUA) -e 'require("busted.runner")({ standalone = false })'

lint:
	luacheck awesome/ spec/

# Lint + Lua specs in the same Arch container as CI, without installing busted/luacheck locally.
test-docker:
	docker run --rm -v "$(CURDIR)":/src:ro -w /src archlinux:latest bash -c '\
	  pacman -Syu --noconfirm --needed lua54 lua54-lgi lua54-busted luacheck cairo gdk-pixbuf2 >/dev/null && \
	  luacheck awesome/ spec/ && lua5.4 -e "require(\"busted.runner\")({ standalone = false })"'

# make release V=patch|minor|major|X.Y.Z  (add DRY=1 to preview). See scripts/release.js.
release:
	node scripts/release.js $(V) $(if $(DRY),--dry-run)
