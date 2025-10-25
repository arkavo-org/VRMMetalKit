# Contributing to VRMMetalKit

Thank you for your interest in contributing to VRMMetalKit! This document provides guidelines and instructions for contributing.

## Code of Conduct

This project adheres to a Code of Conduct. By participating, you are expected to uphold this code. Please read [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) before contributing.

## How Can I Contribute?

### Reporting Bugs

Before creating bug reports, please check existing issues to avoid duplicates. When creating a bug report, include:

- **Clear title and description**
- **Steps to reproduce** the issue
- **Expected behavior** vs actual behavior
- **VRM model details** (if applicable)
- **Environment**: macOS/iOS version, Xcode version, Swift version
- **Code samples** or screenshots if relevant

### Suggesting Enhancements

Enhancement suggestions are tracked as GitHub issues. When creating an enhancement suggestion:

- **Use a clear title** describing the enhancement
- **Provide detailed description** of the proposed functionality
- **Explain why** this enhancement would be useful
- **List alternatives** you've considered

### Pull Requests

1. **Fork the repository** and create your branch from `main`
2. **Follow the coding style** (see below)
3. **Add tests** for new functionality
4. **Update documentation** as needed
5. **Ensure all tests pass** (`swift test`)
6. **Add license headers** to new files
7. **Write clear commit messages**

## Development Setup

```bash
# Clone your fork
git clone https://github.com/YOUR_USERNAME/VRMMetalKit.git
cd VRMMetalKit

# Build the project
swift build

# Run tests
swift test

# Run specific tests
swift test --filter TestName
```

## Coding Style

### Swift Style Guide

- Follow [Swift API Design Guidelines](https://swift.org/documentation/api-design-guidelines/)
- Use **4 spaces** for indentation (no tabs)
- **Maximum line length**: 120 characters
- Use **descriptive variable names**
- Add **documentation comments** for public APIs

### Example

```swift
/// Loads a VRM model from the specified URL.
///
/// - Parameters:
///   - url: The file URL of the VRM model
///   - device: The Metal device for GPU resources
/// - Returns: The loaded VRM model
/// - Throws: `VRMError` if loading fails
public static func load(from url: URL, device: MTLDevice) async throws -> VRMModel {
    // Implementation
}
```

### Metal Shaders

- Use **4 spaces** for indentation
- Add **comments** explaining complex shader logic
- Follow **HLSL naming conventions** for shader functions
- Use **meaningful variable names**

## File Headers

All Swift and Metal files must include the Apache 2.0 license header:

```swift
//
// Copyright 2025 Arkavo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
```

## Testing

- **Write tests** for new features
- **Maintain or improve** code coverage
- Tests should be **fast and isolated**
- Use **descriptive test names**

```swift
func testVRMModelLoadingWithValidFile() throws {
    // Test implementation
}
```

## Documentation

- Update **README.md** for major changes
- Add **inline documentation** for public APIs
- Update **CHANGELOG.md** for all changes
- Include **code examples** for new features

## Commit Messages

Use clear, descriptive commit messages:

```
Add support for VRM 1.1 specification

- Implement new expression types
- Update parser for VRMC_vrm-1.1
- Add backward compatibility for VRM 1.0

Fixes #123
```

### Commit Message Format

- **First line**: Brief summary (50 chars or less)
- **Blank line**
- **Body**: Detailed explanation (wrap at 72 chars)
- **Footer**: Issue references

## Pull Request Process

1. **Update CHANGELOG.md** with your changes
2. **Ensure CI passes** (build, tests, checks)
3. **Request review** from maintainers
4. **Address feedback** promptly
5. **Squash commits** if requested
6. **Wait for approval** before merging

## Branch Naming

- `feature/description` - New features
- `fix/description` - Bug fixes
- `docs/description` - Documentation only
- `refactor/description` - Code refactoring
- `test/description` - Test additions/fixes

## Performance Considerations

VRMMetalKit is a performance-critical library. When contributing:

- **Profile your changes** using Instruments
- **Avoid allocations** in hot paths
- **Use Metal best practices** for GPU code
- **Consider memory usage** for large models
- **Test on real devices** (not just simulator)

## Questions?

- Open an issue with the `question` label
- Check existing issues and discussions
- Review the documentation in README.md

## License

By contributing to VRMMetalKit, you agree that your contributions will be licensed under the Apache License 2.0.

---

Thank you for contributing to VRMMetalKit! 🎉
