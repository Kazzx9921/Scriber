# 背景錄音與 App 切換：做法整理

> 日期：2026-11-22　狀態：研究完成，程式已寫好，**實機驗證中**
> 這份文件整理「怎麼讓鍵盤點了就能講、少跳 App、少亮橘燈」找到的所有做法，包含來源、證據強度、風險，以及我們目前的實作狀態。

---

## 1. 問題

iOS 有兩個限制，所有聽寫鍵盤都要面對：

1. **鍵盤（App Extension）不能用麥克風。** 只有主 App 可以。
2. **App 不能在背景「開始」錄音。** 只有已經在錄的 App 可以繼續錄。App 退到背景幾秒後會被系統凍結，凍結後收不到鍵盤的訊號。

所以最基本的做法是：鍵盤點麥克風 → 跳到主 App 開始錄 → 使用者回到原本的 App → 講完 → 文字打進去。每講一次都要跳一次，很煩。

要改善，有四個方向：

| 方向 | 目標 |
|---|---|
| **背景待命** | 讓主 App 在背景活著，之後點麥克風不用跳 |
| **鍵盤內錄音** | 讓鍵盤自己錄，完全不需要主 App |
| **自動跳回** | 還是要跳，但自動送回原本的 App |
| **背景喚醒** | 用系統的 App Intent 把主 App 在背景叫起來錄 |

---

## 2. 結論總表

| 代號 | 做法 | 公開 API | 別人的實機證據 | 我們的狀態 | 退件風險 |
|---|---|---|---|---|---|
| **B** | 靜音待命：麥克風引擎不關，閒置時把輸入靜音 | ✅ | Dictus：背景啟動 10/10，閒置無橘燈 | ✅ 寫完，**預設**，待實測 | 低 |
| **A** | 輸出待命：閒置時完全關麥克風，用無聲輸出保活 | ✅ | Dictus：背景重開麥克風**失敗** | ✅ 寫完，可切換，預期會被拒絕 | 中（無聲播放） |
| — | 講完即關：每次都跳 App | ✅ | 一定可行 | ✅ 寫完，可切換 | 無 |
| **C** | 鍵盤內錄音：隱藏的網頁元件要麥克風 | ⚠️ 繞過限制 | Hex：iPhone 17 Pro、iOS 27.2 成功 | ✅ 寫完，預設關，待實測 | 高（2.5.1） |
| **D1** | 自動跳回「事先選好的 App」 | ✅ | Dictus：跳回網址可行 | ✅ 寫完，預設不跳 | 低 |
| **D2** | 自動偵測所在 App 再跳回 | ❌ 非公開 | Dictus：iOS 26.6 實機 9/12 | ❌ 沒做 | 高 |
| **E** | App Intent 背景喚醒錄音 | ✅ | 兩個專案在動作按鈕上成功；**沒有人從鍵盤觸發成功** | ❌ 沒做 | 低 |

**目前的測試順序：B → C →（都不行才考慮）D2 或 E。**

---

## 3. Typeless 實際怎麼做

### 3.1 官方說明寫的（確定）
- 大部分時候點麥克風就直接講，不用切 App。
- 需要切 App 時，是「短暫切到 Typeless App 取得麥克風」。
- 麥克風圖示：**實心** = 不用切，直接講；**空心** = 會短暫切換。
- 閒置時麥克風是關的。
- 沒寫返回是自動還是手動。

### 3.2 別人抓到的手機 log（一支手機、一次紀錄，iOS 27.0.1）
- **閒置**：App 在背景活著，音訊類別是「播放影片」（MediaPlayback / MoviePlayback），音訊工作階段沒有啟用，沒有輸入，所以沒有橘燈。
- **點麥克風**：把類別切成「播放加錄音」（DefaultToSpeaker、MixWithOthers），啟用約 85 毫秒，約 0.3 秒後開始收音。全程沒有跳到前景，系統沒有拒絕。
- **點結束**：停止輸入、停用，約 180 毫秒後切回播放類別。橘燈立刻熄。
- **同一個程序全程存活**，沒有重新啟動。

