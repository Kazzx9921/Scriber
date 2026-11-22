# App Store 截圖

產生 `docs/appstore/screenshots/` 裡的商店截圖。

| 檔案 | 用途 |
|---|---|
| `compose.py` | 把原始截圖排成商店圖：標題、副標、手機外框。改文字就改這支的 `SHOTS` |
| `capture-app.sh` | 重新截 App 的兩張畫面（04 首頁、05 設定） |

輸入是 `docs/appstore/raw/`（模擬器原始截圖，1320 × 2868），輸出：

- `docs/appstore/screenshots/zh-Hant/`：6.9 吋，1320 × 2868
- `docs/appstore/screenshots/zh-Hant-6.5/`：6.5 吋，1284 × 2778（重新排版，不是拉伸）
- `docs/appstore/screenshots/preview.jpg`：6.9 吋五張並排，檢查用

## 只改文字或版面

```sh
python3 scripts/appstore-screenshots/compose.py
```

需要 Pillow 和系統字體 PingFang TC（macOS 內建）。標題和副標在全組用同一個字級，放不下時整組一起縮小。

檢查尺寸、沒有透明、色彩是 sRGB：

```sh
sips -g pixelWidth -g pixelHeight -g hasAlpha -g profile docs/appstore/screenshots/zh-Hant*/*.png
```

## 重新截 App 畫面（04、05）

```sh
scripts/appstore-screenshots/capture-app.sh
python3 scripts/appstore-screenshots/compose.py
```

腳本會建立一台暫時的 iPhone 17 Pro Max 模擬器（iOS 27、繁中台灣、淺色、狀態列 9:41），在背景開機（不開 Simulator App），編譯 Debug 版，用這些參數啟動後截圖，最後刪掉模擬器：

```
-ScriberSkipOnboarding YES -ScriberDemo YES -ScriberDemoReady YES -ScriberTab home|settings
```

- `-ScriberDemo`：範例的試用結果、字典、歷史紀錄，首頁統計 86 次、12,340 字（`App/App/DemoData.swift`、`HomeView.currentStats`）。
- `-ScriberDemoReady`：只影響畫面。首頁不顯示「還差一步」，設定頁把 ElevenLabs 和 Groq 的 key 顯示成「已設定」。不會寫入 Keychain，也不會要求任何權限。

全程不錄音：不授予麥克風權限、不點任何東西。

## 重新截鍵盤畫面（01–03）

`simctl` 沒辦法在別的 App 裡叫出自訂鍵盤，所以這三張是用一個一次性的測試 App 截的（沒有放進 repo）。做法：

1. 用 XcodeGen 建一個 iOS App target，sources 包含 repo 的 `Keyboard/`（排除 `Info.plist`、`*.entitlements`、`PrivacyInfo.xcprivacy`），連結 `Packages/ScriberCore` 的 `ScriberShared` 和 `ScriberCore`。Info.plist **不要**放麥克風用途說明，萬一有東西碰到麥克風會直接當掉，而不是跳出權限視窗。
2. 畫面上半部是假的聊天畫面（SwiftUI），下面是輸入框，再下面是真的鍵盤：`KeyboardRootView(model:)`，高度 `KeyboardViewController.portraitHeight`（176 pt），底下加 78 pt 系統區（灰底和地球鍵，不畫系統的聽寫鍵）。`KeyboardModel(controller:)` 傳一個沒有載入 view 的 `KeyboardViewController()`，並自己保留它（model 只弱參照）。
3. 用 DEBUG 的 `model.debugShow(...)` 指定狀態，`showsGlobe: false`（Face ID iPhone 的鍵盤不畫自己的地球鍵）：
   - 01 錄音中：`model.levels.provider` 換成假的音量曲線，`debugShow(availability: .ready, activity: .recording(toggle: true), warm: true, showsGlobe: false)`
   - 02 結果：輸入框放整理後的文字，`debugShow(availability: .ready, activity: .idle, canUndo: true, warm: true, showsGlobe: false)`（剛插入文字時會出現復原鍵）
   - 03 翻譯語言：`debugShow(... .idle ...)` 之後，`model.debugModes(KeyboardModes.state(...))`（出廠的模式、沒有用過的紀錄；它也讓 model 當作有完整取用），再用 `model.modePicker.touchChanged(to:)` 按住模式鍵中心 0.4 秒、滑到「日文」那一格。這就是按鍵本身的手勢會呼叫的方法，彈出位置和高亮都是真的。2026-11-22 之前的截圖是舊的翻譯鍵（只有三個語言）；模式鍵的長按多了模式，要重截。
4. 用同樣的模擬器設定，啟動後等 8 秒（剛安裝完第一次啟動比較慢）再 `xcrun simctl io <udid> screenshot`，存成 `docs/appstore/raw/01-keyboard-recording.png`、`02-keyboard-result.png`、`03-keyboard-translate.png`。

## 內容

範例文字都是自己編的，沒有真實人名或品牌（技術名詞 API、demo 除外）。

第 2 張的「你說的 → 打進去的」來自真的處理流程：把下面這段逐字稿丟進 ScriberCore 的潤飾關閉流程（`RuleBasedCleanup.clean` → `ZhTW.toTraditionalTaiwan` → `preferCommonTai` → `normalize(spaceBetweenCJKAndLatin: true)` → `PunctuationStyler.apply(.dropFinalPeriod, limit: 20)`，也就是預設設定），得到的就是輸入框裡的文字。改了其中一邊，另一邊要重新跑一次。

```
嗯，簡報我來準備，呃，週四前會先放到共用資料夾。那個，如果 API 文件還沒更新，我我順便整理一下。
→ 簡報我來準備，週四前會先放到共用資料夾。如果 API 文件還沒更新，我順便整理一下。
```

第 4 張首頁的「我們明天的 demo，改到下午兩點，一樣在三樓會議室」也是同一個流程的實際輸出（`DemoData.trials`）。
