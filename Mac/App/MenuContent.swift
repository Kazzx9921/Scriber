import AppKit
import SwiftUI
import ScriberShared

/// The menu bar menu, limited to what is used every day: status, start/finish (cancel and retry
/// only when they apply), copy the last result, recent results, translate on/off and its
/// language, open Scriber, quit. Engines and everything else live in the main window.
struct MenuContent: View {
    @Environment(DictationController.self) private var controller
    @Environment(MacSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Text(controller.presentedStatusLine)
        Divider()

        Button(primaryTitle) { controller.toggleFromMenu() }
            .disabled(controller.phase == .processing)
        if controller.phase != .idle {
            Button("取消") { controller.cancelFromMenu() }
        }
        if controller.canRetry, controller.phase == .idle {
            Button("重試上一段") { controller.retry() }
        }
        Button("複製上一段") { controller.copyLast() }
            .disabled(controller.lastText == nil)
        if !controller.recent.isEmpty {
            Menu("最近") {
                ForEach(controller.recent) { item in
                    Button(Self.preview(item.text)) { controller.copy(item.text) }
                }
            }
        }

        Divider()
        // Needs a Groq or Anthropic key; 設定 explains why it is greyed out.
        Toggle("翻譯", isOn: $settings.translateLocked)
            .disabled(!settings.hasLLMKey && !settings.translateLocked)
        Menu("翻譯成：\(settings.translateLanguage.displayName)") {
            Picker("翻譯成", selection: $settings.translateLanguageID) {
                ForEach(quickLanguages) { language in
                    Text(language.displayName).tag(language.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }

        Divider()
        if !controller.accessibilityTrusted {
            Button("開啟自動貼上…") { WindowManager.shared.showAutoPaste() }
        }
        Button("打開 Scriber…") { WindowManager.shared.showMain() }
            .keyboardShortcut(",")
        Button("結束 Scriber") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var primaryTitle: String {
        switch controller.phase {
        case .idle: "開始聽寫"
        case .recording: "結束"
        case .processing: "整理中…"
        }
    }

    /// The three quick languages, plus the current one if it is not among them.
    private var quickLanguages: [TranslateLanguage] {
        var ids = settings.translateQuickLanguageIDs
        if !ids.contains(settings.translateLanguageID) { ids.append(settings.translateLanguageID) }
        return ids.map(TranslateLanguage.find)
    }

    /// One line, about 28 characters.
    static func preview(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > 28 ? String(flat.prefix(28)) + "…" : flat
    }
}
