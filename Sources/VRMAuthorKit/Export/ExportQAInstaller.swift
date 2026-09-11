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

/// Installs the export, QA and inspection handlers. The integrator replaces the
/// default hooks by calling `installer(rights:render:consumer:)` from
/// Registry+Installers.swift.
public enum ExportQAInstaller {
    public static let names = ExportHandlers.names + QAHandlers.names + InspectionHandlers.names

    public static let install: RegistryInstaller = installer()

    public static func installer(rights: any RecipeRightsHook = NoRightsHook(), render: any RenderAdapter = NoRenderer(),
                                 consumer: any ConsumerImporter = SelfReimportConsumer()) -> RegistryInstaller {
        let export = ExportHandlers(rights: rights)
        let qa = QAHandlers(render: render, consumer: consumer)
        return { registry in
            export.install(into: &registry)
            qa.install(into: &registry)
            InspectionHandlers.install(into: &registry)
        }
    }
}
