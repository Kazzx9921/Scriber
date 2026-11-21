# App Store 上架資料

> App Store Connect：https://appstoreconnect.apple.com/apps/6837815862/distribution
> 這份文件是可以直接貼進 App Store Connect 的內容，加上送審前的檢查清單。
> 標 ⚠️ 的是要你自己決定或自己處理的。

---

## 1. 檢查清單

### 專案（已完成）
- [x] App 圖示（1024，無透明）
- [x] 隱私權清單（主 App、鍵盤各一份）
- [x] 出口合規聲明（`ITSAppUsesNonExemptEncryption = false`）
- [x] 麥克風用途說明
- [x] 版本號 1.0，Release 版可以封存
- [x] 首次設定明確寫出「你說的話會直接送到你選的服務辨識」
- [x] 隱私權政策文字（`docs/PRIVACY.md`）

### 已決定（2026-11-22）
- **「在鍵盤內直接錄音」先不拿掉**，照現狀送審。這是退件風險最高的一項（見第 7 節），被退的話再拿掉重送。
- **隱私權問卷填「不收集資料」**（第 5 節的填法 A）。
- **截圖**由程式產生，放在 `docs/appstore/screenshots/`。

### 專案（待處理）
- [ ] **在 iPad 上跑一次**。App 只支援 iPhone，但審核常用 iPad 以相容模式測試，不能當掉
- [ ] 上傳前跑 `scripts/bump-build.sh`

### App Store Connect（要你在網頁上做）
- [ ] 貼上第 2 節的商店資訊
- [ ] 上傳截圖（第 3 節）
- [ ] 填 App 隱私權問卷（第 5 節）
- [ ] 填年齡分級問卷（第 4 節）
- [ ] 設定價格（第 4 節）
- [ ] 填審核資訊和備註（第 6 節）
- [ ] 上傳建置版本並選取
- [ ] ⚠️ 隱私權政策和支援網址要是**公開可以打開的**（第 2 節）
- [ ] ⚠️ 付費 App 需要已簽署「付費 App 協議」並填好銀行和稅務資料。PhotoClean 有內購的話應該已經完成

---

## 2. 商店資訊（繁體中文）

**名稱**（30 字內）
```
Scriber - 開源語音輸入鍵盤
```

**副標題**（30 字內）
```
按一下說話，自動整理成繁體中文
```

**宣傳文字**（170 字內，隨時可改、不用重新送審）
```
用說的比打字快。在任何 App 切到 Scriber 鍵盤，點一下麥克風開始說，再點一下，整理好的繁體中文就打進去了。
```

**描述**
```
Scriber 是一個語音輸入鍵盤。在任何 App 裡切換到 Scriber，點一下麥克風說話，再點一下，文字就會出現在輸入框裡。

【為繁體中文設計】
・一律輸出繁體中文和台灣用語，不會出現簡體字
・中英夾雜也能辨識，英文專有名詞保持原文
・自動加上全形標點，中英文之間的空格可以自己決定
・短句不加句號、標點換成空格，都可以在設定裡調整

【不只是逐字稿】
・自動去掉「嗯、呃、那個」這類贅字和口吃
・個人字典：把常用的人名、品牌、專有名詞加進去，辨識時就會照你的寫法輸出
・翻譯：說中文，直接輸出英文、日文、韓文等語言，長按可快速切換
・說話改字：選取一段文字，用說的告訴它怎麼改

【用你自己的 API key】
Scriber 沒有自己的伺服器，也不收月費。你使用自己的 API key 連到語音辨識服務，費用由服務商直接向你收取，通常非常低。

支援的服務：
・ElevenLabs Scribe v3
・Groq Whisper Large v3／Turbo
・任何 OpenAI 相容的語音辨識服務（自訂網址和模型）

翻譯和 AI 潤飾可使用 Groq 或 Anthropic Claude。

【隱私】
・錄音直接從你的手機送到你選的服務，不經過開發者
・沒有追蹤、沒有廣告、沒有分析工具
・歷史紀錄和個人字典只存在你的手機上
・原始碼公開，任何人都可以檢查

【使用前請注意】
・需要自備 API key（至少一組語音辨識服務的 key）
・需要在「設定 → 一般 → 鍵盤」加入 Scriber 鍵盤，並開啟「允許完整取用」。鍵盤要靠它跟 Scriber App 溝通，因為 iOS 不允許鍵盤直接使用麥克風
・Scriber 鍵盤只有語音輸入，沒有打字按鍵。要打字時請切回系統鍵盤
・第一次使用或一段時間沒用時，點麥克風會先跳到 Scriber App 啟動錄音，再回到原本的 App 繼續
```

