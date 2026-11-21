import SwiftUI
import ScriberCore
import ScriberShared

/// The latest in-app dictation on Home: the text, which engines made it and how fast, copy and close.
struct TrialCard: View {
    let trial: Trial
    /// Set only for the latest failure when the engine kept the audio.
    var onRetry: (() -> Void)?
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch trial.outcome {
            case .success(let result):
                Text(result.finalText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                footer(stt: result.sttProvider, polish: result.polishProvider,
                       seconds: Format.seconds(millis: result.sttMillis + result.polishMillis)) {
                    CopyButton(text: result.finalText)
                }

            case .failure(let message, let stt, let polish):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                footer(stt: stt, polish: polish, seconds: nil) {
                    if let onRetry {
                        Button(action: onRetry) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.clockwise")
                                Text("重試")
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func footer<Action: View>(stt: STTProviderKind, polish: PolishProviderKind, seconds: String?,
                                      @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 14) {
            Text([stt.shortName, polish.shortName, seconds].compactMap { $0 }.joined(separator: "・"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            action()
                .font(.subheadline.weight(.medium))
                .buttonStyle(.borderless)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("關閉")
        }
    }
}
