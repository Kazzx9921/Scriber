import SwiftUI
import ScriberShared

/// 設定 → API key: every key in one place. The provider rows in Settings set keys inline too;
/// this page is for reviewing, testing and deleting them.
struct APIKeysView: View {
    @Environment(SettingsModel.self) private var settings

    private var builtInKinds: [APIKeyKind] { APIKeyKind.allCases.filter { $0 != .custom } }

    var body: some View {
        List {
            Section {
                ForEach(builtInKinds, id: \.self) { kind in
                    NavigationLink {
                        APIKeyDetailView(kind: kind)
                    } label: {
                        row(title: kind.vendor, usage: kind.usage, isSet: settings.hasKey(kind))
                    }
                }
                if settings.isCustomEngineConfigured || settings.hasKey(.custom) {
                    NavigationLink {
                        CustomEngineView()
                    } label: {
                        row(title: settings.customEngineName, usage: APIKeyKind.custom.usage,
                            isSet: settings.hasKey(.custom))
                    }
                }
            } header: {
                SectionTitle("API key", info: "Scriber 用你自己的 key 直接連到這些服務，費用由服務商向你收取。key 只存在這支手機的鑰匙圈裡。")
            }
        }
        .navigationTitle("API key")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(title: String, usage: String, isSet: Bool) -> some View {
        LabeledContent {
            StatusBadge(isOn: isSet)
        } label: {
            Text(title)
            Text(usage)
        }
    }
}
