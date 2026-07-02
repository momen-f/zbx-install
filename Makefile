# Makefile — lint / fmt / test / build / matrix / clean. SPEC §16.

# Prefer a modern bash (Homebrew on macOS, /usr/bin on Linux CI) for bats.
BASH_BIN := $(shell command -v /opt/homebrew/bin/bash bash 2>/dev/null | head -1)
BASH_DIR := $(dir $(BASH_BIN))

SH_SRC := build.sh src/main.sh $(wildcard src/lib/*.sh)
DIST   := dist/zbx-install.sh

.PHONY: all lint fmt test build matrix clean

all: lint test

build:
	./build.sh

# Lint the program through main.sh (-x follows the dev-source'd libs for
# whole-program analysis, avoiding false "unused" on cross-module vars), the
# standalone build script, and the bundled artifact. SPEC §16.
lint: build
	shellcheck -x src/main.sh build.sh
	shellcheck $(DIST)

# Formatting check: 2-space indent, indented case bodies (-ci).
fmt:
	shfmt -d -i 2 -ci $(SH_SRC)

# Unit tests. Force a >=4.2 bash onto PATH so associative arrays work.
test:
	PATH="$(BASH_DIR):$$PATH" bats tests/bats

# Container smoke matrix (filled in from Phase 1 onward). SPEC §16.
matrix:
	@echo "matrix: implemented from Phase 1 (container smoke tests)"

clean:
	rm -rf dist
