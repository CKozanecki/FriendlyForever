# Dev tooling lives outside the project because LuaRocks cannot build in
# paths containing spaces. Override with: make TOOLS=/some/path ...
TOOLS ?= $(HOME)/.cache/friendlyforever
BIN := $(TOOLS)/lua51/bin

.PHONY: setup lint test package check clean

setup:
	python3 -m venv "$(TOOLS)/venv"
	"$(TOOLS)/venv/bin/pip" install -q hererocks==0.25.1
	"$(TOOLS)/venv/bin/hererocks" "$(TOOLS)/lua51" -l 5.1 -r latest
	"$(BIN)/luarocks" install busted 2.2.0-1
	"$(BIN)/luarocks" install luacheck 1.2.0-1

lint:
	"$(BIN)/luacheck" .

test:
	"$(BIN)/busted"

package:
	./scripts/package.sh

check: lint test package

clean:
	rm -rf dist
