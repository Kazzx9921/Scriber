import SwiftUI

/// The mic pill. Tap to start listening, tap again to finish. Monochrome: it uses the label
/// color, so it is black on a light keyboard and white on a dark one.
///
/// It is also the keyboard's only message surface: failures and hints appear inside it as an
/// icon and a very short label (`KeyboardFeedback`), with a small shake for problems. Tapping it
/// then does what the message offers: retry, open Scriber to fix a setting, or simply dictate.
struct MicButton: View {
    let model: KeyboardModel
    var size: CGSize

    var body: some View {
        Button {
            model.pillTapped()
        } label: {
            ZStack {
                Capsule().fill(Color.primary)
                content
                    .transition(.opacity)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .modifier(ShakeEffect(shakes: CGFloat(model.shakeCount)))
        .animation(.linear(duration: 0.4), value: model.shakeCount)
        .disabled(model.activity == .processing)
        .animation(.easeOut(duration: 0.18), value: model.activity)
        .animation(.easeOut(duration: 0.18), value: model.feedback)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }

    @ViewBuilder
    private var content: some View {
        if model.isOpeningApp || model.isStartingCapture {
            ProgressView().tint(Color(.systemBackground))
        } else {
            activityContent
        }
    }

    @ViewBuilder
    private var activityContent: some View {
        switch model.activity {
        case .recording:
            HStack(spacing: 10) {
                Circle().fill(.red).frame(width: 9, height: 9)
                WaveformView(history: model.levels, color: Color(.systemBackground))
                    .frame(height: size.height * 0.5)
            }
            .padding(.horizontal, 20)
        case .processing:
            ProgressView().tint(Color(.systemBackground))
        default:
            if let feedback = model.feedback {
                FeedbackLabel(feedback: feedback, height: size.height, opensApp: feedback.kind == .needsSetup)
                    .id(feedback) // cross-fade between messages
            } else {
                Image(systemName: idleSymbol)
                    .font(.system(size: size.height * 0.42, weight: .semibold))
                    .foregroundStyle(Color(.systemBackground))
            }
        }
    }

    /// Solid when a tap records right here (warm app or in-keyboard capture), outlined when a
    /// tap will open Scriber first.
    private var idleSymbol: String {
        if model.rewritesSelection { return "wand.and.stars" }
        return model.isWarm ? "mic.fill" : "mic"
    }

    private var accessibilityLabel: String {
        switch model.activity {
        case .recording: return "完成"
        case .processing: return "整理中"
        default:
            if let feedback = model.feedback { return feedback.spoken }
            return model.micAccessibilityLabel
        }
    }

    private var accessibilityHint: String {
        switch model.activity {
        case .recording, .processing: return ""
        default:
            switch model.feedback?.kind {
            case .retry: return "點兩下重試"
            case .needsSetup: return "點兩下打開 Scriber"
            default: return model.isWarm ? "" : "會先打開 Scriber App"
            }
        }
    }
}

/// Icon + short label inside the pill. Problems get an orange icon; "needs setup" adds a small
/// arrow meaning "opens Scriber".
private struct FeedbackLabel: View {
    let feedback: KeyboardFeedback
    let height: CGFloat
    let opensApp: Bool

    var body: some View {
        let fontSize: CGFloat = height >= 60 ? 15 : 13
        HStack(spacing: 6) {
            Image(systemName: feedback.symbol)
                .font(.system(size: fontSize + 1, weight: .semibold))
                .foregroundStyle(feedback.isProblem ? Color.orange : Color(.systemBackground))
            Text(feedback.label)
                .font(.system(size: fontSize, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if opensApp {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: fontSize - 3, weight: .bold))
                    .opacity(0.7)
            }
        }
        .foregroundStyle(Color(.systemBackground))
        .padding(.horizontal, 14)
    }
}

/// One quick horizontal shake per increment of `shakes` (two oscillations, back to rest).
struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat
    var travel: CGFloat = 5

    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(shakes * .pi * 4), y: 0))
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
