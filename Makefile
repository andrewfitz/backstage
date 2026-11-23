PREFIX ?= /opt/homebrew
BIN = $(shell swift build -c release --show-bin-path)/backstage

.PHONY: build install uninstall dist test test-cli test-agents

build:
	swift build -c release

install: build
	mkdir -p "$(PREFIX)/bin"
	ln -sf "$(BIN)" "$(PREFIX)/bin/backstage"

uninstall:
	@if [ -L "$(PREFIX)/bin/backstage" ] && [ "$(PREFIX)/bin/backstage" -ef "$(BIN)" ]; then \
		"$(BIN)" stop && rm "$(PREFIX)/bin/backstage"; \
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

test: test-cli test-agents
	BACKSTAGE_BIN="$(BIN)" tests/e2e.sh
