# Dev tooling lives outside the project because LuaRocks cannot build in
# paths containing spaces. Override with: make TOOLS=/some/path ...
TOOLS ?= $(HOME)/.cache/friendlyforever
BIN := $(TOOLS)/lua51/bin

.PHONY: setup lint test package release-notes check clean

# Pinned versions, each download checked against scripts/dev-setup.lock.
setup:
	./scripts/dev-setup.sh "$(TOOLS)"

lint:
	"$(BIN)/luacheck" .

test:
	"$(BIN)/busted"

package:
	./scripts/package.sh

release-notes:
	./scripts/release-notes.sh

check: lint test package

clean:
	rm -rf dist .release RELEASE_NOTES.md
