# Makefile for VRMMetalKit shader compilation
# Copyright 2025 Arkavo

.PHONY: help shaders clean test

help:
	@echo "VRMMetalKit Build Targets:"
	@echo "  make shaders  - Compile all .metal files into metallib"
	@echo "  make clean    - Remove temporary build files"
	@echo "  make test     - Run Swift tests"

# Compile all Metal shaders into a single metallib
shaders:
	@echo "🔨 Compiling Metal shaders..."
	@mkdir -p /tmp/vrm-shaders
	@xcrun metal -c Sources/VRMMetalKit/Shaders/*.metal -o /tmp/vrm-shaders/shaders.air
	@xcrun metallib /tmp/vrm-shaders/shaders.air -o Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib
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