### 3.3 推測（沒證實）
- 它怎麼在沒開麥克風、工作階段也沒啟用的情況下不被凍結：log 裡系統把它標為「前景焦點」，研究者推測是隱藏的子母畫面或影片播放。**沒有證實。**
- 自動跳回：App Store 有一則評論說「連滑都不用滑，會自動切回去」。只有這一則。
- 副作用：有使用者抱怨它一直在背景，會讓手機不自動鎖定，要強制關閉才恢復。

---

## 4. 各做法細節

### 4.1 B：靜音待命（目前預設）

**做法**
- 講完後，錄音引擎和「播放加錄音」工作階段都保持運作，立刻用 `AVAudioApplication.shared.setInputMuted(true)`（iOS 17+）把輸入靜音。
- 鍵盤送「開始」時只做取消靜音。取消失敗就讓這次請求失敗，不會錄到一段靜音。
- 心跳持續，鍵盤知道可以直接送指令。
- 待命時間到（1／5／10／30 分鐘）就整個結束。

**證據**
- Dictus 合併的 PR #799（分支名就叫 mute-input-when-idle）回報：一支 iPhone 上背景啟動 10/10，按下到第一個取樣 47–113 毫秒，閒置時沒有橘燈。這是他們 PR 描述裡的數字，不是原始 log。

**不確定的**
- 在 Kazen 的手機上橘燈會不會熄。
- 靜音期間預錄緩衝是空的，第一個字會不會被切，取決於取消靜音多快生效。

**怎麼判斷成功**（診斷紀錄）
- `mute true ok …` → `standby idle … posture=muted`
- `cmd start … app=background posture=muted idleFor=…s` → `recording id=… inputReadyMs=…`
- 失敗：`input start failed domain=… code=…`

### 4.2 A：輸出待命

**做法**
- 講完後停掉輸入，切成 `.playback` 加 `.mixWithOthers`，啟動一個只輸出無聲的引擎讓 App 不被凍結。不發布「正在播放」資訊，不會打斷或壓低音樂。
- 鍵盤送「開始」時切回「播放加錄音」、啟用、啟動輸入、停掉無聲輸出。
- 如果 iOS 拒絕：記下錯誤碼，結束待命，這次請求失敗並提示再點一次（下一次會開 App）。之後在同一個 iOS 版本上自動當成「講完即關」，設定裡會顯示警告和「再試一次」。
- 診斷紀錄畫面有一個開發者選項：待命時留在「播放加錄音」不切類別（Dictus 的分離引擎版本）。

**證據**
- Dictus 試過「停輸入、用輸出保活」，有沒有切類別都一樣：背景重開麥克風失敗（`kAUStartIO 'what'`）。
- Typeless 的 log 顯示它做得到，但它保活的方式不是無聲輸出，機制未知。

**預期**：會被拒絕。留著是為了在 Kazen 的手機上確認。

**風險**：只為了保活而播放無聲音訊，Dictus 作者認為是 App Store 規範 2.5.4 會退件的典型情況。這是他的判斷。

### 4.3 C：鍵盤內錄音

