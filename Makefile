PREFIX ?= /opt/homebrew
BIN = $(shell swift build -c release --show-bin-path)/backstage

.PHONY: build install uninstall dist test test-cli test-agents test-multi test-concurrency test-focus load

build:
	swift build -c release

install: build
	mkdir -p "$(PREFIX)/bin"
	ln -sf "$(BIN)" "$(PREFIX)/bin/backstage"

uninstall:
	@if [ -L "$(PREFIX)/bin/backstage" ] && [ "$(PREFIX)/bin/backstage" -ef "$(BIN)" ]; then \
		"$(BIN)" stop --all && rm "$(PREFIX)/bin/backstage"; \
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
	BACKSTAGE_BIN="$(BIN)" tests/multi.sh

test-concurrency: build
	BACKSTAGE_BIN="$(BIN)" tests/concurrency.sh

test-focus: build
	BACKSTAGE_BIN="$(BIN)" tests/focus.sh

test: test-cli test-agents
	BACKSTAGE_BIN="$(BIN)" tests/e2e.sh
	BACKSTAGE_BIN="$(BIN)" tests/multi.sh
	BACKSTAGE_BIN="$(BIN)" tests/concurrency.sh
	BACKSTAGE_BIN="$(BIN)" tests/focus.sh

# Load harness (docs/LOAD_TESTING.md), not part of `make test`. Defaults to a short 2-session
# smoke run. Full runs (8/16/32 sessions, with --dedicated) belong on a separate macOS user
# account or a dedicated Mac: make load LOAD_SESSIONS=32 LOAD_ARGS=--dedicated
LOAD_SESSIONS ?= 2
LOAD_WORKLOADS ?= all
LOAD_ARGS ?= --duration 6 --rounds 2 --cycles 3
load: build
	BACKSTAGE_BIN="$(BIN)" tests/load.sh $(LOAD_SESSIONS) $(LOAD_WORKLOADS) $(LOAD_ARGS)
