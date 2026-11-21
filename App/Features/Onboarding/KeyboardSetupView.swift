import SwiftUI

/// Copy for adding the keyboard, shared by onboarding and the settings/help page.
enum KeyboardSetupCopy {
    static var steps: [Text] { [
        Text("打開「設定」→「一般」→「鍵盤」"),
        Text("點「鍵盤」→「新增鍵盤⋯」，選「Scriber」"),
        Text("點剛加入的「Scriber」，打開「允許完整取用」"),
    ] }
    static var shortcut: LocalizedStringKey { "按「打開設定」會直接到 Scriber 的設定頁，點「鍵盤」就能打開。" }
    static var fullAccessBody: LocalizedStringKey { "「允許完整取用」讓鍵盤能和 Scriber App 溝通，才能錄音、拿回文字。你的聲音只會送到你選的辨識服務，不會傳給開發者。" }
}

/// Pushed from Home (setup checklist) and Settings.
struct KeyboardSetupView: View {
    @Environment(SetupStatus.self) private var setup
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                KeyboardDetectedRow(isAdded: setup.isKeyboardAdded)
            }

            Section {
                ForEach(Array(KeyboardSetupCopy.steps.enumerated()), id: \.offset) { index, step in
                    NumberedStep(number: index + 1, text: step)
                        .padding(.vertical, 2)
                }
            } header: {
                SectionTitle("步驟") {
                    InfoText(KeyboardSetupCopy.shortcut)
                    InfoText(KeyboardSetupCopy.fullAccessBody)
                }
            }

            Section {
                Button("打開設定") { openURL(SystemSettings.appSettingsURL) }
            }
        }
        .navigationTitle("加入鍵盤")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { setup.refresh() }
    }
}

struct KeyboardDetectedRow: View {
    let isAdded: Bool

    var body: some View {
        if isAdded {
            Label("已加入 Scriber 鍵盤", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Label("還沒加入 Scriber 鍵盤", systemImage: "keyboard")
                .foregroundStyle(.secondary)
        }
    }
}
