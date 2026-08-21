# Makefile for VRMMetalKit shader compilation
# Copyright 2025 Arkavo

.PHONY: help shaders shaders-macos shaders-ios shaders-iossim shaders-visionos shaders-visionossim gltf-shaders clean test docs docs-static gputrace gputrace-baseline bench-baseline bench-gate bench-visionos bench-visionos-sim

help:
	@echo "VRMMetalKit Build Targets:"
	@echo "  make shaders       - Compile all five VRMMetalKit metallib slices (macOS / iOS / iOS Sim / visionOS / visionOS Sim)"
	@echo "  make shaders-macos - Compile only the macOS slice (FP16)"
	@echo "  make shaders-ios   - Compile only the iOS device slice (FP16)"
	@echo "  make shaders-iossim- Compile only the iOS Simulator slice (FP16)"
	@echo "  make shaders-visionos    - Compile only the visionOS device slice (FP16)"
	@echo "  make shaders-visionossim - Compile only the visionOS Simulator slice (FP16)"
	@echo "  make gltf-shaders  - Compile GLTFMetalKit (PBR) shaders into metallib"
	@echo "  make clean         - Remove temporary build files"
	@echo "  make test          - Run Swift tests"
	@echo "  make gputrace      - Capture a .gputrace of the bundled avatar render (inspect with gpudebug)"
	@echo "  make gputrace-baseline - Capture a .gputrace matching the VRMBenchmark baseline (animated + spring, 1024px)"
	@echo "  make bench-baseline - Record the authoritative perf baseline (run on the dedicated perf machine)"
	@echo "  make bench-gate    - Gate the current build against baselines/baseline.json (perf machine only)"
	@echo "  make bench-visionos - Stereo reverse-Z compositor-shaped bench (preferred vs host submit)"
	@echo "  make bench-visionos-sim - Same bench on the visionOS Simulator GPU (Apple Vision Pro 26.5)"
	@echo "  make docs          - Preview documentation locally"
	@echo "  make docs-static   - Generate a static documentation site under .build/docs"

# Compile all VRM Metal shaders into five SDK-specific metallibs:
#   - macosx          (FP16; supersedes PR #279's FP32 safe-default — measured
#                      via gpudebug on M4: -5.8% encoder time and fragment
#                      occupancy 21%→71% at 2048px, with the full MToon
#                      conformance battery pixel-clean)
#   - iphoneos        (FP16, mobile double-rate payoff)
#   - iphonesimulator (FP16, simulator-native; fixes nil-pipeline error)
#   - xros            (FP16; Vision Pro is the same Apple-Silicon GPU class
#                      as iOS, so the double-rate payoff carries over)
#   - xrsimulator     (FP16, simulator-native — without it visionOS falls
#                      through to the macOS slice and pipeline creation fails)
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
shaders: shaders-macos shaders-ios shaders-iossim shaders-visionos shaders-visionossim
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

