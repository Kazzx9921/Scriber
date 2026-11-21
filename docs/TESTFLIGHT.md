# 上傳到 TestFlight

> 只有 iOS 版。macOS 版不走 App Store（見 `PRD-macOS版.md` 第 7 節）。

## 每次上傳前

1. **把建置編號加一**（App Store Connect 不收編號沒有變大的版本）：
   ```
   scripts/bump-build.sh          # 建置編號 +1
   scripts/bump-build.sh 1.0.0    # 同時改版本號
   ```
   版本號和建置編號寫在 `project.yml` 最上面的 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`，主 App 和鍵盤共用同一組。
2. 跑測試：`cd Packages/ScriberCore && swift test`

## 第一次要做的（只做一次）

1. 到 [App Store Connect](https://appstoreconnect.apple.com) →「我的 App」→ 新增 App。
   - 平台：iOS
   - 套件識別碼：`com.geekaz.Scriber`
   - 名稱要是 App Store 上沒人用過的。
2. 鍵盤的識別碼 `com.geekaz.Scriber.Keyboard`、App Group `group.com.geekaz.Scriber`、Keychain 群組，Xcode 自動簽署會自己處理。

## 打包上傳

**用 Xcode**
1. `open Scriber.xcodeproj`
2. 上方裝置選「Any iOS Device (arm64)」。
3. Product → Archive。
4. 完成後在 Organizer 按 Distribute App → App Store Connect → Upload。

**用指令**（需要 Xcode 已登入開發者帳號）
```
xcodebuild -project Scriber.xcodeproj -scheme Scriber -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/ios/Scriber.xcarchive \
  -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath build/ios/Scriber.xcarchive \
  -exportOptionsPlist scripts/ExportOptions.plist -exportPath build/ios/export \
  -allowProvisioningUpdates
```
`scripts/ExportOptions.plist` 還沒建立，要用指令上傳時再加（`method` = `app-store-connect`，`destination` = `upload`）。

## 加測試者

| | 內部測試 | 外部測試 |
|---|---|---|
| 對象 | App Store Connect 團隊成員 | 任何人，email 或公開連結 |
| 人數 | 最多 100 | 最多 10,000 |
| 審核 | 不用 | 第一個版本要過 Beta 審核 |

朋友人數少的話，把他們加進團隊（「使用者與存取權限」，角色選最低的）走內部測試最快。

測試者在手機裝 TestFlight App，點邀請連結安裝。每個版本可測 90 天。

## 給測試者的說明要包含

- **要自己準備 API key**。Scriber 是自備 key 的設計。Groq 有免費額度，門檻最低；ElevenLabs Scribe v3 最準。
- 加入鍵盤：設定 → 一般 → 鍵盤 → 鍵盤 → 新增鍵盤 → Scriber，再開「允許完整取用」。
- 出問題時到 Scriber「設定 → 實驗功能 → 診斷紀錄」複製內容回報。裡面沒有說話內容和 key。

## 外部測試送審前要處理

- **審核備註要附一把測試用的 API key 和操作步驟**，不然審核人員無法驗證功能。
- 說明鍵盤為什麼需要「完整取用」（鍵盤要跟主 App 溝通，麥克風在主 App）。
- 說明為什麼需要背景音訊（待命時讓鍵盤不用每次跳到 App）。
- **「在鍵盤內直接錄音」建議先拿掉**。它預設關閉，但程式碼和鍵盤的麥克風用途宣告都在，是退件風險最高的一項（規範 2.5.1）。
- App Store Connect 的「App 隱私權」問卷要自己填，見下一節。

## 隱私權

- `App/PrivacyInfo.xcprivacy` 和 `Keyboard/PrivacyInfo.xcprivacy` 宣告了用到的系統 API 和原因：
  - UserDefaults（App 自己的設定，以及主 App 和鍵盤共用的 App Group）
  - 檔案時間戳（自己容器內的錄音暫存檔）
  - 系統開機時間（量測耗時和逾時）
  - 作用中的鍵盤（主 App 檢查自己的鍵盤有沒有被加入）
- 清單裡「收集的資料」目前填的是**沒有**。理由是 Scriber 沒有自己的伺服器，音訊是用使用者自己的 key 直接送到使用者選的服務。但音訊確實離開了裝置，Apple 怎麼認定這種情況沒有明確的說法。**上架前要自己判斷 App Store 的隱私權標示怎麼填**，保守的做法是標示「音訊資料，用於 App 功能，不與身分連結，不用於追蹤」。

## 新增程式碼時要注意

用到新的「需要說明原因的 API」時，要同步更新兩份 `PrivacyInfo.xcprivacy`。常見的有：UserDefaults、檔案時間戳、磁碟空間、系統開機時間、作用中的鍵盤。
