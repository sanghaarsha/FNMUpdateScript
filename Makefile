SHELL := /usr/bin/env bash

# Installation configuration
PREFIX  ?= /usr/local
BINDIR  ?= $(PREFIX)/bin
SCRIPT_NAME := fnm_update

.PHONY: all test lint install uninstall clean help

# Default target runs lint and tests
all: lint test

## test: Run Bats test suite inside isolated sandbox
test:
	@command -v bats >/dev/null 2>&1 || { \
		echo "Error: 'bats' test runner is not installed." >&2; \
		echo "Install with:" >&2; \
		echo "  - Linux: sudo apt-get install bats (or pacman -S bats / npm install -g bats)" >&2; \
		echo "  - macOS: brew install bats-core" >&2; \
		exit 1; \
	}
	@echo "==> Running hermetic Bats test suite..."
	bats test/updater.bats

## lint: Run ShellCheck on scripts and test helpers
lint:
	@command -v shellcheck >/dev/null 2>&1 || { \
		echo "Error: 'shellcheck' is not installed." >&2; \
		echo "Install with:" >&2; \
		echo "  - Linux: sudo apt-get install shellcheck (or npm install -g shellcheck)" >&2; \
		echo "  - macOS: brew install shellcheck" >&2; \
		exit 1; \
	}
	@echo "==> Running ShellCheck analysis..."
	shellcheck fnm_update.sh bin/*.sh test/helpers/*.bash
	@echo "ShellCheck passed with zero warnings."

## install: Install executable to $(BINDIR)
install:
	@echo "==> Installing $(SCRIPT_NAME) to $(DESTDIR)$(BINDIR)..."
	install -d "$(DESTDIR)$(BINDIR)"
	install -m 755 fnm_update.sh "$(DESTDIR)$(BINDIR)/$(SCRIPT_NAME)"
	@echo "Successfully installed: $(DESTDIR)$(BINDIR)/$(SCRIPT_NAME)"

## uninstall: Remove installed executable from $(BINDIR)
uninstall:
	@echo "==> Uninstalling $(SCRIPT_NAME) from $(DESTDIR)$(BINDIR)..."
	rm -f "$(DESTDIR)$(BINDIR)/$(SCRIPT_NAME)"
	@echo "Uninstalled $(DESTDIR)$(BINDIR)/$(SCRIPT_NAME)"

## clean: Remove temporary test artifacts and editor leftovers
clean:
	@rm -rf /tmp/fnm_test_sandbox_* test/fixtures/*~ *~

## help: Show Makefile targets and usage
help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@grep -E '^## ' $(MAKEFILE_LIST) | sed -e 's/## //' | awk -F':' '{printf "  %-12s %s\n", $$1, $$2}'