shaders-visionos:
	@echo "🔨 Compiling visionOS device shaders (FP16)..."
	@mkdir -p /tmp/vrm-shaders-visionos
	@for file in Sources/VRMMetalKit/Shaders/*.metal; do \
		echo "  Compiling $$file..."; \
		xcrun -sdk xros metal -Wall -Wextra -Werror $(MSL_STD) \
			-mtargetos=xros26.0 -DMTOON_USE_HALF_PRECISION=1 \
			-c $$file -o /tmp/vrm-shaders-visionos/$$(basename $$file .metal).air || exit 1; \
	done
	@xcrun -sdk xros metallib /tmp/vrm-shaders-visionos/*.air \
		-o Sources/VRMMetalKit/Resources/VRMMetalKitShaders_visionOS.metallib
	@echo "📦 Output: Sources/VRMMetalKit/Resources/VRMMetalKitShaders_visionOS.metallib"
	@ls -lh Sources/VRMMetalKit/Resources/VRMMetalKitShaders_visionOS.metallib

shaders-visionossim:
	@echo "🔨 Compiling visionOS Simulator shaders (FP16)..."
	@mkdir -p /tmp/vrm-shaders-visionossim
	@for file in Sources/VRMMetalKit/Shaders/*.metal; do \
		echo "  Compiling $$file..."; \
		xcrun -sdk xrsimulator metal -Wall -Wextra -Werror $(MSL_STD) \
			-mtargetos=xros26.0-simulator -DMTOON_USE_HALF_PRECISION=1 \
			-c $$file -o /tmp/vrm-shaders-visionossim/$$(basename $$file .metal).air || exit 1; \
	done
	@xcrun -sdk xrsimulator metallib /tmp/vrm-shaders-visionossim/*.air \
		-o Sources/VRMMetalKit/Resources/VRMMetalKitShaders_visionOSSimulator.metallib
	@echo "📦 Output: Sources/VRMMetalKit/Resources/VRMMetalKitShaders_visionOSSimulator.metallib"
	@ls -lh Sources/VRMMetalKit/Resources/VRMMetalKitShaders_visionOSSimulator.metallib

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

# Capture a GPU trace that matches the VRMBenchmark render baseline: the actual
# AvatarSample_A model at 1024px, standard radiometric lighting, animated, with
# spring-bone physics — so the trace's encoders (SpringBone compute + render) and
# GPU time line up with the benchmark's gpu p95. Override any path/size/animation
# via the GPUTRACE_BASELINE_* / GPUTRACE_VRM / GPUTRACE_VRMA variables.
GPUTRACE_BASELINE_OUT  ?= /tmp/vrmmetalkit/baseline.gputrace
GPUTRACE_BASELINE_SIZE ?= 1024
GPUTRACE_VRM           ?= $(CURDIR)/AvatarSample_A.vrm.glb
GPUTRACE_VRMA          ?= $(CURDIR)/VRMA_01.vrma
gputrace-baseline:
	@echo "🎞️  Capturing baseline GPU trace ($(GPUTRACE_BASELINE_SIZE)px, standard lighting, animated + spring) to $(GPUTRACE_BASELINE_OUT)..."
	@METAL_CAPTURE_ENABLED=1 \
		VRM_GPUTRACE_OUT=$(GPUTRACE_BASELINE_OUT) \
		VRM_GPUTRACE_SIZE=$(GPUTRACE_BASELINE_SIZE) \
		VRM_GPUTRACE_LIGHTING=standard \
		VRM_GPUTRACE_SPRING=1 \
		VRM_GPUTRACE_VRMA=$(GPUTRACE_VRMA) \
		VRM_TEST_VRM1_PATH=$(GPUTRACE_VRM) \
		swift test --filter GPUTraceCaptureTests --disable-sandbox
	@echo "✅ Inspect with: gpudebug -t $(GPUTRACE_BASELINE_OUT)"

# Performance baseline + regression gate — the AUTHORITATIVE perf check.
# Run these only on the dedicated performance machine (a fixed Apple-silicon Mac);
# CI's hosted-runner numbers vary too much to gate on. `bench-baseline` records the
# reference into baselines/baseline.json (commit it from the perf machine);
# `bench-gate` re-runs and fails on a regression past the benchmark's thresholds.
# Keep the two in lockstep — they share the same inputs and frame counts.
BENCH_VRM      ?= AvatarSample_A_1.0.vrm.glb
BENCH_VRMA     ?= VRMA_01.vrma
BENCH_FRAMES   ?= 500
BENCH_WARMUP   ?= 30
BENCH_BASELINE ?= baselines/baseline.json
BENCH_ARGS      = --mode render --frames $(BENCH_FRAMES) --warmup $(BENCH_WARMUP) --vrma $(BENCH_VRMA)

bench-baseline:
	@echo "📊  Recording performance baseline to $(BENCH_BASELINE) (this machine is the reference)..."
	@swift build -c release --product VRMBenchmark
	@mkdir -p $(dir $(BENCH_BASELINE))
	@.build/release/VRMBenchmark $(BENCH_VRM) $(BENCH_ARGS) --label baseline-$$(hostname -s) --json $(BENCH_BASELINE)
	@echo "✅ Baseline written. Commit $(BENCH_BASELINE) from this machine."

bench-gate:
	@echo "🚦  Gating current build against $(BENCH_BASELINE)..."
	@swift build -c release --product VRMBenchmark
	@.build/release/VRMBenchmark $(BENCH_VRM) $(BENCH_ARGS) --label gate-$$(hostname -s) --baseline $(BENCH_BASELINE)

# Compositor-shaped stereo bench (Mac stand-in for visionOS). Does not
# replace bench-gate. Preferred submit simulates once; host submit is the
# older per-eye drawOffscreen path.
BENCH_VISIONOS_VRM ?= AvatarSample_U_1.0.vrm.glb
BENCH_VISIONOS_ARGS = --mode visionos --frames 200 --warmup 30 --vrma $(BENCH_VRMA) --spring-bone --fps 90

bench-visionos:
	@echo "🥽  visionOS-shaped stereo bench (preferred, then host)..."
	@swift build -c release --product VRMBenchmark
	@mkdir -p perf-review-output
	@.build/release/VRMBenchmark $(BENCH_VISIONOS_VRM) $(BENCH_VISIONOS_ARGS) \
		--visionos-submit preferred --label visionos-preferred-$$(hostname -s) \
		--json perf-review-output/bench-visionos-preferred.json
	@.build/release/VRMBenchmark $(BENCH_VISIONOS_VRM) $(BENCH_VISIONOS_ARGS) \
		--visionos-submit host --label visionos-host-$$(hostname -s) \
		--json perf-review-output/bench-visionos-host.json

# Offscreen + compositor sample on the visionOS Simulator GPU (not a Vision Pro).
BENCH_VISIONOS_SIM ?= Apple Vision Pro
BENCH_VISIONOS_SIM_OS ?= 26.5
bench-visionos-sim:
	@echo "🥽  visionOS Simulator GPU bench..."
	@cd VisionHost && xcodegen generate
	@xcodebuild -project VisionHost/VRMVisionHost.xcodeproj -scheme VRMVisionHost \
		-destination 'platform=visionOS Simulator,name=$(BENCH_VISIONOS_SIM),OS=$(BENCH_VISIONOS_SIM_OS)' \
		-configuration Release -derivedDataPath VisionHost/DerivedData build
	@xcrun simctl boot "$(BENCH_VISIONOS_SIM)" || true
	@xcrun simctl install booted \
		VisionHost/DerivedData/Build/Products/Release-xrsimulator/VRMVisionHost.app
	@mkdir -p perf-review-output
	@SIMCTL_CHILD_VRM_VISIONOS_BENCH=both \
		xcrun simctl launch --stdout=$(CURDIR)/perf-review-output/visionos-sim-stdout.log \
		--stderr=$(CURDIR)/perf-review-output/visionos-sim-stderr.log \
		booted org.arkavo.VRMVisionHost
	@echo "⏳ waiting for bench JSON (offscreen + compositor sample)..."
	@for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do \
		DATA=$$(xcrun simctl get_app_container booted org.arkavo.VRMVisionHost data 2>/dev/null); \
		if [ -n "$$DATA" ] && [ -f "$$DATA/Documents/bench-visionos-xrsimulator.json" ]; then \
			cp "$$DATA/Documents/bench-visionos-xrsimulator.json" perf-review-output/; \
			echo "✅ wrote perf-review-output/bench-visionos-xrsimulator.json"; \
			exit 0; \
		fi; \
		sleep 5; \
	done; \
	echo "⚠️  JSON not ready; check perf-review-output/visionos-sim-stdout.log"

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