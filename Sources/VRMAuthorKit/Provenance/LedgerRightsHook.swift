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

/// `recipe apply` rights hook backed by the project ledger and `RightsResolver`,
/// so a recipe cannot bypass attribution or conflict detection.
public struct LedgerRightsHook: RecipeRightsHook {
    public init() {}

    public func resolve(declaration: RightsDeclaration, recipe: Recipe, context: OperationContext) throws -> RecipeRightsResolution {
        var knownImageIds = Set<String>()
        var ledger = RightsLedger()
        if let projectPath = context.projectPath, let store = try? ProjectStore.open(at: projectPath) {
            ledger = (try? RightsLedger.load(store)) ?? RightsLedger()
            if let state = try? store.state() {
                knownImageIds = ProvenanceHandlers.knownImageIds(state: state, ledger: ledger)
            }
        }
        let resolver = RightsResolver(baseURL: context.cwd, knownImageIds: knownImageIds, ledger: ledger)
        let resolution = try resolver.resolve(declaration)
        return RecipeRightsResolution(meta: resolution.meta,
                                      attribution: try JSONValue.from(resolution.attributions),
                                      conflicts: resolution.conflicts.map(\.authorError))
    }
}
