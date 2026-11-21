import SwiftUI
import ScriberShared

/// Home's hero: how much time dictating has saved compared with typing on the phone, with the
/// character and dictation counts underneath. Before the first dictation it shows an illustration.
struct SavedTimeCard: View {
    let stats: UsageStats

    @ScaledMetric(relativeTo: .largeTitle) private var numberSize: CGFloat = 46

    var body: some View {
        Group {
            if stats.dictations == 0 {
                empty
            } else {
                filled
            }
        }
        .card(padding: 20)
    }

    // MARK: Filled

    private var filled: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 2) {
                    Label {
                        Text("省下的時間").foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "hourglass").foregroundStyle(.tint)
                    }
                    .font(.subheadline.weight(.semibold))
                    InfoButton("和用手機鍵盤打出同樣的字相比（以每分鐘 \(Int(UsageStats.typingCharactersPerMinute)) 字估算），再扣掉說話的時間。")
                        .font(.subheadline)
                }
                savedText
                    .contentTransition(.numericText())
                    .accessibilityLabel("省下 \(Format.duration(seconds: stats.secondsSaved))")
            }

            Divider()

            HStack(alignment: .top, spacing: 12) {
                stat(value: stats.characters.formatted(), label: "說出的字")
                stat(value: stats.dictations.formatted(), label: "聽寫次數")
            }
        }
    }

    /// "2 小時 14 分" with big rounded numbers and smaller units; wraps at large text sizes.
    private var savedText: Text {
        let numberFont = Font.system(size: min(numberSize, 84), weight: .bold, design: .rounded)
        let unitFont = Font.system(.title3, design: .rounded).weight(.semibold)
        let parts = Format.durationParts(seconds: stats.secondsSaved)
        return parts.enumerated().reduce(Text(verbatim: "")) { text, item in
            let gap = item.offset == 0 ? "" : " "
            let number = Text(verbatim: item.element.value).font(numberFont)
            let unit = Text(verbatim: " \(item.element.unit)").font(unitFont).foregroundStyle(.secondary)
            return Text("\(text)\(gap)\(number)\(unit)")
        }
    }

    private func stat(value: String, label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Empty

    private var empty: some View {
        VStack(spacing: 16) {
            SpotIllustration(symbol: "mic.fill", accent: "wave.3.right", size: 84)
            VStack(spacing: 4) {
                Text("省下的時間會記在這裡")
                    .font(.headline)
                Text("說第一句話試試看")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}