**做法**
- 鍵盤裡放一個 2×2 點的隱藏 `WKWebView`，用 `https://keyboard.scriber.invalid/` 當基底網址載入一段內嵌 HTML。這樣才算安全來源，`getUserMedia` 才能用，而且不會真的連網。
- 網頁呼叫 `navigator.mediaDevices.getUserMedia({audio:true})`，`WKUIDelegate` 同意麥克風權限。WebKit 的媒體程序是用主 App 的麥克風權限在錄。
- 網頁用 ScriptProcessor 把 16-bit 音訊分段傳給 Swift，Swift 重新取樣成 16 kHz 存成 WAV。
- **辨識也在鍵盤裡跑**：鍵盤連結 ScriberCore，API key 搬到 App 和鍵盤共用的 Keychain 群組（有自動搬移）。
- 使用條件：開關打開、iOS 26+、完整取用、麥克風權限已允許、記憶體餘裕至少 40 MB、共用 Keychain 裡有辨識用的 key。
- **失敗自動退回**：網頁 4 秒內沒就緒、`getUserMedia` 2.5 秒內沒開始、麥克風開始後 1.5 秒內沒有取樣，同一次點擊就改走主 App。硬性錯誤冷卻 30 分鐘，逾時要連續兩次才冷卻 5 分鐘。
- 網頁元件只在錄音期間存在，閒置時沒有任何東西在跑。

**證據**
- **Hex**（開源，MIT）：唯一的實機確認。iPhone 17 Pro、iOS 27.2，主 App 完全關閉，文字成功打進 Mail 和備忘錄，記憶體約 58 MB。
- AI-Notepad PR #503：照 Hex 移植，自己寫明「還沒在實機確認」。
- KeyboardKit 部落格：說「可以確認這個做法很好用」，沒寫裝置和版本，並警告 Apple 可能關掉這個漏洞或退件。
- Raycast iOS 1.5.5 的更新說明：「直接在鍵盤聽寫，不用切到 Raycast」。沒說用什麼技術。它已經上架，表示至少過了一次審核。

**風險**
- App Store 規範 2.5.1（繞過沙盒限制）。沒有任何來源提到審核結果。
- Apple 隨時可能封掉。
- 鍵盤記憶體上限約 60–70 MB。

**怎麼判斷成功**（診斷紀錄）
- `local page ready secure=true mediaDevices=true` → `local webkit media permission request … → grant` → `local mic started` → `local first sample since-tap=…ms`
- `local clip duration=… peak=…` → `local pipeline ok …` → `insert … path=local`
- 失敗：`local fallback → app … reason=…`

### 4.4 D：自動跳回原本的 App

**官方 API**：沒有。iOS 17 到 27 都沒有公開的「回上一個 App」，也沒有公開方法讓鍵盤知道自己在哪個 App。最接近的 `sourceApplication` 對別家的 App 回傳空值。

**D1：跳回事先選好的 App（已實作）**
- 使用者在設定選一個 App，錄音開始後用它的網址（例如 `line://`）打開它。
- 只能在主 App 還在前景時做。Dictus 的觀察是晚 5 秒重試就會被系統拒絕。
- 內建 15 個 App 的網址表（來自 Dictus 的清單）。訊息用 `ichat://`，因為 `sms://` 會開新訊息。Safari 和 Claude 沒有能回到原畫面的網址，所以不在表裡。
- **限制**：如果使用者其實是從別的 App 過來，還是會跳去選的那個。
- 預設「不自動跳回」。手動返回提示保留。

**D2：自動偵測所在 App（沒做）**

別的專案的做法，分兩步：
1. **偵測**（非公開）：
   - 讀鍵盤控制器上的 `_hostProcessIdentifier` 取得所在 App 的程序編號。
   - 透過 `_UIKeyboardArbiterClient` 蒐集「程序編號 → App 識別碼」的對應。
   - 需要在程式啟動前（`__attribute__((constructor))`）改掉 `+[_UIKeyboardArbiterClient enabled]` 這個系統函式。在 `viewWillAppear` 才改會失敗。
   - iOS 26.3 以前可以直接讀 `_hostBundleID`，26.4 被拿掉了。
2. **跳回**（公開）：用 App 對應的網址打開它。表裡沒有的 App 跳不回去。

