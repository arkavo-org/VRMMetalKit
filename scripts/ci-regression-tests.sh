#!/bin/bash
#
# CI/CD Visual Regression Test Runner
#
# Designed for continuous integration environments
# Runs all visual regression tests with minimal output
#
# Usage:
#   ./scripts/ci-regression-tests.sh
#
# Environment Variables:
#   VRM_MODEL      Path to VRM model (default: ./AliciaSolid.vrm)
#   VRMA_ANIM      Path to VRMA animation (default: ./VRMA_01.vrma)
#   TEST_DURATION  Test duration in seconds (default: 1.0)
#   CI             Set to 'true' for CI mode (minimal output)
#
# Exit codes:
#   0  All tests passed
#   1  One or more tests failed
#

set -e

# Configuration
VRM_MODEL="${VRM_MODEL:-./AliciaSolid.vrm}"
VRMA_ANIM="${VRMA_ANIM:-./VRMA_01.vrma}"
TEST_DURATION="${TEST_DURATION:-1.0}"
TEST_FPS="${TEST_FPS:-30}"
CI="${CI:-false}"

# Logging functions
log_info() {
    if [ "$CI" != "true" ]; then
        echo "[INFO] $1"
    fi
}

log_error() {
    echo "[ERROR] $1" >&2
}

log_success() {
    if [ "$CI" != "true" ]; then
        echo "[PASS] $1"
    fi
}

# ============================================================================
# Setup
# ============================================================================

log_info "Starting visual regression tests..."

# Check swift
if ! command -v swift &> /dev/null; then
    log_error "Swift not found"
    exit 1
fi

# Build the tools
log_info "Building VRMVisualRegression..."
if ! swift build --target VRMVisualRegression -q 2>/dev/null; then
    log_error "Failed to build VRMVisualRegression"
    exit 1
fi

# Check for test files
SKIP_DQS_TEST=false
if [ ! -f "$VRM_MODEL" ]; then
    log_info "VRM model not found: $VRM_MODEL"
    SKIP_DQS_TEST=true
fi

if [ ! -f "$VRMA_ANIM" ]; then
    log_info "VRMA animation not found: $VRMA_ANIM"
    SKIP_DQS_TEST=true
fi

# ============================================================================
# Tests
# ============================================================================

TESTS_PASSED=0
TESTS_FAILED=0

# Test 1: DQS Shader Functions Exist
# ----------------------------------------------------------------------------
log_info "Test 1: Verifying DQS shader functions exist..."

# Run the GPU test which verifies shader functions
if swift test --filter testDQSShaderFunctionsExist 2>/dev/null | grep -q "passed"; then
    log_success "DQS shader functions exist"
    ((TESTS_PASSED++))
else
    log_error "DQS shader functions test failed"
    ((TESTS_FAILED++))
fi

# Test 2: DQS Memory Layout
# ----------------------------------------------------------------------------
log_info "Test 2: Verifying DQS memory layout..."

if swift test --filter testDualQuaternionMemoryLayoutForGPU 2>/dev/null | grep -q "passed"; then
    log_success "DQS memory layout correct"
    ((TESTS_PASSED++))
else
    log_error "DQS memory layout test failed"
    ((TESTS_FAILED++))
fi

# Test 3: LBS vs DQS Comparison (if files available)
# ----------------------------------------------------------------------------
if [ "$SKIP_DQS_TEST" = false ]; then
    log_info "Test 3: Comparing LBS vs DQS output..."
    
    if swift run VRMVisualRegression compare-lbs-dqs \
        "$VRM_MODEL" "$VRMA_ANIM" \
        -d "$TEST_DURATION" -f "$TEST_FPS" \
        -w 640 -h 360 > /tmp/dqs_test_output.txt 2>&1; then
        
        # Extract metrics from output
        MAX_DIFF=$(grep "Max difference:" /tmp/dqs_test_output.txt | tail -1 | awk '{print $3}')
        DIFF_FRAMES=$(grep "Different frames:" /tmp/dqs_test_output.txt | tail -1 | awk -F'[ /]' '{print $3}')
        TOTAL_FRAMES=$(grep "Different frames:" /tmp/dqs_test_output.txt | tail -1 | awk -F'[ /]' '{print $4}')
        
        log_info "DQS Results: max_diff=$MAX_DIFF, different_frames=$DIFF_FRAMES/$TOTAL_FRAMES"
        
        if [ -n "$MAX_DIFF" ] && (( $(echo "$MAX_DIFF > 0.01" | bc -l) )); then
            log_success "DQS produces different output from LBS"
            ((TESTS_PASSED++))
        else
            log_error "DQS output too similar to LBS (max_diff=$MAX_DIFF)"
            ((TESTS_FAILED++))
        fi
    else
        log_error "DQS comparison test failed to run"
        ((TESTS_FAILED++))
    fi
else
    log_info "Test 3: Skipped (missing input files)"
fi

# Test 4: Metallib Integrity
# ----------------------------------------------------------------------------
log_info "Test 4: Verifying metallib integrity..."

METALLIB="Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib"
if [ ! -f "$METALLIB" ]; then
    log_error "Metallib not found"
    ((TESTS_FAILED++))
else
    # Check file size
    SIZE=$(stat -f%z "$METALLIB" 2>/dev/null || stat -c%s "$METALLIB" 2>/dev/null)
    if [ "$SIZE" -gt 200000 ]; then
        log_success "Metallib size OK ($SIZE bytes)"
        ((TESTS_PASSED++))
    else
        log_error "Metallib too small ($SIZE bytes, expected > 200KB)"
        ((TESTS_FAILED++))
    fi
fi

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "========================================"
echo "Visual Regression Test Results"
echo "========================================"
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo "✓ All tests passed"
    exit 0
else
    echo "✗ $TESTS_FAILED test(s) failed"
    exit 1
fi
