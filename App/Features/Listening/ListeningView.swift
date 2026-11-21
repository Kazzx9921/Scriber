import SwiftUI
import ScriberShared

/// Full-screen confirmation shown when the keyboard opens the app (scriber://session).
/// Seen many times a day: no entrance animation, one clear instruction, nothing to decide.
struct ListeningView: View {
    /// Shows a fake active session (DEBUG screenshots).
    var isDemo = false
    var onStay: () -> Void

    @Environment(DictationEngine.self) private var engine
    @Environment(SettingsModel.self) private var settings
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var startTimedOut = false
    @State private var demoExpiry = Date().addingTimeInterval(10 * 60)

    private enum Display {
        case starting
        case active(expiresAt: Date?)
        case needsMic(denied: Bool)
        case failed(String?)
    }

    private var isRecording: Bool { isDemo || engine.phase == .recording }

    /// What to do next. When auto-return is on, the user is usually already gone by the time
    /// this is read; the manual "◀︎" stays the fallback.
    private var instruction: String {
        switch engine.autoReturnStatus {
        case .returning(let name):
            return "正在帶你回到 \(name)，回去後繼續說。"
        case .failed(let name):
            return "沒辦法自動打開 \(name)。點左上角的「◀︎」回去繼續說。"
        case .idle:
            return isRecording
                ? "點左上角的「◀︎」回到剛才的 App 繼續說，說完在鍵盤點一下。"
                : "點左上角的「◀︎」回到剛才的 App，在鍵盤點麥克風說話。"
        }
    }

    /// Standby: the next dictations do not come here.
    private var standbyNote: String? {
        guard !isDemo, engine.effectiveStandbyMode != .off else { return nil }
        return "\(settings.standbyMinutes) 分鐘內再用，不會再跳到這裡。"
    }

    private var display: Display {
        if isDemo { return .active(expiresAt: demoExpiry) }
        switch engine.micPermission {
        case .denied: return .needsMic(denied: true)
        case .undetermined: return .needsMic(denied: false)
        case .granted: break
        }
        if engine.isSessionActive { return .active(expiresAt: engine.sessionExpiresAt) }
        return startTimedOut ? .failed(engine.lastErrorMessage) : .starting
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                center
                    .padding(.horizontal, 32)
                Spacer()
                bottom
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }

            if case .active = display {
                backHint
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 20)
                    .padding(.top, 6)
            }
        }
        .task {
            // Give the audio session a moment before calling it a failure.
            try? await Task.sleep(for: .seconds(2))
            startTimedOut = true
        }
        .onAppear { Haptics.success() }
    }

    // MARK: Pieces

    /// Points at the system "◀ App" back chip in the top-left corner.
    private var backHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.left")
                .font(.body.weight(.semibold))
            Text("點這裡回到剛才的 App")
                .font(.subheadline.weight(.medium))
        }
        .foregroundStyle(.tint)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var center: some View {
        switch display {
        case .active:
            VStack(spacing: 16) {
                badge(symbol: "waveform", tint: .accentColor, animate: !reduceMotion && isRecording)
                Text(isRecording ? "正在錄音" : "已準備好")
                    .font(.largeTitle.weight(.bold))
                Text(instruction)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                if let standbyNote {
                    Text(standbyNote)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                if let missing = settings.missingSTTKey {
                    Label("還沒設定 \(missing.vendor) 的 key，辨識會失敗", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }
            }
            .accessibilityElement(children: .combine)

        case .starting:
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text("正在準備…")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

        case .needsMic(let denied):
            VStack(spacing: 16) {
                badge(symbol: "mic.slash.fill", tint: .orange, animate: false)
                Text(denied ? "麥克風權限已關閉" : "需要麥克風權限")
                    .font(.title.weight(.bold))
                Text(denied
                     ? "到「設定」打開 Scriber 的麥克風。"
                     : "允許後，鍵盤才能聽你說話。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

        case .failed(let message):
            VStack(spacing: 16) {
                badge(symbol: "exclamationmark.triangle.fill", tint: .orange, animate: false)
                Text("沒辦法開始聆聽")
                    .font(.title.weight(.bold))
                Text(message ?? "請再試一次。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var bottom: some View {
        VStack(spacing: 12) {
            switch display {
            case .needsMic(let denied):
                Button {
                    if denied {
                        openURL(SystemSettings.appSettingsURL)
                    } else {
                        Task {
                            if await engine.requestMicPermission() { engine.startSession() }
                        }
                    }
                } label: {
                    FullWidthLabel(denied ? "打開設定" : "允許麥克風")
                }
                .primaryActionStyle()
            case .failed:
                Button {
                    startTimedOut = false
                    engine.startSession()
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        startTimedOut = true
                    }
                } label: {
                    FullWidthLabel("再試一次")
                }
                .primaryActionStyle()
            case .active, .starting:
                EmptyView()
            }

            Button("留在 Scriber", action: onStay)
                .font(.body)
                .padding(.vertical, 8)
        }
    }

    private func badge(symbol: String, tint: Color, animate: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 44, weight: .medium))
            .foregroundStyle(tint)
            .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating, isActive: animate)
            .frame(width: 104, height: 104)
            .background(Circle().fill(tint.opacity(0.12)))
    }
}
