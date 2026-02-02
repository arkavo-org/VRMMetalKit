# Makefile for VRMMetalKit shader compilation
# Copyright 2025 Arkavo

.PHONY: help shaders clean test visual-regression dqs-test

help:
	@echo "VRMMetalKit Build Targets:"
	@echo "  make shaders          - Compile all .metal files into metallib"
	@echo "  make clean            - Remove temporary build files"
	@echo "  make test             - Run Swift tests"
	@echo "  make dqs-test         - Run DQS implementation tests"
	@echo "  make visual-regression- Generate reference videos"
	@echo "  make visual-test      - Run visual regression tests"

# Compile all Metal shaders into a single metallib
shaders:
	@echo "🔨 Compiling Metal shaders..."
	@mkdir -p /tmp/vrm-shaders
	@for file in Sources/VRMMetalKit/Shaders/*.metal; do \
		echo "  Compiling $$file..."; \
		xcrun metal -c $$file -o /tmp/vrm-shaders/$$(basename $$file .metal).air; \
	done
	@xcrun metallib /tmp/vrm-shaders/*.air -o Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib
	@echo "✅ Shaders compiled successfully"
	@echo "📦 Output: Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib"
	@ls -lh Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib

# List functions in the compiled metallib
list-functions:
	@echo "📋 Functions in VRMMetalKitShaders.metallib:"
	@xcrun metal-objdump -macho -function-list Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib 2>/dev/null || echo "metal-objdump not available"

# Clean temporary files
clean:
	@echo "🗑️  Cleaning temporary files..."
	@rm -rf /tmp/vrm-shaders
	@echo "✅ Clean complete"

# Run tests
test:
	@echo "🧪 Running tests..."
	@swift test

# Build the package
build:
	@echo "🔨 Building VRMMetalKit..."
	@swift build

# Run DQS-specific tests
dqs-test:
	@echo "🦴 Running DQS tests..."
	@swift test --filter DualQuaternion

# Run visual regression tests (requires VRM model)
visual-test:
	@echo "🎬 Running visual regression tests..."
	@./scripts/run-visual-regression-tests.sh --test-dqs

# Generate reference videos for regression testing
visual-regression:
	@echo "🎬 Generating reference videos..."
	@./scripts/run-visual-regression-tests.sh --generate-refs

# Run DQS comparison test (verifies DQS produces different output than LBS)
dqs-compare:
	@echo "🦴 Testing DQS vs LBS..."
	@./scripts/test-dqs-regression.sh --verbose

# Run CI tests (minimal output)
ci-test:
	@echo "🧪 Running CI tests..."
	@CI=true ./scripts/ci-regression-tests.sh

# Build and run tests
all: shaders build test
	@echo "✅ All tasks complete"