**證據**
- Dictus PR #538：iPhone 15 Pro Max、iOS 26.6.1，12 次裡 9 次成功、1 次正確拒絕、2 次沒抓到，沒有跳錯 App。
- VivaDicta（開源）有同樣做法，聲稱已上架，對應表 88 個 App。
- macparakeet PR #7、typr PR #71：程式碼沒在實機跑過。
- Wispr Flow 的說法互相矛盾：更新說明寫自動返回在所有支援的 iOS 版本都能用（含 iOS 27 beta）；另一份使用者整理的文件寫 iOS 26.4 之後常常要手動滑回去。

**風險**
- 用非公開 API 加改系統函式。Dictus 作者：「有兩個上架的 App 用這個做法，這只代表有前例，不代表安全。」
- 那段啟動前執行的程式如果出錯，**鍵盤會完全不出現**。Dictus 發生過一次。
- Apple 會改：iOS 26.4 就拿掉一個屬性，造成大規模失效。

**如果要做**：做成開關、預設關閉、獨立成一個檔案，上架前可以整段拿掉。

### 4.5 E：App Intent 背景喚醒（沒做）

**做法**：`AudioRecordingIntent` 是公開 API，設計給動作按鈕、控制中心、捷徑用，讓 App 在背景被叫起來錄音。

**別人觀察到的條件**（都是二手資料）
- 要搭配 Live Activity，否則錄音會停。
- 要有背景音訊模式。
- 第一次啟用的工作階段必須是可混音的，否則被拒絕（`!int`）。
- 同一個程序裡第二次啟動會被拒絕（`!pla`）。
- 有專案回報只宣告 `AudioRecordingIntent`（不加 `LiveActivityIntent`）才成功，另有專案說兩個都要。互相矛盾。

**證據**
- avibe PR #4016 引用兩個專案：legato 7/7、oliv 12/12，都在 iPhone 17 上。我沒讀到原始資料。
- 這些全部是從動作按鈕、背後輕點、Siri、控制中心觸發。

**關鍵缺口**：**沒有找到任何人成功從鍵盤觸發。** Outspoken 說它的鍵盤透過「捷徑」間接觸發，沒說怎麼做，沒有數據。

**值不值得試**：如果 B 和 C 都不行，這是唯一一條全公開 API 的路，可以做一個小實驗：在鍵盤裡放 `Button(intent:)` 看系統會不會在主 App 的程序裡執行。

---

## 5. 其他同類產品的做法

| 產品 | 待命 | 返回 | 備註 |
|---|---|---|---|
| **Typeless** | 背景存活、閒置無麥克風 | 可能自動（一則評論） | 見第 3 節 |
| **Wispr Flow** | 工作階段可設：永不／1 小時／15 分／5 分（預設）／立即 | 自動，失敗時提示手動滑回 | 單次聽寫上限 5 分鐘；用 `.mixWithOthers` 不打斷音樂 |
| **Dictus**（開源） | 10 分鐘暖機，後來改成閒置靜音 | 非公開偵測加網址跳回 | 研究資料最完整 |
| **Outspoken** | 10 分鐘，輸出極小聲雜訊保活 | 跳到空白交接畫面 | 另有捷徑加 AudioRecordingIntent 的路，預設關 |
| **Raycast** | — | — | 1.5.5 起鍵盤內直接聽寫，技術未公開 |

---

## 6. 已知的坑

- **冷啟動後鍵盤會失聯約 10 秒**（Dictus #281，iOS 26.5–26.6）：跳到主 App 再回來後，系統把鍵盤的控制器全部銷毀，要再跳一次才恢復。只發生在冷啟動。原因不明，作者沒找到解法。
- **鍵盤回來時可能沒接上錄音狀態**：我們自己遇到的「後面幾次沒文字」。已修：改成每次狀態變化都嘗試接上，並在短時間內輪詢。
- **重裝 App 會把正在跑的鍵盤關掉**：測試時要等安裝完再切鍵盤。
- **讀 `documentIdentifier` 會讓鍵盤每次啟動都當掉**（Dictus 的教訓）：不要用。
- **模擬器不能驗證這些**：沒有真實音訊輸入，也不顯示螢幕鍵盤。全部要靠實機。

