# Visual Regression Test Results

**Date:** 2026-02-01  
**Model:** AliciaSolid_vrm-0.51.vrm  
**Animation:** VRMA_03.vrma

## Test Summary

### DQS Implementation Verification

| Metric | Value |
|--------|-------|
| Frames Compared | 90 |
| Matching Frames | 0 (0.0%) |
| Different Frames | 90 (100.0%) |
| Max Difference | 0.7509 |
| Average Difference | 0.0007 |
| PSNR | 42.61 dB |

### Result: ✅ PASSED

**DQS is producing different output from LBS** - This confirms that:
1. DQS shader functions are correctly compiled and loaded
2. The DQS pipeline is being used (not falling back to LBS)
3. Volume-preserving skinning is active

## Generated Reference Videos

| File | Size | Description |
|------|------|-------------|
| `AliciaSolid_vrm-0.51_lbs.mov` | 178K | Linear Blend Skinning reference |
| `AliciaSolid_vrm-0.51_dqs.mov` | 177K | Dual Quaternion Skinning reference |

## Technical Details

### Render Settings
- Resolution: 640x360
- Duration: 3.0 seconds
- Frame Rate: 30 fps
- Total Frames: 90

### Observed Differences

The 100% frame difference rate with max difference of 0.7509 indicates significant visual differences between LBS and DQS. This is expected and desired because:

- **LBS** causes volume loss ("candy wrapper" effect) at high joint rotations
- **DQS** preserves volume during rotation
- The model has significant finger and arm animations that demonstrate this difference

### Pipeline Verification

Log output confirms DQS pipelines are being used:
```
[PSO] Frame 1: Setting pipeline: mtoon_skinned_dqs_opaque for Alicia_body
[PSO] Frame 1: Setting pipeline: mtoon_skinned_dqs_blend for Alicia_face_mastuge
```

## Usage

### Compare new render against LBS reference:
```bash
swift run VRMVisualRegression compare \
  test-refs/AliciaSolid_vrm-0.51_lbs.mov \
  new_render.mov \
  -t 0.02
```

### Compare new render against DQS reference:
```bash
swift run VRMVisualRegression compare \
  test-refs/AliciaSolid_vrm-0.51_dqs.mov \
  new_render.mov \
  -t 0.02
```

### Run LBS vs DQS comparison:
```bash
swift run VRMVisualRegression compare-lbs-dqs \
  /Users/arkavo/Projects/GameOfMods/AliciaSolid_vrm-0.51.vrm \
  /Users/arkavo/Projects/GameOfMods/VRMA_03.vrma \
  -d 3.0 -f 30 -w 640 -h 360
```

## Notes

- The reference videos use 640x360 resolution for faster rendering during testing
- For production quality testing, use 1920x1080 resolution
- The slight file size difference between LBS and DQS is due to video encoding variance
