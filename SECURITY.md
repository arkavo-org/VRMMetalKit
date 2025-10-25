# Security Policy

## Supported Versions

We release patches for security vulnerabilities in the following versions:

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |

## Reporting a Vulnerability

We take security vulnerabilities seriously. If you discover a security vulnerability in VRMMetalKit, please follow these steps:

### Where to Report

**Do not** open a public GitHub issue for security vulnerabilities.

Instead, please report security issues privately to:
- **Email**: security@arkavo.org
- **Subject**: [SECURITY] VRMMetalKit - Brief Description

### What to Include

Please include the following information in your report:

1. **Description** of the vulnerability
2. **Steps to reproduce** the issue
3. **Potential impact** of the vulnerability
4. **Suggested fix** (if you have one)
5. **Your contact information** for follow-up

### Example Report

```
Subject: [SECURITY] VRMMetalKit - Buffer Overflow in VRM Parser

Description:
A buffer overflow vulnerability exists in the VRM parser when handling
malformed VRM files with oversized vertex buffers.

Steps to Reproduce:
1. Create a VRM file with vertex count exceeding buffer allocation
2. Load the file using VRMModel.load()
3. Observe crash or memory corruption

Potential Impact:
- Application crash
- Potential code execution with crafted VRM files
- Memory corruption

Suggested Fix:
Add bounds checking in BufferLoader.swift:123 before memcpy

Contact: researcher@example.com
```

## Response Timeline

- **Initial Response**: Within 48 hours
- **Status Update**: Within 7 days
- **Fix Timeline**: Depends on severity
  - **Critical**: Within 7 days
  - **High**: Within 30 days
  - **Medium**: Within 90 days
  - **Low**: Next regular release

## Disclosure Policy

We follow **responsible disclosure**:

1. **Report received**: We acknowledge receipt within 48 hours
2. **Investigation**: We validate and assess the vulnerability
3. **Fix development**: We develop and test a fix
4. **Coordinated disclosure**: We coordinate release timing with reporter
5. **Public disclosure**: We release the fix and publish security advisory

## Security Advisories

Security advisories will be published at:
- GitHub Security Advisories: https://github.com/arkavo-org/VRMMetalKit/security/advisories
- Project website (if applicable)

## Recognition

We appreciate security researchers who responsibly disclose vulnerabilities. With your permission, we will:

- Credit you in the security advisory
- List you in our Hall of Fame (SECURITY_HALL_OF_FAME.md)
- Provide a detailed timeline of the disclosure process

## Security Best Practices

### For Users

When using VRMMetalKit:

1. **Validate VRM files** from untrusted sources
2. **Use the latest version** to get security fixes
3. **Enable StrictMode** in development to catch issues early
4. **Sanitize user input** before passing to VRMMetalKit APIs
5. **Handle errors gracefully** - don't expose internal errors to end users

### For Contributors

When contributing code:

1. **Avoid unsafe operations** - prefer safe Swift constructs
2. **Validate all inputs** - especially buffer sizes and indices
3. **Check array bounds** before accessing
4. **Use assertions** for internal invariants
5. **Review Metal shader code** for buffer overruns
6. **Test with malformed files** - fuzz testing encouraged

## Known Security Considerations

### Buffer Handling

- VRMMetalKit handles binary data from VRM files
- Always validate buffer sizes before GPU uploads
- Use StrictMode to detect buffer size mismatches

### Shader Security

- Metal shaders access GPU memory directly
- Ensure vertex/index counts don't exceed buffer sizes
- Validate buffer bindings before draw calls

### File Parsing

- VRM files are glTF/GLB with JSON metadata
- JSON parsing uses Foundation's JSONDecoder (safe)
- Binary buffer access is validated with bounds checks

## Security Updates

Subscribe to security updates:

- **Watch** this repository on GitHub
- **Star** to show support and receive notifications
- **Follow** releases for security patches

## Contact

For security concerns:
- **Email**: security@arkavo.org
- **GPG Key**: Available upon request

For general questions:
- Open a GitHub issue (non-security related)
- Check CONTRIBUTING.md for contribution guidelines

---

**Remember**: If you think you've found a security vulnerability, please email security@arkavo.org instead of opening a public issue.
