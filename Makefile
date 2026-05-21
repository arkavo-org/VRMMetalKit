# Makefile for VRMMetalKit shader compilation
# Copyright 2025 Arkavo

.PHONY: help shaders shaders-macos shaders-ios shaders-iossim gltf-shaders clean test docs docs-static muter-bootstrap mutation-test

help:
	@echo "VRMMetalKit Build Targets:"
	@echo "  make shaders       - Compile all three VRMMetalKit metallib slices (macOS / iOS / iOS Simulator)"
	@echo "  make shaders-macos - Compile only the macOS slice (FP32)"
	@echo "  make shaders-ios   - Compile only the iOS device slice (FP16)"
	@echo "  make shaders-iossim- Compile only the iOS Simulator slice (FP16)"
	@echo "  make gltf-shaders  - Compile GLTFMetalKit (PBR) shaders into metallib"
	@echo "  make clean         - Remove temporary build files"
	@echo "  make test          - Run Swift tests"
	@echo "  make docs          - Preview documentation locally"
	@echo "  make docs-static   - Generate a static documentation site under .build/docs"
	@echo "  make muter-bootstrap - Build muter from a pinned SHA into .build/tools/"
	@echo "  make mutation-test - Run mutation testing against DepthBiasCalculator"

# Compile all VRM Metal shaders into three SDK-specific metallibs:
#   - macosx          (FP32, baseline; preserves PR #279's safe-default)
#   - iphoneos        (FP16, mobile double-rate payoff)
#   - iphonesimulator (FP16, simulator-native; fixes nil-pipeline error)
# -Wall -Wextra enables the common clang warning classes; -Werror promotes
# them to hard errors so the CI Shaders job (and local `make shaders`)
# catches issues like unused functions, writable-buffer aliasing, and
# sign-compare bugs before they become harder to fix later.
shaders: shaders-macos shaders-ios shaders-iossim
	@echo "✅ All shader slices built"

shaders-macos:
	@echo "🔨 Compiling macOS shaders (FP32)..."
	@mkdir -p /tmp/vrm-shaders-macos
	@for file in Sources/VRMMetalKit/Shaders/*.metal; do \
		echo "  Compiling $$file..."; \
		xcrun -sdk macosx metal -Wall -Wextra -Werror \
			-c $$file -o /tmp/vrm-shaders-macos/$$(basename $$file .metal).air; \
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
		xcrun -sdk iphoneos metal -Wall -Wextra -Werror \
			-mios-version-min=26.0 -DMTOON_USE_HALF_PRECISION=1 \
			-c $$file -o /tmp/vrm-shaders-ios/$$(basename $$file .metal).air; \
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
		xcrun -sdk iphonesimulator metal -Wall -Wextra -Werror \
			-mios-simulator-version-min=26.0 -DMTOON_USE_HALF_PRECISION=1 \
			-c $$file -o /tmp/vrm-shaders-iossim/$$(basename $$file .metal).air; \
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
		xcrun metal -Wall -Wextra -Werror -c $$file -o /tmp/gltf-shaders/$$(basename $$file .metal).air; \
	done
	@xcrun metallib /tmp/gltf-shaders/*.air -o Sources/GLTFMetalKit/Resources/GLTFMetalKitShaders.metallib
	@echo "✅ GLTFMetalKit shaders compiled"
	@echo "📦 Output: Sources/GLTFMetalKit/Resources/GLTFMetalKitShaders.metallib"
	@ls -lh Sources/GLTFMetalKit/Resources/GLTFMetalKitShaders.metallib

# Mutation testing (issue #282) — first target: DepthBiasCalculator
# muter is built from a pinned master SHA into .build/tools/ because the
# last tagged release (16, 2023) predates Swift 6.2 toolchain changes.
MUTER_SHA := 99624ecfde93dac3cc1f7a66ac6f7df05611091d
MUTER_BIN := .build/tools/bin/muter

$(MUTER_BIN):
	@echo "🔧 Building muter @ $(MUTER_SHA)..."
	@mkdir -p .build/tools
	@if [ ! -d .build/tools/muter-src ]; then \
		git clone https://github.com/muter-mutation-testing/muter.git .build/tools/muter-src; \
	fi
	@cd .build/tools/muter-src && git fetch && git checkout $(MUTER_SHA)
	@cd .build/tools/muter-src && swift build -c release --product muter
	@mkdir -p .build/tools/bin
	@ln -sf ../muter-src/.build/release/muter $(MUTER_BIN)
	@echo "✅ muter built: $$(./$(MUTER_BIN) --version 2>/dev/null || echo unknown)"

muter-bootstrap: $(MUTER_BIN)
	@$(MUTER_BIN) --version

mutation-test: $(MUTER_BIN)
	@mkdir -p .build/mutation-testing
	@$(MUTER_BIN) run \
		--configuration .muter/depth-bias.yml \
		--files-to-mutate Sources/GLTFCore/Utilities/DepthBiasCalculator.swift \
		--skip-coverage \
		--format json \
		--output .build/mutation-testing/last-run.json

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