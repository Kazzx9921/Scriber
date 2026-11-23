# 發布 macOS 版

> macOS 版不走 App Store，用 Developer ID 簽署加上 Apple 公證，包成 DMG 直接給人下載。
> 沒有公證的版本在別人的 Mac 上會打不開（只顯示「無法打開應用程式」）。

## 需要的東西（只做一次）

- 鑰匙圈裡有「Developer ID Application: Geekaz LLC」憑證。只有開發者團隊的帳號持有人能建立。
  Xcode 裡建不出來時（顯示只有 Account Holder 能做），改到 developer.apple.com → Certificates 用憑證申請檔建立，再把下載的憑證和本機的私鑰一起匯入鑰匙圈。
- Xcode → Settings → Accounts 有登入團隊的 Apple 帳號。公證走 Xcode 的登入，不需要另外設 App 專用密碼。

## 步驟

```
# 1. 封存
xcodebuild -project Scriber.xcodeproj -scheme ScriberMac -configuration Release \
  -archivePath build/mac-archive/Scriber.xcarchive archive

# 2. 用 Developer ID 簽署並送公證
xcodebuild -exportArchive -archivePath build/mac-archive/Scriber.xcarchive \
  -exportOptionsPlist scripts/ExportOptions-mac.plist \
  -exportPath build/mac-archive/export -allowProvisioningUpdates

# 3. 等 Apple 處理完，取回公證好的 App（還在處理時會回報 processing，過一陣子再試）
xcodebuild -exportNotarizedApp -archivePath build/mac-archive/Scriber.xcarchive \
  -exportPath build/mac-archive/notarized

# 4. 包成 DMG（會檢查公證、簽署 DMG、確認系統放行）
scripts/make-mac-dmg.sh
```

成品在 `build/dist/Scriber-<版本>.dmg`。`build/` 不進版本控制。

## 注意

- 公證通常幾分鐘，新憑證或新 App 第一次送可能要更久。
- 版本號和建置編號跟 iOS 共用，寫在 `project.yml`。
- 提示音的授權見 `Mac/Resources/Sounds/NOTICE.md`。
