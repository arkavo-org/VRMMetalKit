#!/bin/bash
#
# Visual Regression Test Suite for VRMMetalKit
#
# This script runs visual regression tests to detect rendering regressions
# It compares rendered output against reference videos
#
# Usage:
#   ./scripts/run-visual-regression-tests.sh [options]
#
# Options:
#   --generate-refs      Generate reference videos instead of comparing
#   --test-dqs           Test DQS implementation (LBS vs DQS comparison)
#   --vrm <path>         Path to VRM model (default: ./AliciaSolid.vrm)
#   --vrma <path>        Path to VRMA animation (default: ./VRMA_01.vrma)
#   --refs-dir <dir>     Directory for reference videos (default: ./test-refs)
#   --output-dir <dir>   Directory for test outputs (default: ./test-output)
#   --help               Show this help message
#
# Exit codes:
#   0   All tests passed
#   1   One or more tests failed
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default paths
VRM_PATH="${VRM_PATH:-./AliciaSolid.vrm}"
VRMA_PATH="${VRMA_PATH:-./VRMA_01.vrma}"
REFS_DIR="${REFS_DIR:-./test-refs}"
OUTPUT_DIR="${OUTPUT_DIR:-./test-output}"
GENERATE_REFS=false
TEST_DQS=false
VERBOSE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --generate-refs)
            GENERATE_REFS=true
            shift
            ;;
        --test-dqs)
            TEST_DQS=true
            shift
            ;;
        --vrm)
            VRM_PATH="$2"
            shift 2
            ;;
        --vrma)
            VRMA_PATH="$2"
            shift 2
            ;;
        --refs-dir)
            REFS_DIR="$2"
            shift 2
            ;;
            --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --help)
            head -n 25 "$0" | tail -n 24 | sed 's/^# //'
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Create directories
mkdir -p "$REFS_DIR"
mkdir -p "$OUTPUT_DIR"

# Check if swift is available
if ! command -v swift &> /dev/null; then
    echo -e "${RED}Error: Swift not found in PATH${NC}"
    exit 1
fi

# Check if VRMVisualRegression is built
echo -e "${BLUE}Building VRMVisualRegression...${NC}"
swift build --target VRMVisualRegression -q

# Helper function to print section headers
print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
}

# Helper function to run a test
run_test() {
    local test_name="$1"
    local command="$2"
    
    echo ""
    echo -e "${YELLOW}▶ Running: $test_name${NC}"
    
    if [ "$VERBOSE" = true ]; then
        if eval "$command"; then
            echo -e "${GREEN}✓ PASSED: $test_name${NC}"
            return 0
        else
            echo -e "${RED}✗ FAILED: $test_name${NC}"
            return 1
        fi
    else
        if eval "$command" > /dev/null 2>&1; then
            echo -e "${GREEN}✓ PASSED: $test_name${NC}"
            return 0
        else
            echo -e "${RED}✗ FAILED: $test_name${NC}"
            return 1
        fi
    fi
}

# Track test results
TESTS_PASSED=0
TESTS_FAILED=0

# ============================================================================
# Main Test Suite
# ============================================================================

print_header "VRMMetalKit Visual Regression Test Suite"

echo "Configuration:"
echo "  VRM:        $VRM_PATH"
echo "  VRMA:       $VRMA_PATH"
echo "  Refs dir:   $REFS_DIR"
echo "  Output dir: $OUTPUT_DIR"
echo "  Mode:       $(if [ "$GENERATE_REFS" = true ]; then echo "GENERATE"; else echo "COMPARE"; fi)"

# Check if input files exist
if [ ! -f "$VRM_PATH" ]; then
    echo -e "${YELLOW}⚠ Warning: VRM file not found: $VRM_PATH${NC}"
    echo "Tests requiring VRM model will be skipped."
fi

if [ ! -f "$VRMA_PATH" ]; then
    echo -e "${YELLOW}⚠ Warning: VRMA file not found: $VRMA_PATH${NC}"
    echo "Tests requiring animation will be skipped."
fi

# ============================================================================
# Test 1: DQS Implementation Test
# ============================================================================
if [ "$TEST_DQS" = true ] && [ -f "$VRM_PATH" ] && [ -f "$VRMA_PATH" ]; then
    print_header "Test 1: DQS Implementation Verification"
    echo "This test verifies that DQS produces different output than LBS"
    echo ""
    
    if run_test "LBS vs DQS Comparison" "swift run VRMVisualRegression compare-lbs-dqs \"$VRM_PATH\" \"$VRMA_PATH\" -d 1.0 -f 30 -w 640 -h 360"; then
        ((TESTS_PASSED++))
    else
        ((TESTS_FAILED++))
    fi
fi

# ============================================================================
# Test 2: Reference Generation or Comparison
# ============================================================================
if [ -f "$VRM_PATH" ] && [ -f "$VRMA_PATH" ]; then
    if [ "$GENERATE_REFS" = true ]; then
        print_header "Test 2: Generating Reference Videos"
        
        # Generate LBS reference
        REF_LBS="$REFS_DIR/reference_lbs.mov"
        echo "Generating LBS reference..."
        if swift run VRMVisualRegression generate "$VRM_PATH" "$VRMA_PATH" "$REF_LBS" -d 2.0 -f 30 -w 640 -h 360; then
            echo -e "${GREEN}✓ Generated: $REF_LBS${NC}"
            ((TESTS_PASSED++))
        else
            echo -e "${RED}✗ Failed to generate LBS reference${NC}"
            ((TESTS_FAILED++))
        fi
        
        # Generate DQS reference
        REF_DQS="$REFS_DIR/reference_dqs.mov"
        echo ""
        echo "Generating DQS reference..."
        if swift run VRMVideoRenderer "$VRM_PATH" "$VRMA_PATH" "$REF_DQS" -d 2.0 -f 30 -w 640 -h 360 --dqs; then
            echo -e "${GREEN}✓ Generated: $REF_DQS${NC}"
            ((TESTS_PASSED++))
        else
            echo -e "${RED}✗ Failed to generate DQS reference${NC}"
            ((TESTS_FAILED++))
        fi
    else
        print_header "Test 2: Regression Testing Against References"
        
        # Check if reference videos exist
        if [ -f "$REFS_DIR/reference_lbs.mov" ]; then
            TEST_OUTPUT="$OUTPUT_DIR/test_lbs.mov"
            
            # Generate test render
            echo "Rendering test video with LBS..."
            swift run VRMVideoRenderer "$VRM_PATH" "$VRMA_PATH" "$TEST_OUTPUT" -d 2.0 -f 30 -w 640 -h 360
            
            # Compare
            if run_test "LBS Regression Check" "swift run VRMVisualRegression compare \"$REFS_DIR/reference_lbs.mov\" \"$TEST_OUTPUT\" -t 0.02 --max-frames 60"; then
                ((TESTS_PASSED++))
            else
                ((TESTS_FAILED++))
            fi
        else
            echo -e "${YELLOW}⚠ Reference video not found: $REFS_DIR/reference_lbs.mov${NC}"
            echo "Run with --generate-refs to create reference videos"
        fi
    fi
fi

# ============================================================================
# Test Summary
# ============================================================================
print_header "Test Summary"

echo -e "Tests Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests Failed: ${RED}$TESTS_FAILED${NC}"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}✗ Some tests failed${NC}"
    exit 1
fi
