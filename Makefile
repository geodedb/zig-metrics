# metrics - Zig Library Makefile
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2025 CodePros

.PHONY: all build test test-unit test-integration clean check fmt help dev ci bench
.PHONY: test-release-safe test-release-fast test-release-small test-all-optimizations
.PHONY: pre-commit-install pre-commit pre-commit-run
.PHONY: scale-bench bench-save bench-baseline bench-compare

# Default target: build and run tests
all: build test-unit
	@echo "✅ All builds and tests completed successfully!"

# Build the library
build:
	@echo "🔨 Building metrics..."
	@zig build

# Run all tests
test: test-unit test-integration
	@echo "✅ All tests completed"

# Run unit tests only
test-unit:
	@echo "🧪 Running unit tests..."
	@zig build test --summary all

# Run integration tests only
test-integration:
	@echo "🔗 Running integration tests..."
	@zig build test-integration --summary all

# Clean build artifacts
clean:
	@echo "🧹 Cleaning build artifacts..."
	@rm -rf zig-cache zig-out .zig-cache

# Check for compilation errors (fast, no codegen)
check:
	@echo "🔍 Checking for compilation errors..."
	@zig build check

# Run variance benchmark
bench:
	@echo "Running variance benchmark..."
	@zig build bench -Doptimize=ReleaseFast

# Run multi-tier scale benchmark (human-readable to stderr, JSON to stdout)
scale-bench:
	@zig build scale-bench

# Run scale benchmark and save results with current commit SHA
bench-save:
	@mkdir -p benchmarks/results
	@zig build scale-bench 2>/dev/null > benchmarks/results/$$(git rev-parse --short HEAD).json
	@echo "Saved to benchmarks/results/$$(git rev-parse --short HEAD).json"

# Run scale benchmark and save as the accepted baseline
bench-baseline:
	@mkdir -p benchmarks/results
	@zig build scale-bench 2>/dev/null > benchmarks/results/baseline.json
	@echo "Saved to benchmarks/results/baseline.json"

# Run scale benchmark and compare against baseline (exits 1 on regression)
bench-compare:
	@if [ ! -f benchmarks/results/baseline.json ]; then \
		echo "No baseline found. Run 'make bench-baseline' first."; \
		exit 1; \
	fi
	@zig build scale-bench 2>/dev/null > /tmp/metrics-bench-current.json
	@zig build compare-bench -- benchmarks/results/baseline.json /tmp/metrics-bench-current.json

# Format source code
fmt:
	@echo "📝 Formatting code..."
	@zig fmt src/ tests/ benchmarks/ build.zig

# Quick development iteration loop
dev: fmt check test-unit
	@echo "✅ Development checks passed"

# Full CI pipeline (clean slate)
ci: clean build test
	@echo "✅ CI pipeline passed"

# Release optimization level tests
test-release-safe:
	@echo "🧪 Testing with ReleaseSafe..."
	@zig build test -Doptimize=ReleaseSafe --summary all

test-release-fast:
	@echo "🧪 Testing with ReleaseFast..."
	@zig build test -Doptimize=ReleaseFast --summary all

test-release-small:
	@echo "🧪 Testing with ReleaseSmall..."
	@zig build test -Doptimize=ReleaseSmall --summary all

test-all-optimizations: test-unit test-release-safe test-release-fast test-release-small
	@echo "✅ All optimization levels passed"

# Pre-commit hook management
pre-commit-install:
	@echo "📦 Installing pre-commit hooks..."
	@pre-commit install
	@pre-commit install --hook-type commit-msg
	@pre-commit install --hook-type pre-push

pre-commit:
	@echo "🔍 Running pre-commit checks..."
	@pre-commit run --all-files

pre-commit-run: pre-commit

# Display help
help:
	@echo "metrics - Zig Library"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Development:"
	@echo "  all                  Build and run tests (default)"
	@echo "  build                Build the library"
	@echo "  dev                  Quick iteration: fmt + check + test"
	@echo "  ci                   Full CI: clean + build + test"
	@echo ""
	@echo "Testing:"
	@echo "  test                 Run all tests"
	@echo "  test-unit            Run unit tests only"
	@echo "  test-integration     Run integration tests only"
	@echo "  test-release-safe    Test with ReleaseSafe"
	@echo "  test-release-fast    Test with ReleaseFast"
	@echo "  test-release-small   Test with ReleaseSmall"
	@echo "  test-all-optimizations  Test all optimization levels"
	@echo ""
	@echo "Benchmarks:"
	@echo "  bench                Run variance benchmark (stability)"
	@echo "  scale-bench          Run multi-tier scale benchmark (JSON)"
	@echo "  bench-save           Run and save results as <sha>.json"
	@echo "  bench-baseline       Run and save as baseline.json"
	@echo "  bench-compare        Run and compare against baseline"
	@echo ""
	@echo "Code Quality:"
	@echo "  fmt                  Format source code"
	@echo "  check                Check for compilation errors"
	@echo "  pre-commit           Run pre-commit hooks"
	@echo "  pre-commit-install   Install pre-commit hooks"
	@echo ""
	@echo "Maintenance:"
	@echo "  clean                Remove build artifacts"
	@echo "  help                 Show this help message"
