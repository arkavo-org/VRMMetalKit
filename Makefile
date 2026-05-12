# Makefile for VRMMetalKit shader compilation
# Copyright 2025 Arkavo

.PHONY: help shaders clean test docs docs-static

help:
	@echo "VRMMetalKit Build Targets:"
	@echo "  make shaders     - Compile all .metal files into metallib"
	@echo "  make clean       - Remove temporary build files"
	@echo "  make test        - Run Swift tests"
	@echo "  make docs        - Preview documentation locally"
	@echo "  make docs-static - Generate a static documentation site under .build/docs"

# Compile all Metal shaders into a single metallib.
# -Wall -Wextra enables the common clang warning classes; -Werror promotes
# them to hard errors so the CI Shaders job (and local `make shaders`)
# catches issues like unused functions, writable-buffer aliasing, and
# sign-compare bugs before they become harder to fix later.
shaders:
	@echo "🔨 Compiling Metal shaders..."
	@mkdir -p /tmp/vrm-shaders
	@for file in Sources/VRMMetalKit/Shaders/*.metal; do \
		echo "  Compiling $$file..."; \
		xcrun metal -Wall -Wextra -Werror -c $$file -o /tmp/vrm-shaders/$$(basename $$file .metal).air; \
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

# Build and run tests
all: shaders build test
	@echo "✅ All tasks complete"

# Build and preview docs locally (opens a local web server)
docs:
	@echo "📖 Previewing documentation locally..."
	@swift package --disable-sandbox preview-documentation --target VRMMetalKit

# Generate a static documentation site under .build/docs
docs-static:
	@echo "📖 Generating static documentation site..."
	@swift package --disable-sandbox \
		--allow-writing-to-directory .build/docs \
		generate-documentation --target VRMMetalKit \
		--disable-indexing \
		--transform-for-static-hosting \
		--hosting-base-path VRMMetalKit \
		--output-path .build/docs
	@echo "✅ Static site written to .build/docs"