---

## 7. 實測計畫

測試清單在 `docs/DEVICE_TEST.md`。出問題時到「設定 → 診斷紀錄」複製內容。

1. **B 靜音待命**（預設）
   - 講完後橘燈有沒有熄。
   - 隔 1、5、9 分鐘再點，能不能直接講（麥克風圖示是實心）。
   - 連續幾次文字都有出來。
   - 播音樂時不會被打斷或變小聲。
2. **C 鍵盤內錄音**（設定裡打開）
   - 主 App 完全關掉後，點麥克風能不能直接講。
   - 按下到開始收音要多久。
   - 兩次聽寫之間沒有橘燈。
3. **A 輸出待命**：確認是否如預期被拒絕。
4. 依結果決定要不要做 D2 或 E。

---

## 8. 來源

**Typeless**
- [Typeless 官方說明：什麼時候會切換 App](https://www.typeless.com/help/release-notes/ios/when-does-app-switching-happen)
- [Typeless App Store 評論](https://apps.apple.com/us/app/typeless-ai-voice-keyboard/id6749257650?see-all=reviews&platform=iphone)
- [Dictus #430：研究 Typeless 如何不亮麥克風燈又不用跳 App](https://github.com/getdictus/dictus-ios/issues/430)

**背景待命**
- [Dictus #281：冷啟動後鍵盤失去控制約 10 秒](https://github.com/getdictus/dictus-ios/issues/281)
- [Wispr Flow：為什麼橘燈在聽寫後還亮著](https://docs.wisprflow.ai/articles/3634682593-why-the-orange-dot-or-mic-indicator-stays-on-after-dictating-ios)
- [Wispr Flow：為什麼不暫停背景音訊](https://docs.wisprflow.ai/articles/8415579688-why-wispr-flow-doesn-t-pause-background-audio-on-iphone-ios)
- [Outspoken：The keyboard is a remote control](https://www.useoutspoken.com/blog/the-keyboard-is-a-remote-control)
- [utter #267：讓 iOS 鍵盤的體驗接近 Typeless](https://github.com/harry2480/utter/issues/267)

**鍵盤內錄音**
- [AI-Notepad PR #503](https://github.com/senoldogan-labs/AI-Notepad/pull/503)
- [Diction #34](https://github.com/DictionLabs/Diction/issues/34)
- Hex：`anomalyco/hex` PR #1999（由上面兩篇引用）

**自動跳回**
- [Dictus PR #538：把使用者送回原本打字的 App](https://github.com/getdictus/dictus-ios/pull/538)
- [Dictus #23：冷啟動聽寫後自動返回的研究](https://github.com/getdictus/dictus-ios/issues/23)
- [macparakeet PR #7](https://github.com/brokenalarms/macparakeet/pull/7)
- [typr PR #71](https://github.com/hrudek/typr/pull/71)
- [Wispr Flow：因應 iOS 26.4](https://docs.wisprflow.ai/articles/6269634092-adapting-to-ios-26-4)
- [Wispr Flow field guide：iPhone 章節](https://github.com/vkorost/wispr-flow-field-guide/blob/main/book/chapters/05-iphone.md)
- [Wispr Flow What's new](https://wisprflow.ai/whats-new)

**App Intent 背景喚醒**
- [avibe PR #4016](https://github.com/avibe-bot/avibe/pull/4016)
- [avibe PR #3997](https://github.com/avibe-bot/avibe/pull/3997)
- [Mispher #5](https://github.com/migilabs/Mispher/issues/5)
- [OpenDictate PR #40](https://github.com/HerrStolzier/OpenDictate/pull/40)

**基本限制**
- [Apple Developer Forums 812091：從鍵盤啟動主 App](https://developer.apple.com/forums/thread/812091)
- [Apple Developer Forums 800500：在鍵盤 App 的背景錄音](https://developer.apple.com/forums/thread/800500)
