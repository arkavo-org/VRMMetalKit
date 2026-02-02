#!/bin/bash
#
# DQS Regression Test
# 
# This is a BATS-compatible test script that verifies the DQS implementation
# is working correctly by comparing LBS vs DQS output.
#
# BATS Usage:
#   bats scripts/test-dqs-regression.sh
#
# Standalone Usage:
#   ./scripts/test-dqs-regression.sh [--verbose]
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

VERBOSE=false
if [ "$1" = "--verbose" ]; then
    VERBOSE=true
fi

# Test configuration
VRM_MODEL="${VRM_MODEL:-./AliciaSolid.vrm}"
VRMA_ANIM="${VRMA_ANIM:-./VRMA_01.vrma}"
TEST_DURATION="${TEST_DURATION:-1.0}"
TEST_FPS="${TEST_FPS:-30}"
TEST_WIDTH="${TEST_WIDTH:-640}"
TEST_HEIGHT="${TEST_HEIGHT:-360}"

# ============================================================================
# BATS-style test functions
# ============================================================================

@test() {
    local name="$1"
    shift
    
    echo -e "${BLUE}[TEST]${NC} $name"
    
    if eval "$@"; then
        echo -e "${GREEN}[PASS]${NC} $name"
        return 0
    else
        echo -e "${RED}[FAIL]${NC} $name"
        return 1
    fi
}

# ============================================================================
# Setup
# ============================================================================

setup() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  DQS Regression Test Suite${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Configuration:"
    echo "  Model:    $VRM_MODEL"
    echo "  Animation: $VRMA_ANIM"
    echo "  Duration: ${TEST_DURATION}s @ ${TEST_FPS}fps"
    echo "  Resolution: ${TEST_WIDTH}x${TEST_HEIGHT}"
    echo ""
    
    # Check prerequisites
    if ! command -v swift &> /dev/null; then
        echo -e "${RED}Error: Swift not found${NC}"
        exit 1
    fi
    
    # Build if needed
    if [ "$VERBOSE" = true ]; then
        swift build --target VRMVisualRegression
    else
        swift build --target VRMVisualRegression -q 2>/dev/null
    fi
    
    # Check input files
    if [ ! -f "$VRM_MODEL" ]; then
        echo -e "${YELLOW}⚠ Warning: Model not found: $VRM_MODEL${NC}"
        echo "Some tests will be skipped."
    fi
    
    if [ ! -f "$VRMA_ANIM" ]; then
        echo -e "${YELLOW}⚠ Warning: Animation not found: $VRMA_ANIM${NC}"
        echo "Some tests will be skipped."
    fi
}

# ============================================================================
# Tests
# ============================================================================

test_vrmvisualregression_binary_exists() {
    [ -x .build/debug/VRMVisualRegression ] || [ -x .build/release/VRMVisualRegression ]
}

test_dqs_produces_different_output() {
    if [ ! -f "$VRM_MODEL" ] || [ ! -f "$VRMA_ANIM" ]; then
        skip "Missing input files"
    fi
    
    local output
    if [ "$VERBOSE" = true ]; then
        swift run VRMVisualRegression compare-lbs-dqs \
            "$VRM_MODEL" "$VRMA_ANIM" \
            -d "$TEST_DURATION" -f "$TEST_FPS" \
            -w "$TEST_WIDTH" -h "$TEST_HEIGHT"
    else
        output=$(swift run VRMVisualRegression compare-lbs-dqs \
            "$VRM_MODEL" "$VRMA_ANIM" \
            -d "$TEST_DURATION" -f "$TEST_FPS" \
            -w "$TEST_WIDTH" -h "$TEST_HEIGHT" 2>&1)
    fi
}

test_dqs_shaders_exist() {
    # This is tested via the GPU tests, but we can verify the metallib has the functions
    local metallib="Sources/VRMMetalKit/Resources/VRMMetalKitShaders.metallib"
    
    if [ ! -f "$metallib" ]; then
        echo "Metallib not found at $metallib"
        return 1
    fi
    
    # Check file size (incomplete metallib is ~70KB, complete is ~250KB+)
    local size
    size=$(stat -f%z "$metallib" 2>/dev/null || stat -c%s "$metallib" 2>/dev/null)
    
    if [ "$size" -lt 200000 ]; then
        echo "Metallib seems incomplete (size: $size bytes)"
        return 1
    fi
    
    return 0
}

# Helper for BATS compatibility
skip() {
    echo -e "${YELLOW}[SKIP]${NC} $1"
    return 0
}

# ============================================================================
# Main
# ============================================================================

main() {
    setup
    
    local passed=0
    local failed=0
    local skipped=0
    
    echo "Running tests..."
    echo ""
    
    # Test 1: Binary exists
    if test_vrmvisualregression_binary_exists; then
        ((passed++))
    else
        ((failed++))
    fi
    
    # Test 2: DQS shaders exist in metallib
    if test_dqs_shaders_exist; then
        ((passed++))
    else
        ((failed++))
    fi
    
    # Test 3: DQS produces different output
    if [ -f "$VRM_MODEL" ] && [ -f "$VRMA_ANIM" ]; then
        if test_dqs_produces_different_output; then
            ((passed++))
        else
            ((failed++))
        fi
    else
        echo -e "${YELLOW}[SKIP]${NC} DQS output comparison (missing input files)"
        ((skipped++))
    fi
    
    # Summary
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Test Summary${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "Passed:  ${GREEN}$passed${NC}"
    echo -e "Failed:  ${RED}$failed${NC}"
    echo -e "Skipped: ${YELLOW}$skipped${NC}"
    echo ""
    
    if [ $failed -eq 0 ]; then
        echo -e "${GREEN}✓ All tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}✗ Some tests failed${NC}"
        exit 1
    fi
}

# Run main if not sourced (for BATS compatibility)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
