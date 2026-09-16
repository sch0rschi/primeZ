JOBS ?= $(shell nproc 2>/dev/null || sysctl -n hw.ncpu)
REPEATS ?= 1
ONLY ?=

# Four scenarios, each calibrated to run in roughly 5-10s so the suite stays
# fast to iterate on: two from-zero ranges (~5s and ~10s) plus two much
# higher offsets at (roughly) the same window width - "high" and "extreme"
# name how deep the offset is, not the window width, since the two are
# close in width by construction (picked so both land at ~10s; see below).
# That pair lets offset effects be compared directly at fixed width, since
# project memory "huge_tier_high_offset_regression" found perf tracks with
# offset, not width. Override any bound with e.g.
# `make -C bench bench BIG_LIMIT=2000000000000`.
SMALL_START ?= 0
SMALL_LIMIT ?= 70000000000
BIG_START ?= 0
BIG_LIMIT ?= 130000000000
HIGH_START ?= 1000000000000000
HIGH_LIMIT ?= 1000040000000000
EXTREME_START ?= 100000000000000000
EXTREME_LIMIT ?= 100000028000000000

HERE := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ROOT := $(abspath $(HERE)/..)

SCRIPTS := $(HERE)/scripts
PRIMESIEVE_DIR := $(HERE)/primesieve
PRIMESIEVE_BUILD := $(PRIMESIEVE_DIR)/build
PRIMESIEVE_BIN := $(PRIMESIEVE_BUILD)/primesieve
PRIMEZ_BIN := $(ROOT)/zig-out/bin/primez

SCENARIO_ARGS := \
	small $(SMALL_START) $(SMALL_LIMIT) \
	big $(BIG_START) $(BIG_LIMIT) \
	high $(HIGH_START) $(HIGH_LIMIT) \
	extreme $(EXTREME_START) $(EXTREME_LIMIT)

ONLY_ARGS := $(if $(ONLY),--only $(ONLY),)

.PHONY: help all bench primesieve-build primez-build clean distclean
.NOTPARALLEL:

help:
	@echo "primeZ vs. primesieve benchmark: small limit, big limit, high offset, extreme offset"
	@echo ""
	@echo "  make bench    build both and print the runtime comparison table"
	@echo "  make clean    remove build outputs"
	@echo "  make distclean also remove the primesieve build tree"
	@echo ""
	@echo "  vars: REPEATS=$(REPEATS) (best-of-N per scenario) ONLY=$(ONLY) (comma-separated scenario names)"
	@echo "        SMALL_START=$(SMALL_START) SMALL_LIMIT=$(SMALL_LIMIT)"
	@echo "        BIG_START=$(BIG_START) BIG_LIMIT=$(BIG_LIMIT)"
	@echo "        HIGH_START=$(HIGH_START) HIGH_LIMIT=$(HIGH_LIMIT)"
	@echo "        EXTREME_START=$(EXTREME_START) EXTREME_LIMIT=$(EXTREME_LIMIT)"

all: bench

primesieve-build:
	cmake -S $(PRIMESIEVE_DIR) -B $(PRIMESIEVE_BUILD) \
		-DCMAKE_BUILD_TYPE=RelWithDebInfo -DBUILD_TESTS=OFF \
		-DBUILD_STATIC_LIBS=ON -DBUILD_SHARED_LIBS=OFF \
		-DCMAKE_CXX_FLAGS="-march=native" \
		-DCMAKE_CXX_FLAGS_RELWITHDEBINFO="-O3 -g -DNDEBUG"
	cmake --build $(PRIMESIEVE_BUILD) -j$(JOBS)

primez-build:
	rm -rf $(ROOT)/zig-out $(ROOT)/.zig-cache
	cd $(ROOT) && zig build

bench: primez-build primesieve-build
	@python3 $(SCRIPTS)/compare.py $(PRIMEZ_BIN) $(PRIMESIEVE_BIN) --repeats $(REPEATS) $(ONLY_ARGS) $(SCENARIO_ARGS)

clean:
	rm -rf $(ROOT)/zig-out $(ROOT)/.zig-cache

distclean: clean
	rm -rf $(PRIMESIEVE_BUILD)
