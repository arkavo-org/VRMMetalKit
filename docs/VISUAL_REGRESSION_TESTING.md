# Visual Regression Testing

This document describes the visual regression testing framework for VRMMetalKit.

## Overview

Visual regression testing compares rendered output against reference images/videos to detect:
- Rendering regressions (broken shaders, incorrect colors)
- Skinning algorithm differences (LBS vs DQS)
- Pipeline configuration issues
- Missing or corrupted shader functions

## Components

### 1. VRMVisualRegression Tool

A Swift-based CLI tool for comparing rendered videos:

```bash
# Compare two video files
swift run VRMVisualRegression compare reference.mov test.mov

# Compare LBS vs DQS output (verifies DQS is working)
swift run VRMVisualRegression compare-lbs-dqs model.vrm anim.vrma

# Generate reference video
swift run VRMVisualRegression generate model.vrm anim.vrma output.mov
```

### 2. Shell Scripts

#### `scripts/run-visual-regression-tests.sh`

Main test runner with multiple test modes:

```bash
# Run all tests including DQS verification
./scripts/run-visual-regression-tests.sh --test-dqs

# Generate reference videos
./scripts/run-visual-regression-tests.sh --generate-refs

# Custom paths
./scripts/run-visual-regression-tests.sh --vrm ./MyModel.vrm --vrma ./MyAnim.vrma
```

#### `scripts/test-dqs-regression.sh`

BATS-compatible test for DQS implementation:

```bash
# Run DQS tests
./scripts/test-dqs-regression.sh

# Verbose mode
./scripts/test-dqs-regression.sh --verbose
```

#### `scripts/ci-regression-tests.sh`

CI-optimized test runner:

```bash
# Run in CI mode (minimal output)
./scripts/ci-regression-tests.sh

# With custom model
VRM_MODEL=./model.vrm VRMA_ANIM=./anim.vrma ./scripts/ci-regression-tests.sh
```

### 3. Makefile Targets

```bash
# Run DQS unit tests
make dqs-test

# Run visual regression tests
make visual-test

# Generate reference videos
make visual-regression

# Run DQS comparison
make dqs-compare

# Run CI tests
make ci-test
```

## DQS Testing

### Why Test DQS?

Dual Quaternion Skinning (DQS) should produce visibly different output than Linear Blend Skinning (LBS) because:
- DQS preserves volume during joint rotation
- LBS causes "candy wrapper" artifact at high rotation angles
- Different shader functions are used (verify they're compiled)

### The `compare-lbs-dqs` Command

This is the key test for DQS implementation:

```bash
swift run VRMVisualRegression compare-lbs-dqs model.vrm anim.vrma
```

**Expected Output:**
- The test renders the same animation with both LBS and DQS
- Compares the output frame by frame
- **Passes** if there are significant differences (DQS is working)
- **Fails** if outputs are identical (DQS not being applied)

**Example Output:**
```
📊 Visual Regression Results
═════════════════════════════════════════════════════
Frames compared:    60
Matching frames:    5 (8.3%)
Different frames:   55 (91.7%)

Difference Metrics:
  Max difference:   0.1847
  Average diff:     0.0234
  Worst frame:      #23
  PSNR:             28.45 dB

Result: ✅ PASSED
```

## Comparison Metrics

### Perceptual Difference

The comparison uses weighted RGB differences:
- Red: 29.9% weight
- Green: 58.7% weight  
- Blue: 11.4% weight

This matches human perception where green differences are most noticeable.

### PSNR (Peak Signal-to-Noise Ratio)

- **> 40 dB**: Images are nearly identical
- **30-40 dB**: Good quality, minor differences
- **20-30 dB**: Noticeable differences
- **< 20 dB**: Significant differences

### Thresholds

| Test Type | Threshold | Description |
|-----------|-----------|-------------|
| Standard | 0.02 (2%) | Normal regression testing |
| LBS vs DQS | 0.05 (5%) | Expecting visible differences |

## CI/CD Integration

### GitHub Actions Example

```yaml
name: Visual Regression Tests

on: [push, pull_request]

jobs:
  visual-test:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Build
        run: make build
      
      - name: Compile Shaders
        run: make shaders
      
      - name: Run Visual Tests
        run: make ci-test
        env:
          VRM_MODEL: ./test-data/model.vrm
          VRMA_ANIM: ./test-data/anim.vrma
```

### Interpreting Results

**Exit Codes:**
- `0`: All tests passed
- `1`: One or more tests failed

**Failed Tests Indicate:**
- DQS shader not compiled into metallib
- Sanity check causing fallback to LBS
- Buffer binding issues
- Shader compilation errors

## Troubleshooting

### "Metallib too small"

The metallib should be ~250KB+. If smaller:
```bash
make shaders  # Recompile all shaders
```

### "DQS output identical to LBS"

Check:
1. DQS shader functions exist: `swift test --filter testDQSShaderFunctionsExist`
2. Sanity check not triggered (extreme position check removed)
3. DQ buffer properly bound in renderer

### "Reference video not found"

Generate references first:
```bash
make visual-regression
```

## Advanced Usage

### Custom Comparison Threshold

```bash
swift run VRMVisualRegression compare ref.mov test.mov -t 0.05
```

### Limit Frame Count

```bash
swift run VRMVisualRegression compare ref.mov test.mov --max-frames 30
```

### Generate Low-Resolution Reference

```bash
swift run VRMVisualRegression generate model.vrm anim.vrma ref.mov -w 320 -h 180 -d 1.0
```

## File Structure

```
scripts/
├── run-visual-regression-tests.sh    # Main test runner
├── test-dqs-regression.sh            # DQS-specific tests
└── ci-regression-tests.sh            # CI-optimized runner

Sources/VRMVisualRegression/
└── main.swift                         # Comparison tool

test-refs/                             # Reference videos (git-ignored)
├── reference_lbs.mov
└── reference_dqs.mov

test-output/                           # Test outputs (git-ignored)
└── test_*.mov
```

## See Also

- [DQS Implementation Notes](./DQS_IMPLEMENTATION.md)
- [Testing Guide](./TESTING.md)
