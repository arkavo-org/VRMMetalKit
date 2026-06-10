# Makefile for VRMMetalKit shader compilation
# Copyright 2025 Arkavo

.PHONY: help shaders shaders-macos shaders-ios shaders-iossim gltf-shaders clean test docs docs-static gputrace

help:
	@echo "VRMMetalKit Build Targets:"
	@echo "  make shaders       - Compile all three VRMMetalKit metallib slices (macOS / iOS / iOS Simulator)"
	@echo "  make shaders-macos - Compile only the macOS slice (FP16)"
	@echo "  make shaders-ios   - Compile only the iOS device slice (FP16)"
	@echo "  make shaders-iossim- Compile only the iOS Simulator slice (FP16)"
	@echo "  make gltf-shaders  - Compile GLTFMetalKit (PBR) shaders into metallib"
	@echo "  make clean         - Remove temporary build files"
	@echo "  make test          - Run Swift tests"
	@echo "  make gputrace      - Capture a .gputrace of the bundled avatar render (inspect with gpudebug)"
	@echo "  make docs          - Preview documentation locally"
	@echo "  make docs-static   - Generate a static documentation site under .build/docs"

# Compile all VRM Metal shaders into three SDK-specific metallibs:
#   - macosx          (FP16; supersedes PR #279's FP32 safe-default — measured
#                      via gpudebug on M4: -5.8% encoder time and fragment
#                      occupancy 21%→71% at 2048px, with the full MToon
#                      conformance battery pixel-clean)
#   - iphoneos        (FP16, mobile double-rate payoff)
#   - iphonesimulator (FP16, simulator-native; fixes nil-pipeline error)
# -Wall -Wextra enables the common clang warning classes; -Werror promotes
# them to hard errors so the CI Shaders job (and local `make shaders`)
# catches issues like unused functions, writable-buffer aliasing, and
# sign-compare bugs before they become harder to fix later.
# -std=metal4.0 pins the Metal language version to the macOS 26 / iOS 26
# deployment floor: a beta toolchain's default (e.g. metal4.1 from the
# Xcode 27 beta) produces slices MTLDevice.makeLibrary rejects on release
# OSes ("language version 4.1 is not supported on this OS" — issue #336).
# The -m*-version-min flags do NOT constrain the language version, so the
# explicit -std pin is the only protection. Bump it deliberately, together
# with the platforms floor in Package.swift.
MSL_STD := -std=metal4.0
shaders: shaders-macos shaders-ios shaders-iossim
	@echo "✅ All shader slices built"

