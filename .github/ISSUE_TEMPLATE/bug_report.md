---
name: Bug Report
about: Report a bug or unexpected behavior
title: '[BUG] '
labels: bug
assignees: ''
---

## Bug Description

A clear and concise description of the bug.

## Steps to Reproduce

1. Go to '...'
2. Load VRM file '...'
3. Call method '...'
4. See error

## Expected Behavior

A clear description of what you expected to happen.

## Actual Behavior

What actually happened instead.

## Environment

- **Platform**: macOS / iOS
- **OS Version**: (e.g., macOS 14.5, iOS 17.4)
- **Xcode Version**: (e.g., 15.3)
- **Swift Version**: (e.g., 6.0)
- **VRMMetalKit Version**: (e.g., 0.1.0)
- **Device**: (for iOS: iPhone 15 Pro, etc.)

## VRM Model Details (if applicable)

- **Model Source**: (e.g., VRoid Hub, custom, etc.)
- **VRM Version**: (1.0 or 0.0)
- **File Size**: (approximate)
- **Model Complexity**: (triangle count, bone count if known)

## Code Sample

```swift
// Minimal code to reproduce the issue
let device = MTLCreateSystemDefaultDevice()!
let renderer = VRMRenderer(device: device)
// ... rest of code
```

## Error Messages / Logs

```
Paste any error messages or relevant log output here
```

## Screenshots (if applicable)

Add screenshots to help explain the problem.

## Additional Context

Any other context about the problem here.

## Possible Solution (optional)

If you have ideas on how to fix this, please share.
