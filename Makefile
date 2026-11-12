# Dev tooling lives outside the project because LuaRocks cannot build in
# paths containing spaces. Override with: make TOOLS=/some/path ...
# SPECS names the spec files to run (default: all of them), as CI's shards do.
TOOLS ?= $(HOME)/.cache/friendlyforever
BIN := $(TOOLS)/lua51/bin

.PHONY: setup lint test package release-notes changelog changelog-preview check clean

# Pinned versions, each download checked against scripts/dev-setup.lock.
setup:
	./scripts/dev-setup.sh "$(TOOLS)"

lint:
	"$(BIN)/luacheck" .

test:
	"$(BIN)/busted" $(SPECS)

package:
	./scripts/package.sh

# RELEASE=1 also fails while a changelog note waits to be gathered (#261).
release-notes:
	./scripts/release-notes.sh $(if $(RELEASE),--release)

# In the release PR only: gather changes/*.md into CHANGELOG.md's new
# "## $(VERSION)" section and delete them (#261). The preview changes nothing.
changelog:
	"$(BIN)/lua" scripts/changelog-gather.lua "$(VERSION)"

changelog-preview:
	"$(BIN)/lua" scripts/changelog-gather.lua --dry-run "$(VERSION)"

check: lint test package

clean:
	rm -rf dist .release RELEASE_NOTES.md
