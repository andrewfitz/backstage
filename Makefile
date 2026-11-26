PREFIX ?= /opt/homebrew
BIN_DIR := $(shell swift build -c release --show-bin-path)
ifeq ($(strip $(BIN_DIR)),)
$(error SwiftPM could not resolve the release build directory)
endif
BIN := $(BIN_DIR)/backstage
# Injected into the dev builds and test runners `launch` starts (Sources/BackstageInaudible).
# backstage looks for it next to itself, then in ../lib/backstage.
DYLIB_NAME = libbackstage-inaudible.dylib
DYLIB = $(BIN_DIR)/$(DYLIB_NAME)
LIBDIR = $(PREFIX)/lib/backstage
# GUI suites run a fresh copy of the build at a new path each time (see the install rule:
# ScreenCaptureKit can stop answering one executable path for good).
define fresh_bin
testdir=$$(mktemp -d /tmp/backstage-test.XXXXXX) && trap 'rm -f "$$testdir/backstage" "$$testdir/$(DYLIB_NAME)"; rmdir "$$testdir"' EXIT && cp "$(BIN)" "$$testdir/backstage" && cp "$(DYLIB)" "$$testdir/$(DYLIB_NAME)"
endef

.PHONY: build install uninstall dist test test-cli test-agents test-multi test-concurrency test-focus test-computer-use test-audio test-dock test-launch test-send test-displays test-multidisplay test-strays test-restart load

build:
	swift build -c release --product backstage
	# The injected library, rebuilt universal: an injected app's x86_64 (Rosetta) child would
	# otherwise fail to start (dyld terminates a process whose inserted library can't load).
	# Replaced by rename, never in place: running apps have it mapped.
	@set -e; if [ "$(DYLIB)" -nt Sources/BackstageInaudible/inaudible.c ] && [ "$(DYLIB)" -nt Makefile ] \
		&& xcrun lipo "$(DYLIB)" -verify_arch arm64 && xcrun lipo "$(DYLIB)" -verify_arch x86_64 \
		&& codesign --verify --all-architectures "$(DYLIB)"; then exit 0; fi; \
	staging=$$(mktemp -d "$(BIN_DIR)/.backstage-build.XXXXXX"); \
	trap 'rm -f "$$staging/$(DYLIB_NAME)"; rmdir "$$staging"' EXIT; \
	xcrun clang -dynamiclib -O2 -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 -framework CoreAudio \
		-install_name @rpath/$(DYLIB_NAME) -Wl,-headerpad_max_install_names -o "$$staging/$(DYLIB_NAME)" Sources/BackstageInaudible/inaudible.c; \
	codesign -f -s - "$$staging/$(DYLIB_NAME)"; \
	mv -f "$$staging/$(DYLIB_NAME)" "$(DYLIB)"

install: build
	mkdir -p "$(PREFIX)/bin" "$(LIBDIR)"
	# A real copy, not a symlink into .build: ScreenCaptureKit (replayd) has been seen to stop
	# answering one executable path for good after many rebuilds and timed-out captures, while
	# a copy of the same bytes elsewhere works. A copy also keeps running daemons off the build dir.
	# Replaced by rename: apps launched inaudible have the old one mapped, and their children
	# load it by path.
	@set -e; lib=$$(mktemp "$(LIBDIR)/.backstage-lib.XXXXXX"); \
	trap 'rm -f "$$lib"' EXIT; \
	stage=$$(mktemp -d "$(PREFIX)/bin/.backstage-bin.XXXXXX"); bin="$$stage/backstage"; \
	trap 'rm -f "$$lib" "$$bin"; rmdir "$$stage"' EXIT; \
	cp -p "$(DYLIB)" "$$lib"; cp -p "$(BIN)" "$$bin"; \
	xcrun strip -S -x "$$bin"; codesign --verify "$$bin"; \
	mv -f "$$lib" "$(LIBDIR)/$(DYLIB_NAME)"; mv -f "$$bin" "$(PREFIX)/bin/backstage"

uninstall:
	@set -e; if [ -L "$(PREFIX)/bin/backstage" ] && [ "$(PREFIX)/bin/backstage" -ef "$(BIN)" ]; then \
		"$(BIN)" stop --all && rm "$(PREFIX)/bin/backstage"; \
	elif [ ! -L "$(PREFIX)/bin/backstage" ] && [ -f "$(PREFIX)/bin/backstage" ] && [ -f "$(BIN)" ]; then \
		if ! cmp -s "$(PREFIX)/bin/backstage" "$(BIN)"; then \
			tmp=$$(mktemp -d); trap 'rm -f "$$tmp/backstage"; rmdir "$$tmp"' EXIT; \
			xcrun strip -S -x -o "$$tmp/backstage" "$(BIN)"; \
			cmp -s "$(PREFIX)/bin/backstage" "$$tmp/backstage" || exit 0; \
		fi; \
		"$(PREFIX)/bin/backstage" stop --all && rm "$(PREFIX)/bin/backstage" \
			&& if [ ! -L "$(LIBDIR)/$(DYLIB_NAME)" ] && cmp -s "$(DYLIB)" "$(LIBDIR)/$(DYLIB_NAME)"; then \
				rm -f "$(LIBDIR)/$(DYLIB_NAME)" && { rmdir "$(LIBDIR)" 2>/dev/null || true; }; \
			fi; \
	fi

