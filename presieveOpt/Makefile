PYTHON ?= python3
VENV := .venv
VENV_PY := $(VENV)/bin/python

CAP_KIB ?= 32
NUM_BINS ?= 8
TIME_LIMIT ?= 60

.PHONY: help solve solve-balance solve-minmax solve-maxmin solve-cover venv clean

help:
	@echo "presieveOpt - bin-packing solver for primeZ's presieve grouping"
	@echo ""
	@echo "  make solve            fewest-bin grouping under CAP_KIB"
	@echo "  make solve-balance    exactly NUM_BINS bins (partition), minimizing RMS deviation from the mean bin size"
	@echo "  make solve-minmax     exactly NUM_BINS bins (partition), minimizing the single largest bin"
	@echo "  make solve-maxmin     exactly NUM_BINS bins (partition), maximizing the single smallest bin"
	@echo "  make solve-cover      exactly NUM_BINS bins (repeats allowed), minimizing RMS deviation from the CAP_KIB target"
	@echo "                        (all create a venv and install requirements.txt on first run)"
	@echo "  make clean            remove the venv"
	@echo ""
	@echo "  vars: CAP_KIB=$(CAP_KIB) NUM_BINS=$(NUM_BINS) TIME_LIMIT=$(TIME_LIMIT)"

STAMP := $(VENV)/.installed

$(STAMP): requirements.txt
	$(PYTHON) -m venv $(VENV)
	$(VENV_PY) -m pip install --quiet --upgrade pip
	$(VENV_PY) -m pip install --quiet -r requirements.txt
	touch $(STAMP)

venv: $(STAMP)

solve: venv
	$(VENV_PY) solve.py --objective mincount --cap-kib $(CAP_KIB)

solve-balance: venv
	$(VENV_PY) solve.py --objective balance --num-bins $(NUM_BINS)

solve-minmax: venv
	$(VENV_PY) solve.py --objective minmax --num-bins $(NUM_BINS)

solve-maxmin: venv
	$(VENV_PY) solve.py --objective maxmin --num-bins $(NUM_BINS)

solve-cover: venv
	$(VENV_PY) solve.py --objective cover --num-bins $(NUM_BINS) --cap-kib $(CAP_KIB) --time-limit $(TIME_LIMIT)

clean:
	rm -rf $(VENV) __pycache__
