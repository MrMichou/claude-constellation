# Local test entry points (CI runs the same commands, see .github/workflows/ci.yml).
# Lua specs run with lua5.4 directly: Arch's `busted` binary targets Lua 5.5, where lgi is broken.
LUA ?= lua5.4

.PHONY: test test-js test-lua lint

test: test-js lint test-lua

test-js:
	npm test

test-lua:
	$(LUA) -e 'require("busted.runner")({ standalone = false })'

lint:
	luacheck awesome/ spec/
