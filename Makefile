.POSIX:
.PHONY: help install uninstall test lint check

PREFIX  ?= $(HOME)/.local
BINDIR  ?= $(PREFIX)/bin

install: ## Install ocs to ~/.local/bin
	mkdir -p $(DESTDIR)$(BINDIR)
	@install -d $(DESTDIR)$(BINDIR)
	install -m 0755 ocs $(DESTDIR)$(BINDIR)/ocs
	@echo
	@echo "installed:"
	@echo "  $(DESTDIR)$(BINDIR)/ocs"
	@echo
	@case ":$(PATH):" in \
		*":$(BINDIR):"*) echo "$(BINDIR) is already on PATH" ;; \
		*) echo "note: add to PATH -> export PATH=\"$(BINDIR):\$$PATH\"" ;; \
	esac

uninstall: ## Remove installed files
	rm -f $(DESTDIR)$(BINDIR)/ocs
	-rmdir $(DESTDIR)$(PREFIX)/bin 2>/dev/null || true

test: ## Run the suite (slow: one sandbox spawn per check)
	@command -v bats >/dev/null 2>&1 || { \
		echo "bats is not installed"; \
		echo "  Arch:    sudo pacman -S bats"; \
		echo "  Debian:  sudo apt-get install bats"; \
		exit 1; }
	OCS=$(CURDIR)/ocs bats $(CURDIR)/tests/ocs.bats

lint: ## shellcheck the tool
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck is not installed"; exit 1; }
	shellcheck -S style ocs

check: lint test ## Lint then test

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?##' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
