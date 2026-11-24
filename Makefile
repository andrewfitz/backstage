PREFIX ?= /opt/homebrew
BIN = $(shell swift build -c release --show-bin-path)/backstage
# Injected into the dev builds and test runners `launch` starts (Sources/BackstageInaudible).
# backstage looks for it next to itself, then in ../lib/backstage.
DYLIB_NAME = libbackstage-inaudible.dylib
DYLIB = $(dir $(BIN))$(DYLIB_NAME)
LIBDIR = $(PREFIX)/lib/backstage
# GUI suites run a fresh copy of the build at a new path each time (see the install rule:
# ScreenCaptureKit can stop answering one executable path for good).
TEST_BIN := /tmp/backstage-test-$(shell id -u)-$(shell date +%s)/backstage
define fresh_bin
mkdir -p "$(dir $(TEST_BIN))" && cp "$(BIN)" "$(TEST_BIN)" && cp "$(DYLIB)" "$(dir $(TEST_BIN))$(DYLIB_NAME)"
endef

.PHONY: build install uninstall dist test test-cli test-agents test-multi test-concurrency test-focus test-computer-use test-audio test-dock load

build:
	swift build -c release
	# The injected library, rebuilt universal: an injected app's x86_64 (Rosetta) child would
	# otherwise fail to start (dyld terminates a process whose inserted library can't load).
	# Replaced by rename, never in place: running apps have it mapped.
	xcrun clang -dynamiclib -O2 -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 -framework CoreAudio \
		-install_name @rpath/$(DYLIB_NAME) -o "$(DYLIB).new" Sources/BackstageInaudible/inaudible.c
	codesign -f -s - "$(DYLIB).new" 2>/dev/null
	mv -f "$(DYLIB).new" "$(DYLIB)"

install: build
	mkdir -p "$(PREFIX)/bin"
	# A real copy, not a symlink into .build: ScreenCaptureKit (replayd) has been seen to stop
	# answering one executable path for good after many rebuilds and timed-out captures, while
	# a copy of the same bytes elsewhere works. A copy also keeps running daemons off the build dir.
	rm -f "$(PREFIX)/bin/backstage.new"
	cp "$(BIN)" "$(PREFIX)/bin/backstage.new"
	mv -f "$(PREFIX)/bin/backstage.new" "$(PREFIX)/bin/backstage"
	# Replaced by rename: apps launched inaudible have the old one mapped, and their children
	# load it by path.
	mkdir -p "$(LIBDIR)"
	rm -f "$(LIBDIR)/$(DYLIB_NAME).new"
	cp "$(DYLIB)" "$(LIBDIR)/$(DYLIB_NAME).new"
	mv -f "$(LIBDIR)/$(DYLIB_NAME).new" "$(LIBDIR)/$(DYLIB_NAME)"

uninstall:
	@if [ -L "$(PREFIX)/bin/backstage" ] && [ "$(PREFIX)/bin/backstage" -ef "$(BIN)" ]; then \
		"$(BIN)" stop --all && rm "$(PREFIX)/bin/backstage"; \
	elif [ -f "$(PREFIX)/bin/backstage" ] && cmp -s "$(PREFIX)/bin/backstage" "$(BIN)"; then \
		"$(PREFIX)/bin/backstage" stop --all && rm "$(PREFIX)/bin/backstage" \
			&& rm -f "$(LIBDIR)/$(DYLIB_NAME)" && { rmdir "$(LIBDIR)" 2>/dev/null || true; }; \
	fi

# The skill's source of truth is Sources/backstage/Skill.swift; dist/ is generated for packaging.
dist: build
	mkdir -p dist/skills/backstage
	"$(BIN)" skill > dist/skills/backstage/SKILL.md

test-cli: build
	BACKSTAGE_BIN="$(BIN)" bash tests/cli.sh

test-agents: build
	BACKSTAGE_BIN="$(BIN)" bash tests/agents.sh
	bash tests/agent-config.sh "$(BIN)"

test-multi: build
	$(fresh_bin) && BACKSTAGE_BIN="$(TEST_BIN)" tests/multi.sh

test-concurrency: build
	$(fresh_bin) && BACKSTAGE_BIN="$(TEST_BIN)" tests/concurrency.sh

test-focus: build
	$(fresh_bin) && BACKSTAGE_BIN="$(TEST_BIN)" tests/focus.sh

test-computer-use: build
	$(fresh_bin) && BACKSTAGE_BIN="$(TEST_BIN)" tests/computer-use.sh

test-audio: build
	$(fresh_bin) && BACKSTAGE_BIN="$(TEST_BIN)" tests/audio.sh

test-dock: build
	$(fresh_bin) && BACKSTAGE_BIN="$(TEST_BIN)" tests/dock.sh

test: test-cli test-agents
	$(fresh_bin) && BACKSTAGE_BIN="$(TEST_BIN)" tests/e2e.sh
	$(fresh_bin) && BACKSTAGE_BIN="$(TEST_BIN)" tests/multi.sh
	$(fresh_bin) && BACKSTAGE_BIN="$(TEST_BIN)" tests/concurrency.sh
	$(fresh_bin) && BACKSTAGE_BIN="$(TEST_BIN)" tests/focus.sh
	$(fresh_bin) && BACKSTAGE_BIN="$(TEST_BIN)" tests/computer-use.sh
	$(fresh_bin) && BACKSTAGE_BIN="$(TEST_BIN)" tests/audio.sh
	$(fresh_bin) && BACKSTAGE_BIN="$(TEST_BIN)" tests/dock.sh

# Load harness (docs/LOAD_TESTING.md), not part of `make test`. Defaults to a short 2-session
# smoke run. Full runs (8/16/32 sessions, with --dedicated) belong on a separate macOS user
# account or a dedicated Mac: make load LOAD_SESSIONS=32 LOAD_ARGS=--dedicated
LOAD_SESSIONS ?= 2
LOAD_WORKLOADS ?= all
LOAD_ARGS ?= --duration 6 --rounds 2 --cycles 3
load: build
	$(fresh_bin) && BACKSTAGE_BIN="$(TEST_BIN)" tests/load.sh $(LOAD_SESSIONS) $(LOAD_WORKLOADS) $(LOAD_ARGS)
