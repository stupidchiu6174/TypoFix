# TypoFix

macOS 全系統打字修正。在任何 App 的輸入框裡即時檢查錯字,畫出底線;滑過底線看建議,點一下或按 Tab 套用,Esc 略過。支援中文、日文、英文。

## 需求

- macOS 26 以上、Swift 6.2
- 輔助使用權限(讀取輸入框內容、畫底線都要)
- Anthropic API Key,或已登入的 Claude Code CLI

輸入框的文字會送到 Claude 檢查。密碼欄位會跳過。

## 使用

```bash
swift run TypoFixApp
```

啟動後在選單列出現圖示,API Key、觸發時機、日誌都在它的選單裡。日誌在 `~/Library/Logs/TypoFix.log`。

也可以當函式庫用:

```swift
import TypoFix

let typoFix = TypoFixController()
typoFix.start()
```

原本是 LiriOS 的一部分,部分介面文字還會提到 LiriOS。