**關鍵字**（100 字元內，用半形逗號分隔，不要空格）
```
語音輸入,聽寫,語音轉文字,鍵盤,繁體中文,語音鍵盤,口述,轉錄,翻譯,whisper,dictation,voice,keyboard
```
> 名稱裡已經有的詞（語音輸入、鍵盤、開源）不用重複放，可以換成其他詞。上面這組約 70 字元，還有空間。

**支援網址** ⚠️
```
https://github.com/Kazzx9921/Scriber/issues
```

**行銷網址**（選填）
```
https://github.com/Kazzx9921/Scriber
```

**隱私權政策網址** ⚠️
```
https://github.com/Kazzx9921/Scriber/blob/main/docs/PRIVACY.md
```

> ⚠️ 這三個網址現在都打不開，因為 repo 還是私人的。**送審前要先把 repo 轉成公開**，或把隱私權政策和支援頁放到別的公開網址（例如 geekaz.net）。審核人員打不開會直接退件。名稱裡寫了「開源」，所以上架時 repo 也應該要是公開的。

**版權**
```
2026 Kazen
```

---

## 3. 截圖 ⚠️

必須提供，至少一組：

| 尺寸 | 解析度 | 備註 |
|---|---|---|
| 6.9 吋（必要） | 1320 × 2868 或 1290 × 2796 | iPhone 17 Pro Max 等 |
| 6.5 吋（選填） | 1284 × 2778 或 1242 × 2688 | 沒提供會用 6.9 吋的縮放 |

最少 1 張，最多 10 張。建議 4 到 5 張：

1. 在訊息 App 裡使用 Scriber 鍵盤，膠囊顯示錄音波形
2. 辨識結果打進輸入框
3. 長按翻譯鍵選語言
4. 主 App 首頁「省下的時間」
5. 設定頁（引擎和個人字典）

> 你的 iPhone Air 螢幕截圖是 1260 × 2736，不在上面的尺寸裡。App Store Connect 收不收這個尺寸我不確定，上傳時如果被拒，要改用模擬器（iPhone 17 Pro Max）截，或把圖放到符合尺寸的畫布上。

---

## 4. 一般資訊

| 欄位 | 填法 |
|---|---|
| 主要類別 | 生產力工具 |
| 次要類別 | 工具程式 |
| 內容版權 | 不含第三方內容 |
| 年齡分級 | 問卷全部選「無」，結果是 4+ |
| 價格 | NT$60（美國區對應 US$1.99，實際以 App Store Connect 的價格點為準） |
| 供應狀況 | 所有國家或地區，或先只開台灣 |
| 版本 | 1.0（要跟建置版本的版本號一致） |

---

## 5. App 隱私權問卷 ⚠️

**已決定用填法 A（不收集資料）。** 兩種填法的說明保留在下面，被 Apple 質疑時可以改用 B。

**填法 A：不收集資料**
- 理由：開發者沒有伺服器，拿不到任何資料。音訊是用使用者自己的帳號送到使用者選的服務，那些服務不是開發者的合作夥伴。
- 結果：商店頁面顯示「未收集資料」。

**填法 B：收集音訊資料（保守）**
- 資料類型：使用者內容 → 音訊資料
- 用途：App 功能
- 是否與使用者身分連結：否
- 是否用於追蹤：否
- 理由：音訊確實離開了裝置，由第三方處理。

Apple 對「收集」的定義是：資料傳出裝置，而且你或你的第三方合作夥伴可以存取，時間超過即時處理請求所需。Scriber 的情況介於兩者之間，我沒有找到針對「使用者自備 key」的明確說法。填法 B 比較不會被質疑，但會讓商店頁面顯示有收集資料。

---

## 6. 審核資訊

**聯絡資訊**：填你的姓名、電話、email。

