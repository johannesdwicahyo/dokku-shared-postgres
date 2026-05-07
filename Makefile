SHELL := /usr/bin/env bash
BATS  ?= bats
SHELLCHECK ?= shellcheck

SH_FILES := commands config functions install \
            $(wildcard subcommands/*) \
            $(wildcard tests/bin/*)

.PHONY: lint test ci

lint:
	$(SHELLCHECK) -x $(SH_FILES)

test:
	$(BATS) tests

ci: lint test
