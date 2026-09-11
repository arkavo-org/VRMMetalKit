//
// Copyright 2026 Arkavo
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

import Foundation

let usage = """
Usage: VRMAuthorRender --file AVATAR.vrm --scenario ID --out DIR
  Canonical scenario renders for `vrm-author qa run --suite authoring-v1`.
  Scenario rendering is not implemented in this build; `vrm-author doctor`
  reports this executable's presence, and `qa run` returns incomplete.

"""
FileHandle.standardError.write(Data(usage.utf8))
exit(3)
