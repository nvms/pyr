build: ## Build pyr
	zig build

test: ## Run tests
	zig build test

run: ## Run pyr (usage: make run ARGS="build example.pyr")
	zig build run -- $(ARGS)

examples: build ## Run and validate example programs
	@failed=0; total=0; \
	for f in examples/*.pyr; do \
		name=$$(basename $$f .pyr); \
		if [ "$$name" = "mathlib" ] || [ "$$name" = "tls_server" ]; then continue; fi; \
		total=$$((total + 1)); \
		expected="examples/$$name.expected"; \
		if [ -f "$$expected" ]; then \
			actual=$$(./zig-out/bin/pyr run $$f 2>&1); \
			exp=$$(cat $$expected); \
			if [ "$$actual" != "$$exp" ]; then \
				echo "FAIL $$f (output mismatch)"; \
				echo "  expected: $$exp"; \
				echo "  actual:   $$actual"; \
				failed=$$((failed + 1)); \
			else \
				echo "ok   $$f"; \
			fi; \
		else \
			if ./zig-out/bin/pyr run $$f > /dev/null 2>&1; then \
				echo "ok   $$f"; \
			else \
				echo "FAIL $$f (exit code $$?)"; \
				failed=$$((failed + 1)); \
			fi; \
		fi; \
	done; \
	echo ""; \
	echo "$$total examples, $$failed failed"; \
	if [ $$failed -gt 0 ]; then exit 1; fi

bench: ## Run benchmarks (release build)
	./bench/run.sh

clean: ## Clean build artifacts
	rm -rf zig-out .zig-cache zig-cache

.PHONY: build test run examples bench clean help
help: ## Show help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(firstword $(MAKEFILE_LIST)) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[32m%-20s\033[0m %s\n", $$1, $$2}'
