import SwiftUI
import ScriberShared

/// The home hero: the time dictation has saved, said big, with the supporting numbers and
/// Scriber's own artwork on warm paper. Before the first dictation it invites the first one.
struct SavedTimeHero: View {
    let stats: HomeStats
    let active: ActiveHotkey
    let mode: TriggerMode

    private let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

    var body: some View {
        ZStack(alignment: .leading) {
            LinearGradient(colors: [Theme.heroTop, Theme.heroBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
            art
            Group {
                if stats.dictations == 0 { empty } else { filled }
            }
            .padding(.leading, 32)
            .padding(.vertical, 30)
            .padding(.trailing, 220)
        }
        .frame(maxWidth: .infinity, minHeight: 224, alignment: .leading)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.hairline))
    }

    /// Bottom-right, partly cut off by the card's edge.
    private var art: some View {
        MicDiscArt(size: 270)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .offset(x: 46, y: 52)
    }

    // MARK: Filled

    private var filled: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("用說的，你已經省下")
                InfoButton("跟用鍵盤打出同樣的字相比（以每分鐘 \(Int(UsageStats.typingCharactersPerMinute)) 字估算），再扣掉說話的時間。iPhone 和 Mac 分開計算。")
                    .font(.callout)
            }
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary.opacity(0.85))

            savedText
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 2)
                .accessibilityLabel("省下 \(DurationFormat.text(seconds: stats.secondsSaved))")

            HStack(alignment: .top, spacing: 30) {
                stat(stats.characters.formatted(), "說出的字")
                stat(stats.dictations.formatted(), "聽寫次數")
                if let speedup = stats.speedup {
                    stat("\(speedup.formatted(.number.precision(.fractionLength(speedup < 10 ? 1 : 0)))) 倍", "比打字快")
                }
            }
            .padding(.top, 18)
        }
    }

    /// "2 小時 14 分": big rounded terracotta numbers, smaller units.
    private var savedText: Text {
        let numberFont = Font.system(size: 54, weight: .bold, design: .rounded)
        let unitFont = Font.system(size: 24, weight: .semibold, design: .rounded)
        let parts = DurationFormat.parts(seconds: stats.secondsSaved)
        return parts.enumerated().reduce(Text(verbatim: "")) { text, item in
            let gap = item.offset == 0 ? "" : " "
            let number = Text(verbatim: item.element.value).font(numberFont).foregroundStyle(Theme.accentText)
            let unit = Text(verbatim: " \(item.element.unit)").font(unitFont).foregroundStyle(.primary.opacity(0.8))
            return Text("\(text)\(gap)\(number)\(unit)")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Empty

    private var empty: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("說第一句話試試看")
                .font(.system(size: 30, weight: .bold))
            HotkeyHint(active: active, mode: mode, large: true)
                .font(.body)
                .foregroundStyle(.primary.opacity(0.85))
            Text("省下的時間會記在這裡")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
    }
}