# The skill's source of truth is Sources/backstage/Skill.swift; dist/ is generated for packaging.
dist: build
	mkdir -p dist/skills/backstage
	@set -e; tmp=$$(mktemp dist/skills/backstage/.skill.XXXXXX); trap 'rm -f "$$tmp"' EXIT; \
	"$(BIN)" skill > "$$tmp"; chmod 644 "$$tmp"; mv -f "$$tmp" dist/skills/backstage/SKILL.md

test-cli: build
	BACKSTAGE_BIN="$(BIN)" bash tests/cli.sh

test-agents: build
	BACKSTAGE_BIN="$(BIN)" bash tests/agents.sh
	bash tests/agent-config.sh "$(BIN)"

test-multi: build
	$(fresh_bin) && BACKSTAGE_BIN="$$testdir/backstage" tests/multi.sh

test-concurrency: build
	$(fresh_bin) && BACKSTAGE_BIN="$$testdir/backstage" tests/concurrency.sh

test-focus: build
	$(fresh_bin) && BACKSTAGE_BIN="$$testdir/backstage" tests/focus.sh

test-computer-use: build
	$(fresh_bin) && BACKSTAGE_BIN="$$testdir/backstage" tests/computer-use.sh

test-audio: build
	$(fresh_bin) && BACKSTAGE_BIN="$$testdir/backstage" tests/audio.sh

test-dock: build
	$(fresh_bin) && BACKSTAGE_BIN="$$testdir/backstage" tests/dock.sh

test-launch: build
	$(fresh_bin) && BACKSTAGE_BIN="$$testdir/backstage" tests/launch.sh

test-send: build
	$(fresh_bin) && BACKSTAGE_BIN="$$testdir/backstage" tests/send.sh

test-displays: build
	$(fresh_bin) && BACKSTAGE_BIN="$$testdir/backstage" tests/displays.sh

test-multidisplay: build
	$(fresh_bin) && BACKSTAGE_BIN="$$testdir/backstage" tests/multidisplay.sh

test-strays: build
	$(fresh_bin) && BACKSTAGE_BIN="$$testdir/backstage" tests/strays.sh

test-restart: build
	$(fresh_bin) && BACKSTAGE_BIN="$$testdir/backstage" tests/restart.sh

test: test-cli test-agents
	$(fresh_bin) && BACKSTAGE_BIN="$$testdir/backstage" tests/e2e.sh
	$(fresh_bin) && BACKSTAGE_BIN="$$testdir/backstage" tests/launch.sh
	$(fresh_bin) && BACKSTAGE_BIN="$$testdir/backstage" tests/multi.sh
	$(fresh_bin) && BACKSTAGE_BIN="$$testdir/backstage" tests/concurrency.sh
	$(fresh_bin) && BACKSTAGE_BIN="$$testdir/backstage" tests/focus.sh
	$(fresh_bin) && BACKSTAGE_BIN="$$testdir/backstage" tests/computer-use.sh
	$(fresh_bin) && BACKSTAGE_BIN="$$testdir/backstage" tests/audio.sh
	$(fresh_bin) && BACKSTAGE_BIN="$$testdir/backstage" tests/dock.sh
	$(fresh_bin) && BACKSTAGE_BIN="$$testdir/backstage" tests/send.sh
	$(fresh_bin) && BACKSTAGE_BIN="$$testdir/backstage" tests/displays.sh
	$(fresh_bin) && BACKSTAGE_BIN="$$testdir/backstage" tests/multidisplay.sh
	$(fresh_bin) && BACKSTAGE_BIN="$$testdir/backstage" tests/strays.sh
	$(fresh_bin) && BACKSTAGE_BIN="$$testdir/backstage" tests/restart.sh

# Load harness (docs/LOAD_TESTING.md), not part of `make test`. Defaults to a short 2-session
# smoke run. Full runs (8/16/32 sessions, with --dedicated) belong on a separate macOS user
# account or a dedicated Mac: make load LOAD_SESSIONS=32 LOAD_ARGS=--dedicated
LOAD_SESSIONS ?= 2
LOAD_WORKLOADS ?= all
LOAD_ARGS ?= --duration 6 --rounds 2 --cycles 3
load: build
	$(fresh_bin) && BACKSTAGE_BIN="$$testdir/backstage" tests/load.sh $(LOAD_SESSIONS) $(LOAD_WORKLOADS) $(LOAD_ARGS)
