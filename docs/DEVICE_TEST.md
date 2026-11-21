# 實機測試：三種待命方式比較

模擬器看不到橘色麥克風燈，也測不到「鍵盤叫背景的 Scriber 錄音」，以下只能在 iPhone 上做。
目的：找出哪一種待命方式在你的手機上能「講完橘燈就熄、下次不用跳 App」。

## 0. 準備（一次就好）

- [ ] Xcode 裝 Debug 版到手機。設定 > 一般 > 鍵盤 > 新增 Scriber，打開「允許完整取用」。
- [ ] Scriber 給麥克風權限、填 API key。
- [ ] Scriber > 設定 > 實驗功能：
  - 自動跳回原本的 App：開，「跳回」選你要測的 App（建議先選 **備忘錄**，已有人實測過）。
  - 在鍵盤內直接錄音：**關**（這次只測待命）。
- [ ] 設定 > 診斷紀錄 > 「清除」。每測完一種方式就「複製」一次貼給我，再清除。

## 1. 每種方式都照這個做

到 設定 > 實驗功能 > 待命方式 選一種，待命時間選 **10 分鐘**，然後：

1. 用 Apple Music／Spotify 放音樂（音量小一點）。
2. 到備忘錄，切到 Scriber 鍵盤，點麥克風 → 應該跳到 Scriber，再自動回到備忘錄（沒回去就點左上角「◀︎」）。
3. 說一句話，點一下結束，文字要插入。
4. **講完立刻看右上角：橘色麥克風燈有沒有熄？** 30 秒後再看一次。
5. 分別等 **1 分鐘、5 分鐘、9 分鐘**（期間可以鎖屏）各點一次麥克風說話，記下：
   - 有沒有跳到 Scriber？（沒跳 = 待命成功）
   - 第一個字有沒有被吃掉？
   - 錄完橘燈有沒有熄？
6. 整段過程音樂**不能暫停、不能變小聲**。
7. 等超過 10 分鐘再點 → 這次應該會跳到 Scriber 一次（待命結束）。

每種方式記一行就好：

| 方式 | 講完橘燈熄？ | 1 分 | 5 分 | 9 分 | 第一個字 | 音樂正常？ |
|---|---|---|---|---|---|---|
| 講完即關 | | 跳 | 跳 | 跳 | | |
| 靜音待命 | | | | | | |
| 輸出待命（播放模式） | | | | | | |
| 輸出待命（錄音模式） | | | | | | |

「輸出待命」有兩種閒置方式，在 診斷紀錄 右上角「⋯」切換（播放模式是預設），兩種都測。
如果輸出待命時鍵盤顯示「這次要打開 Scriber 才能錄音」，就是 iOS 不准背景開麥克風，這也是答案，照樣把紀錄貼回來；
之後到設定按「再試一次輸出待命」才會重新測。

## 2. 預期（還沒驗證，請用實測推翻）

- **講完即關**：每次都跳 App；橘燈只在錄音時亮。
- **靜音待命**：不跳 App；靜音時橘燈應該熄（另一個開源專案在一支 iPhone 上實測過：10 次都能直接錄，0.05–0.11 秒開始收音）；第一個字可能被吃掉一點點。
- **輸出待命**：講完橘燈一定熄；但另一個專案實測時 iOS 拒絕在背景重開麥克風，很可能 1 分鐘那次就請你再點一次。

## 3. 紀錄裡我要看的幾行

貼整段就好，這是我會找的：

| 想知道 | 紀錄裡的字 |
|---|---|
| 被叫起來、開始錄 | `url session`、`session started`、`launch request`、`recording id=… from=…` |
| 自動跳回 | `autoReturn attempt` → `autoReturn result … opened=true/false` |
| 講完後麥克風怎麼處理 | `mute true ok`（靜音待命）／`input stop`、`category Playback`、`keepAlive start ok`（輸出待命）→ `standby idle … posture=…` |
| 背景時 App 有沒有被系統暫停 | `heartbeat resumed after a …s gap`（有這行 = 待命期間被暫停過） |
| 1／5／9 分鐘那次 | `cmd start … posture=… idleFor=…s` 之後是 `recording id=… inputReadyMs=…`（成功）或 `microphone failed … domain=… code=…('!rec' 或 'what')`（被拒） |
| 第一個字 | `capture end … firstSignalMs=… commandToSignalMs=…`（數字越小越不會吃字） |
| 音樂 | `activate ok … otherAudio=true`、`route change …` |
| 待命結束 | `session ended reason=…`（`expired` = 時間到） |

紀錄只有狀態、時間和錯誤代碼，**不會有你說的內容、選取的文字或 API key**。

## 4. 有空再測

- [ ] 靜音待命中**接一通電話**，掛掉後點麥克風：能直接錄，或跳 App 一次（都可以，但不能卡住）。找 `interruption began/ended`、`revive … ok=`。
- [ ] 待命中戴上／拿下 AirPods 後點麥克風。找 `route change`。
- [ ] 待命中把 Scriber 從多工畫面滑掉 → 下次點麥克風應該跳 App，不會卡住。
- [ ] 錄音中來電 → 已說的內容照常送出。
- [ ] 飛航模式說一段 → 顯示網路失敗＋「重試」→ 關飛航按重試 → 文字插入。

## 5. 可調參數（有問題時回報）

| 現象 | 可調的地方 |
|---|---|
| 第一個字被吃掉 | `CaptureBuffer.preRollSeconds`（講完即關才有預錄） |
| 小聲說話被判成「沒有聽到聲音」 | `DictationEngine.silenceLevel`（預設 0.12） |
| 鍵盤太常誤判 App 沒回應 | `KeyboardModel.ackTimeout`（預設 1.5 秒） |
| 通話後太快放棄待命 | `DictationEngine.interruptionGrace`（預設 60 秒） |