shaders-macos:
	@echo "🔨 Compiling macOS shaders (FP16)..."
	@mkdir -p /tmp/vrm-shaders-macos
	@for file in Sources/VRMMetalKit/Shaders/*.metal; do \
		echo "  Compiling $$file..."; \
		xcrun -sdk macosx metal -Wall -Wextra -Werror $(MSL_STD) \
			-mmacos-version-min=26.0 -DMTOON_USE_HALF_PRECISION=1 \
			-c $$file -o /tmp/vrm-shaders-macos/$$(basename $$file .metal).air || exit 1; \
	done
	@xcrun -sdk macosx metallib /tmp/vrm-shaders-macos/*.air \
		-o Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib
	@echo "📦 Output: Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib"
	@ls -lh Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib

shaders-ios:
	@echo "🔨 Compiling iOS device shaders (FP16)..."
	@mkdir -p /tmp/vrm-shaders-ios
	@for file in Sources/VRMMetalKit/Shaders/*.metal; do \
		echo "  Compiling $$file..."; \
		xcrun -sdk iphoneos metal -Wall -Wextra -Werror $(MSL_STD) \
			-mios-version-min=26.0 -DMTOON_USE_HALF_PRECISION=1 \
			-c $$file -o /tmp/vrm-shaders-ios/$$(basename $$file .metal).air || exit 1; \
	done
	@xcrun -sdk iphoneos metallib /tmp/vrm-shaders-ios/*.air \
		-o Sources/VRMMetalKit/Resources/VRMMetalKitShaders_iOS.metallib
	@echo "📦 Output: Sources/VRMMetalKit/Resources/VRMMetalKitShaders_iOS.metallib"
	@ls -lh Sources/VRMMetalKit/Resources/VRMMetalKitShaders_iOS.metallib

shaders-iossim:
	@echo "🔨 Compiling iOS Simulator shaders (FP16)..."
	@mkdir -p /tmp/vrm-shaders-iossim
	@for file in Sources/VRMMetalKit/Shaders/*.metal; do \
		echo "  Compiling $$file..."; \
		xcrun -sdk iphonesimulator metal -Wall -Wextra -Werror $(MSL_STD) \
			-mios-simulator-version-min=26.0 -DMTOON_USE_HALF_PRECISION=1 \
			-c $$file -o /tmp/vrm-shaders-iossim/$$(basename $$file .metal).air || exit 1; \
	done
	@xcrun -sdk iphonesimulator metallib /tmp/vrm-shaders-iossim/*.air \
		-o Sources/VRMMetalKit/Resources/VRMMetalKitShaders_iOSSimulator.metallib
	@echo "📦 Output: Sources/VRMMetalKit/Resources/VRMMetalKitShaders_iOSSimulator.metallib"
	@ls -lh Sources/VRMMetalKit/Resources/VRMMetalKitShaders_iOSSimulator.metallib

# Compile GLTFMetalKit PBR shaders into a separate metallib so the
# inanimate-object renderer can load them without dragging the MToon /
# spring-bone kernels along. Same -Wall -Wextra -Werror policy as the
# VRM shader build above.
gltf-shaders:
	@echo "🔨 Compiling GLTFMetalKit shaders..."
	@mkdir -p /tmp/gltf-shaders
	@for file in Sources/GLTFMetalKit/Shaders/*.metal; do \
		echo "  Compiling $$file..."; \
		xcrun -sdk macosx metal -Wall -Wextra -Werror $(MSL_STD) \
			-mmacos-version-min=26.0 \
			-c $$file -o /tmp/gltf-shaders/$$(basename $$file .metal).air; \
	done
	@xcrun metallib /tmp/gltf-shaders/*.air -o Sources/GLTFMetalKit/Resources/GLTFMetalKitShaders.metallib
	@echo "✅ GLTFMetalKit shaders compiled"
	@echo "📦 Output: Sources/GLTFMetalKit/Resources/GLTFMetalKitShaders.metallib"
	@ls -lh Sources/GLTFMetalKit/Resources/GLTFMetalKitShaders.metallib

# List functions in the compiled metallib
list-functions:
	@echo "📋 Functions in VRMMetalKitShaders.metallib:"
	@xcrun metal-objdump -macho -function-list Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib 2>/dev/null || echo "metal-objdump not available"

# Clean temporary files
clean:
	@echo "🗑️  Cleaning temporary files..."
	@rm -rf /tmp/vrm-shaders /tmp/vrm-shaders-macos /tmp/vrm-shaders-ios /tmp/vrm-shaders-iossim /tmp/gltf-shaders
	@echo "✅ Clean complete"

# Run tests
test:
	@echo "🧪 Running tests..."
	@swift test

# Capture a GPU trace of the bundled avatar render for offline debugging.
# Override the output path with GPUTRACE_OUT=/path/to/out.gputrace and the
# fixture with GPUTRACE_MODEL=vrm0 (default renders the VRM 1.0 fixture).
GPUTRACE_OUT ?= /tmp/vrmmetalkit/avatar.gputrace
GPUTRACE_MODEL ?= vrm1
GPUTRACE_SIZE ?= 512
gputrace:
	@echo "🎞️  Capturing GPU trace ($(GPUTRACE_MODEL), $(GPUTRACE_SIZE)px) to $(GPUTRACE_OUT)..."
	@METAL_CAPTURE_ENABLED=1 VRM_GPUTRACE_OUT=$(GPUTRACE_OUT) VRM_GPUTRACE_MODEL=$(GPUTRACE_MODEL) VRM_GPUTRACE_SIZE=$(GPUTRACE_SIZE) \
		swift test --filter GPUTraceCaptureTests --disable-sandbox
	@echo "✅ Inspect with: gpudebug -t $(GPUTRACE_OUT)"

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