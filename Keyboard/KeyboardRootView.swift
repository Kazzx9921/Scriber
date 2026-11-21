import SwiftUI
import ScriberShared

struct KeyboardRootView: View {
    let model: KeyboardModel

    var body: some View {
        content
            .environment(\.colorScheme, model.forcesDarkAppearance ? .dark : systemScheme)
    }

    @Environment(\.colorScheme) private var systemScheme

    private var compact: Bool { model.isLandscape }

    private var content: some View {
        VStack(spacing: compact ? 6 : 10) {
            Group {
                switch model.availability {
                case .needsFullAccess:
                    FullAccessPanel(compact: compact)
                default:
                    DictationPanel(model: model, compact: compact)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            BottomRow(model: model)
                .frame(height: compact ? 36 : 42)
        }
        .padding(.horizontal, 14)
        .padding(.top, compact ? 6 : 12)
        .padding(.bottom, compact ? 4 : 8)
        // The whole keyboard view: the translate key reports its frame and its gesture
        // location in this space, and the popup overlay is drawn in it.
        .coordinateSpace(.named(KeyboardSpace.name))
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { model.translatePicker.containerSize = proxy.size }
                    .onChange(of: proxy.size) { _, size in model.translatePicker.containerSize = size }
            }
        )
        .overlay { TranslatePopupOverlay(model: model) }
    }
}

// MARK: - Center: dictation
//
// Icons only; the same three slots in every state so nothing moves:
//   ( left )        (      mic pill      )        ( ⌫ )
// Left: 取消 while recording / processing; 關閉 while a failure waits for the user (retry or
// fix in Scriber); otherwise the 翻譯 key (empty when text is selected, because the mic then
// rewrites the selection). Messages never get a line of their own: they appear inside the mic
// pill (see `KeyboardFeedback`).

private struct DictationPanel: View {
    let model: KeyboardModel
    let compact: Bool

    var body: some View {
        HStack(spacing: 0) {
            leftAction.frame(maxWidth: .infinity, alignment: .leading)
            MicButton(model: model, size: compact ? CGSize(width: 150, height: 54) : CGSize(width: 172, height: 66))
            GlyphKey(symbol: "delete.backward", accessibility: "刪除",
                     onPress: model.deletePressBegan, onRelease: model.deletePressEnded)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxHeight: .infinity)
        .animation(.easeOut(duration: 0.18), value: model.activity)
    }

    private var isBusy: Bool {
        switch model.activity {
        case .recording, .processing: return true
        default: return false
        }
    }

    @ViewBuilder
    private var leftAction: some View {
        if isBusy {
            GlyphKey(symbol: "xmark", accessibility: "取消", onPress: {}, onRelease: model.cancel)
        } else if model.showsDismissKey {
            GlyphKey(symbol: "xmark", accessibility: "關閉訊息", onPress: {}, onRelease: model.dismissError)
        } else if model.hasSelection {
            Color.clear.frame(width: GlyphKey.side, height: GlyphKey.side)
        } else {
            TranslateKey(model: model)
        }
    }
}

// MARK: - Center: no full access
//
// The one place that needs a few lines of instruction. Same anatomy as the dictation row: a
// round icon key on the left, then a title, the Settings path, and one short reason.

private struct FullAccessPanel: View {
    let compact: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "lock.open")
                .font(.system(size: 17, weight: .medium))
                .frame(width: GlyphKey.side, height: GlyphKey.side)
                .background(Circle().fill(KeyPalette.key(scheme)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                Text("開啟「允許完整取用」")
                    .font(.system(size: compact ? 15 : 16, weight: .semibold))
                Text("設定 › 一般 › 鍵盤 › 鍵盤 › Scriber")
                    .font(.system(size: compact ? 12 : 13, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.8))
                Text("麥克風在 Scriber App 裡，鍵盤靠它傳話；不會記錄你打的字。")
                    .font(.system(size: compact ? 11 : 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .lineLimit(2)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Bottom row:  🌐  ↩︎(undo, only after an insert)   [   space   ]   ⏎

private struct BottomRow: View {
    let model: KeyboardModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if model.showsGlobe {
                    GlobeKey(controller: model.controller)
                } else {
                    Color.clear
                }
            }
            .frame(width: GlyphKey.side, height: GlyphKey.side)

            KeyCap(accessibility: "空格", onPress: model.insertSpace) {
                Image(systemName: "space").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
            }
            .clipShape(Capsule())

            if model.canUndo {
                GlyphKey(symbol: "arrow.uturn.backward", accessibility: "復原", onPress: {}, onRelease: model.undo)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            GlyphKey(symbol: returnSymbol, accessibility: model.returnKeyTitle, onPress: model.insertReturn)
        }
        .animation(.easeOut(duration: 0.18), value: model.canUndo)
    }

    /// Send-like fields get an arrow, everything else the return glyph.
    private var returnSymbol: String {
        switch model.returnKeyTitle {
        case "傳送", "前往", "搜尋", "完成", "加入", "下一步", "繼續": return "arrow.up"
        default: return "return"
        }
    }
}
