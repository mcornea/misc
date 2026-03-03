BINARY := buildfarmsim
CONFIG ?=

ETCD_V35_VERSION ?= 3.5.27
ETCD_V36_VERSION ?= 3.6.8
ETCD_ARCH ?= $(shell uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')
ETCD_OS ?= $(shell uname -s | tr A-Z a-z)
ETCD_V35_DIR := /tmp/etcd-v3.5
ETCD_V36_DIR := /tmp/etcd-v3.6

.DEFAULT_GOAL := help

build:  ## Build the simulator binary
	go build -o $(BINARY) .

# --- etcd binary download ---
download-etcd-v35: $(ETCD_V35_DIR)/etcd  ## Download etcd v3.5 to /tmp
$(ETCD_V35_DIR)/etcd:
	@echo "Downloading etcd v$(ETCD_V35_VERSION) to $(ETCD_V35_DIR)..."
	@mkdir -p $(ETCD_V35_DIR)
	@curl -fsSL https://github.com/etcd-io/etcd/releases/download/v$(ETCD_V35_VERSION)/etcd-v$(ETCD_V35_VERSION)-$(ETCD_OS)-$(ETCD_ARCH).tar.gz \
		| tar xz -C $(ETCD_V35_DIR) --strip-components=1
	@echo "etcd v$(ETCD_V35_VERSION) ready at $(ETCD_V35_DIR)/etcd"

download-etcd-v36: $(ETCD_V36_DIR)/etcd  ## Download etcd v3.6 to /tmp
$(ETCD_V36_DIR)/etcd:
	@echo "Downloading etcd v$(ETCD_V36_VERSION) to $(ETCD_V36_DIR)..."
	@mkdir -p $(ETCD_V36_DIR)
	@curl -fsSL https://github.com/etcd-io/etcd/releases/download/v$(ETCD_V36_VERSION)/etcd-v$(ETCD_V36_VERSION)-$(ETCD_OS)-$(ETCD_ARCH).tar.gz \
		| tar xz -C $(ETCD_V36_DIR) --strip-components=1
	@echo "etcd v$(ETCD_V36_VERSION) ready at $(ETCD_V36_DIR)/etcd"

download-etcd: download-etcd-v35 download-etcd-v36  ## Download both etcd versions

# --- Custom run (pass CONFIG=<file.json>) ---
run: build  ## Run with a custom config: make run CONFIG=myconfig.json
	@if [ -z "$(CONFIG)" ]; then echo "Usage: make run CONFIG=<config.json>"; exit 1; fi
	./capture_profiles.sh $(CONFIG) run-$(basename $(CONFIG) .json)

# --- Quick comparison (~3 min per run) ---
run-quick-v35: build download-etcd-v35  ## Run quick workload against v3.5
	./capture_profiles.sh config-quick-v35.json run-quick-v35

run-quick-v36: build download-etcd-v36  ## Run quick workload against v3.6
	./capture_profiles.sh config-quick-v36.json run-quick-v36

compare-quick: build  ## Generate comparison chart from quick run metrics
	./$(BINARY) -plot metrics-quick-v36.csv,metrics-quick-v35.csv \
		-legend "v3.6,v3.5" -o quick-comparison.html

# --- Full comparison (~5 min per run) ---
run-full-v35: build download-etcd-v35  ## Run full workload against v3.5
	./capture_profiles.sh config-full-v35.json run-full-v35

run-full-v36: build download-etcd-v36  ## Run full workload against v3.6
	./capture_profiles.sh config-full-v36.json run-full-v36

compare-full: build  ## Generate comparison chart from full run metrics
	./$(BINARY) -plot metrics-full-v36.csv,metrics-full-v35.csv \
		-legend "v3.6,v3.5" -o full-comparison.html

# --- SVG generation from peak profiles ---
svgs:  ## Generate SVGs from peak heap profiles in all run-* dirs
	@for DIR in run-quick-v35 run-quick-v36 run-full-v35 run-full-v36; do \
		if [ -d "$$DIR/profiles" ]; then \
			PEAK=$$(ls -S $$DIR/profiles/heap_*.pb.gz 2>/dev/null | head -1); \
			if [ -n "$$PEAK" ]; then \
				echo "Generating SVGs from $$PEAK"; \
				go tool pprof -svg -inuse_space -nodefraction=0 -edgefraction=0 -nodecount=0 "$$PEAK" \
					| sed 's/style="dashed"/style="solid"/g' > $$DIR/heap-inuse.svg; \
				go tool pprof -svg -inuse_space -focus="kvsToEvents" -nodefraction=0 -edgefraction=0 "$$PEAK" \
					| sed 's/style="dashed"/style="solid"/g' > $$DIR/heap-kvsToEvents.svg; \
			fi; \
		fi; \
	done

# --- Cleanup ---
clean:  ## Kill etcd and remove all generated files
	pkill -9 etcd || true
	rm -rf data-etcd-*
	rm -rf log-*
	rm -rf run-*
	rm -f metrics-*.csv
	rm -f *.html
	rm -f $(BINARY)

# --- Help ---
help:  ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | \
		sed 's/:.*## /\t/' | \
		awk -F '\t' '{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: build clean svgs help run \
	download-etcd download-etcd-v35 download-etcd-v36 \
	run-quick-v35 run-quick-v36 compare-quick \
	run-full-v35 run-full-v36 compare-full
