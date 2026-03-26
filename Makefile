build: ## Build pyr
	zig build

test: ## Run tests
	zig build test

run: ## Run pyr (usage: make run ARGS="build example.pyr")
	zig build run -- $(ARGS)

examples: build ## Compile example programs
	./zig-out/bin/pyr run examples/hello.pyr
	./zig-out/bin/pyr run examples/basics.pyr
	./zig-out/bin/pyr run examples/strings.pyr

bench: ## Run benchmarks (release build)
	./bench/run.sh

clean: ## Clean build artifacts
	rm -rf zig-out .zig-cache zig-cache

.PHONY: build test run examples bench clean help
help: ## Show help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(firstword $(MAKEFILE_LIST)) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[32m%-20s\033[0m %s\n", $$1, $$2}'
