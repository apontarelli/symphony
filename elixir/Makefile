.PHONY: help all setup deps audit build fmt fmt-check lint test coverage ci dialyzer e2e

MIX ?= mix

help:
	@echo "Targets: setup, deps, audit, fmt, fmt-check, lint, test, coverage, dialyzer, e2e, ci"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

audit:
	$(MIX) hex.audit

build:
	$(MIX) build

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

lint:
	$(MIX) lint

coverage:
	@original_home="$$HOME"; \
	temp_home="$$(mktemp -d)" || exit 1; \
	trap 'rm -rf "$$temp_home"' EXIT; \
	HOME="$$temp_home" \
	MIX_HOME="$${MIX_HOME:-$$original_home/.mix}" \
	MIX_ARCHIVES="$${MIX_ARCHIVES:-$$original_home/.mix/archives}" \
	HEX_HOME="$${HEX_HOME:-$$original_home/.hex}" \
	MISE_DATA_DIR="$${MISE_DATA_DIR:-$$original_home/.local/share/mise}" \
	MISE_CACHE_DIR="$${MISE_CACHE_DIR:-$$original_home/.cache/mise}" \
	$(MIX) test --cover

test:
	$(MIX) test

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

e2e:
	SYMPHONY_RUN_LIVE_E2E=1 $(MIX) test test/symphony_elixir/live_e2e_test.exs

ci:
	$(MAKE) setup
	$(MAKE) audit
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) dialyzer

all: ci
