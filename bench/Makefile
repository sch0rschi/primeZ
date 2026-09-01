N ?= 100000000000
SIEVE_KIB ?= 32
PERF_FREQ ?= 999
JOBS ?= $(shell nproc)

HERE := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ROOT := $(abspath $(HERE)/..)

RESULTS := $(HERE)/results
SCRIPTS := $(HERE)/scripts
PRIMESIEVE_DIR := $(HERE)/primesieve
PRIMESIEVE_BUILD := $(PRIMESIEVE_DIR)/build
PRIMESIEVE_BIN := $(PRIMESIEVE_BUILD)/primesieve
PRIMAL_BENCH_DIR := $(HERE)/primal-bench
PRIMAL_BIN := $(PRIMAL_BENCH_DIR)/target/release/primal-bench

PRIMEZ_SMALL := segmentIterator\.SegmentIterator\.applySmallSievePrimes
PRIMEZ_MEDIUM := segmentIterator\.SegmentIterator\.(applyMediumSievePrimes|activateMediumSievePrimes)
PRIMEZ_LARGE := applyLargeSievePrimesBatch
PRIMEZ_DISCOVERY := findSievePrimesInSegment

PRIMESIEVE_SMALL := EratSmall::
PRIMESIEVE_MEDIUM := EratMedium::
PRIMESIEVE_LARGE := EratBig::

.PHONY: help all bench compare primesieve-build primez-build primal-build perf-primez perf-primesieve perf-primal clean distclean
.NOTPARALLEL:

help:
	@echo "primeZ vs. primesieve vs. primal benchmarks"
	@echo ""
	@echo "  make bench             build + perf-record + report all implementations"
	@echo "  make perf-primez       just primeZ"
	@echo "  make perf-primesieve   just primesieve"
	@echo "  make perf-primal       just primal"
	@echo "  make compare           re-print the side-by-side table from the last recordings"
	@echo "  make clean             remove build outputs and results"
	@echo "  make distclean         also remove the primesieve build tree"
	@echo ""
	@echo "  vars: N=$(N) SIEVE_KIB=$(SIEVE_KIB) PERF_FREQ=$(PERF_FREQ)"

all: bench

primesieve-build:
	cmake -S $(PRIMESIEVE_DIR) -B $(PRIMESIEVE_BUILD) \
		-DCMAKE_BUILD_TYPE=RelWithDebInfo -DBUILD_TESTS=OFF \
		-DBUILD_STATIC_LIBS=ON -DBUILD_SHARED_LIBS=OFF
	cmake --build $(PRIMESIEVE_BUILD) -j$(JOBS)

primez-build:
	rm -rf $(ROOT)/zig-out $(ROOT)/.zig-cache
	cd $(ROOT) && zig build -Dl1_cache_size=$(SIEVE_KIB)

perf-primez: primez-build
	@mkdir -p $(RESULTS)
	@echo "== perf recording primez CLI (up to $(N)) =="
	@t=$$($(SCRIPTS)/perf_and_time.sh $(PERF_FREQ) $(RESULTS)/primez.perf.data -- $(ROOT)/zig-out/bin/primez $(N)); \
	echo "$$t" > $(RESULTS)/primez.seconds; \
	echo "wall time: $${t}s"; \
	echo; \
	echo "== primeZ phase breakdown (perf self-time) =="; \
	$(SCRIPTS)/summarize.sh $(RESULTS)/primez.perf.data "$$t" $(RESULTS)/primez.report.txt \
		'small=$(PRIMEZ_SMALL)' 'medium=$(PRIMEZ_MEDIUM)' 'large=$(PRIMEZ_LARGE)' 'discovery=$(PRIMEZ_DISCOVERY)' \
		| tee $(RESULTS)/primez.summary.txt

perf-primesieve: primesieve-build
	@mkdir -p $(RESULTS)
	@if [ -f $(RESULTS)/primesieve.perf.data ] && [ -f $(RESULTS)/primesieve.seconds ] && \
	   [ -f $(RESULTS)/primesieve.report.txt ] && [ -f $(RESULTS)/primesieve.summary.txt ]; then \
		echo "== primesieve: reusing cached results from a previous run (make clean to force a fresh one) =="; \
		cat $(RESULTS)/primesieve.summary.txt; \
	else \
		echo "== perf recording primesieve (single-threaded, sieve size $(SIEVE_KIB) KiB, up to $(N)) =="; \
		t=$$($(SCRIPTS)/perf_and_time.sh $(PERF_FREQ) $(RESULTS)/primesieve.perf.data -- $(PRIMESIEVE_BIN) $(N) -t1 -s$(SIEVE_KIB) --time --no-status); \
		echo "$$t" > $(RESULTS)/primesieve.seconds; \
		echo "wall time: $${t}s"; \
		echo; \
		echo "== primesieve phase breakdown (perf self-time) =="; \
		$(SCRIPTS)/summarize.sh $(RESULTS)/primesieve.perf.data "$$t" $(RESULTS)/primesieve.report.txt \
			'small=$(PRIMESIEVE_SMALL)' 'medium=$(PRIMESIEVE_MEDIUM)' 'large=$(PRIMESIEVE_LARGE)' \
			| tee $(RESULTS)/primesieve.summary.txt; \
	fi

primal-build:
	cd $(PRIMAL_BENCH_DIR) && cargo build --release

perf-primal: primal-build
	@mkdir -p $(RESULTS)
	@if [ -f $(RESULTS)/primal.perf.data ] && [ -f $(RESULTS)/primal.seconds ] && [ -f $(RESULTS)/primal.summary.txt ]; then \
		echo "== primal: reusing cached results from a previous run (make clean to force a fresh one) =="; \
		cat $(RESULTS)/primal.summary.txt; \
	else \
		echo "== perf recording primal (single-threaded, up to $(N)) =="; \
		t=$$($(SCRIPTS)/perf_and_time.sh $(PERF_FREQ) $(RESULTS)/primal.perf.data -- $(PRIMAL_BIN) $(N)); \
		echo "$$t" > $(RESULTS)/primal.seconds; \
		echo "wall time: $${t}s" | tee $(RESULTS)/primal.summary.txt; \
	fi

bench: perf-primez perf-primesieve perf-primal compare

compare:
	@echo
	@echo "== primeZ vs. primesieve vs. primal =="
	@$(SCRIPTS)/compare.sh \
		$(RESULTS)/primez.report.txt "$$(cat $(RESULTS)/primez.seconds)" \
		$(RESULTS)/primesieve.report.txt "$$(cat $(RESULTS)/primesieve.seconds)" \
		"$$(cat $(RESULTS)/primal.seconds 2>/dev/null)"

clean:
	rm -rf $(ROOT)/zig-out $(ROOT)/.zig-cache $(RESULTS)

distclean: clean
	rm -rf $(PRIMESIEVE_BUILD) $(PRIMAL_BENCH_DIR)/target