**登入資訊**：不需要登入，不勾選。

**備註**（審核人員看英文，建議用英文寫）⚠️ 要把 `<…>` 換成實際內容

```
Scriber is a voice dictation keyboard. It has no backend and no account system: users bring their own API key for a speech-to-text provider. A demo key is provided below so you can test.

DEMO API KEY (ElevenLabs): <paste a key created for App Review; revoke it after approval>

HOW TO TEST
1. Open Scriber and go through onboarding: allow the microphone, paste the demo key under ElevenLabs, then add the keyboard.
2. In Settings > General > Keyboard > Keyboards > Add New Keyboard, choose Scriber, then open it and enable "Allow Full Access".
3. Open Notes, tap a note, switch to the Scriber keyboard with the globe key.
4. Tap the microphone pill. The first time, iOS switches to the Scriber app to start recording; tap the back chip at the top-left to return to Notes.
5. Speak (Mandarin or English), then tap the pill again. The text is inserted.
6. Within the next few minutes, tapping the pill again records without leaving Notes.

WHY THE KEYBOARD NEEDS FULL ACCESS
iOS does not allow app extensions to use the microphone, so the keyboard asks the containing app to record. Full Access is required for the keyboard to communicate with the app through the shared App Group and to open the containing app. The Scriber keyboard has no typing keys and does not read or transmit anything typed with other keyboards.

WHY THE APP USES BACKGROUND AUDIO
After a dictation, the app stays available in the background for a few minutes so that the next tap on the keyboard can record immediately without switching apps again. During this standby the microphone input is muted and nothing is recorded, stored or sent. Audio is captured only between the user's two taps on the microphone. Standby ends automatically after the chosen idle time.

DATA
Audio is sent directly from the device to the provider the user selected (ElevenLabs or Groq), using the user's own API key. If the user enables AI polish or translation, the recognized text is sent to Groq or Anthropic. The developer operates no server and receives no data. This is stated in onboarding and in the privacy policy.

The app is iPhone-only and its interface is in Traditional Chinese.
```

---

## 7. 可能被審核問的地方 ⚠️

| 項目 | 風險 | 建議 |
|---|---|---|
| 「在鍵盤內直接錄音」（實驗功能） | 高。繞過「延伸功能不能用麥克風」的限制，規範 2.5.1。預設關閉，但程式碼和鍵盤的麥克風用途宣告都在 | **決定先保留送審。** 被退件時拿掉：刪 `Keyboard/WebMicrophone.swift`、`Keyboard/InKeyboardCapture.swift` 的使用、設定裡的開關，以及鍵盤 Info.plist 的麥克風用途說明 |
| 背景音訊（靜音待命） | 中。規範 2.5.4 要求背景模式用於其宣告的用途 | 備註裡已說明。被退的話退回「講完即關」模式 |
| 鍵盤需要完整取用才有功能 | 中。規範 4.4.1 說鍵盤在沒有完整網路存取時要維持可用 | 備註裡已說明。同類產品（Typeless、Wispr Flow）也是這樣上架的 |
| 鍵盤開啟主 App | 低到中。規範 4.4.1 說鍵盤不能開啟設定以外的 App | Apple 工程師在開發者論壇確認開啟自己的主 App 是允許的 |
| 需要自備 API key | 低。審核人員要能測試 | 備註裡附測試用的 key |
| 把資料送到第三方 AI | 低。規範 5.1.2 要求明確告知並取得同意 | 首次設定已明確寫出，使用者自己填 key 才會啟用 |
| 名稱裡的「開源」 | 低 | 上架時 repo 要是公開的 |
| 只有繁體中文介面 | 無 | 可以上架。之後想推到其他地區再加英文 |

---

## 8. 送審順序

1. 截圖產生完成後檢查一遍（`docs/appstore/screenshots/`）。
2. 把 repo 轉成公開（或把隱私權政策和支援頁放到別的網址）。
3. `scripts/bump-build.sh`，封存並上傳。
4. 先用 TestFlight 內部測試確認 Release 版正常。
5. 到 App Store Connect 貼上第 2 節的內容、上傳截圖、填問卷、設定價格、選建置版本。
6. 申請一把給審核用的 API key，貼進備註。
7. 送審。通過後撤銷那把 key。
