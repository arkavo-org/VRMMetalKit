# VRM Platform License 1.0

This license applies to VRM model files (.vrm) and 3D avatar assets included in this repository.

## Overview

VRM models follow the **VRM Platform License 1.0** (VPL 1.0) as defined by the VRM Consortium.

## License Text

The VRM Platform License 1.0 is available at:
https://vrm.dev/en/licenses/1.0/

## Key Points

- **Attribution Required**: When redistributing VRM models, proper attribution to the original creator must be provided as specified in the model's metadata.
- **Commercial Use**: Depends on the specific license settings embedded in each VRM model file. Check the model's VRM metadata for permissions.
- **Modification**: Allowed with proper attribution and compliance with the original license terms.
- **Redistribution**: Permitted with attribution and adherence to the original license terms.

## Model-Specific Licensing

Each VRM model contains its own licensing information in the model file metadata:

- **Model Author**: Specified in the VRM metadata
- **Contact Information**: Included in the model metadata if provided
- **Usage Rights**: Defined per model (violent usage, sexual usage, commercial usage, etc.)
- **License Type**: May vary per model (Other, CC0, CC_BY, CC_BY_NC, CC_BY_SA, CC_BY_ND, CC_BY_NC_SA, CC_BY_NC_ND, Redistribution_Prohibited)

## Checking Model License

To check the license of a VRM model:

```swift
import VRMMetalKit

let model = try await VRMModel.load(from: modelURL, device: device)
if let meta = model.vrmExtension?.meta {
    print("License: \(meta.licenseURL ?? "Not specified")")
    print("Author: \(meta.authors?.first ?? "Unknown")")
    print("Commercial use: \(meta.commercialUsage ?? "Unknown")")
}
```

## Test Models

Test VRM models included in this repository are either:

1. **Created specifically for testing** - Licensed under CC0 (public domain)
2. **Downloaded from VRM Hub** - Follow the original creator's license
3. **Generated synthetically** - Created by the VRMBuilder system, CC0 licensed

For test models downloaded from external sources, please refer to the original source for licensing terms.

## More Information

- VRM Specification: https://github.com/vrm-c/vrm-specification
- VRM Hub: https://vrm.dev/
- VRM License Documentation: https://vrm.dev/en/licenses/

---

**Note**: This LICENSE-MODELS.md file applies only to VRM model files (.vrm) and 3D assets.
The source code of VRMMetalKit is licensed separately under Apache License 2.0 (see LICENSE file).
