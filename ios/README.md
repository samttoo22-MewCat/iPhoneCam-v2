# Phone Lens：iOS 相機與美顏原型

以 iPhoneCam-v2 `17c3e1a` 的 Android 版面、配色與操作流程為基準移植，不更動 Android／Windows 程式或 CAM1/CUM1 協定。2026-10-26 版本範圍為手機預覽、真實 GPU 美顏與相機控制；未提供桌面傳輸。

## 已提供

- 深紫黑底、青／紫／粉配色、首頁／設定／幫助導覽，繁體中文及 SF Symbols。
- iOS 26+ 原生 `.glass`、`.glassProminent`、`GlassEffectContainer`；iOS 17–25 採標準 bordered 樣式。
- 系統 sheet、磨皮／美白／清晰／紅潤／補光、重設與原圖對比，以及面板／導覽切換觸覺回饋。
- 面板顯示時隱藏底層控制，避免有色按鈕穿透造成光塊。
- AVFoundation → BGRA 最新幀 → Metal 單 pass → MTKView；丟棄過時影格，GPU 完成前保留 Core Video buffer。參數歸零或停用時為原圖直通。
- 列舉實體前／後鏡頭、4:3 解析度檔位與 30／60 FPS；選最接近的裝置支援尺寸並顯示實際值。不支援所選 FPS 時保留原設定並顯示錯誤。設定提交、解除裝置鎖定後才啟動 session；背景暫停、返回恢復（使用者手動暫停則保持暫停）。
- `UILaunchScreen` 與直向宣告；根畫面頂端對齊並只使用系統安全區。此為手機控制介面的直向版，尚未實作橫向 UI。

## 尚未提供

參數只保留本次執行，尚無持久化。美顏沿用上游的固定中央橢圓加權，**不是人臉偵測／追蹤**；清晰效果也影響背景。補光是 iOS 保留控制。尚無 VideoToolbox 編碼、碼率控制、USB/usbmux、CAM1/CUM1、桌面握手、錄影或 virtual camera 串接。FPS 數字分為設定值與擷取回呼實測值，不代表 GPU 呈現率或端到端效能。

Simulator 不會請求或開啟任何相機，顯示「模擬器沒有相機 · 可操作介面」。無法用它驗證鏡頭切換、實拍美顏品質、發熱或實體觸覺。

此模板的 Phone Lens 名稱與配色是本次 iOS 設計提案；不取代根目錄 SPEC-v3.md 的既有 Windows／Android 規格。未來對接應遵守該文件的協定與解析度要求。

## 建置

以 Xcode 26+ 開啟 `PhoneLens.xcodeproj`，選擇 `PhoneLens` scheme 與 iPhone Simulator。最低部署版本 iOS 17。2026-10-26 使用者重新授權真機安裝，最新版已簽署建置並安裝至 iPhone 14 Pro（`tw.phonecamera.phonelens`）；本次未啟動 App，安裝成功不代表實拍驗收。自動 UI 驗收維持本地 Simulator，不使用 QuickTime／Mac 相機。

從儲存庫根目錄執行：

```sh
xcodebuild -project ios/PhoneLens.xcodeproj -scheme PhoneLens \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/phonelens-template-build build CODE_SIGNING_ALLOWED=NO
```

## 驗證範圍

2026-10-21 已在 Xcode 27 / iPhone 14 iOS 27 Simulator 安裝、啟動並目視檢查首頁和美顏面板：控制文字未溢出、三個滑桿同時可見、面板沒有底層彩色光塊。2026-10-23 PR 整理時重新建置。

2026-10-26：macOS 上以正式 `BeautyRenderer`／Metal shader 跑離屏 GPU 測試，驗證參數界限、NaN、停用直通、UV／通道順序、五項效果確實改變像素及遮罩範圍。iPhone 14 iOS 27 Simulator 已安裝並檢查首頁頂端對齊、三頁導覽、面板開關、五項控制完整顯示、美顏停用／重設／原圖對比。這不代表相機完整管線或實拍效果已驗收。Device Hub 的 slider AX setValue 未使 SwiftUI 數字同步，座標拖曳回報 noWindowsAvailable，因此滑桿拖曳到影像的互動仍需再驗證；不能用 AX 值變動假稱成功。

執行實際 GPU 回歸測試（需要支援 Metal 的 Mac）：

```sh
xcrun swiftc ios/PhoneLens/BeautyParams.swift ios/PhoneLens/BeautyRenderer.swift ios/tests/BeautyTests.swift -o /tmp/phonelens-beauty-tests
/tmp/phonelens-beauty-tests
```

真機相機控制、畫面方向、前置鏡像、背景返回、4K/60fps 發熱及舊版 OS fallback 尚未驗收。本輪提交分支為 `feat/ios-android-ui-metal-beauty`，不包含桌面串流，也不代表完成端到端驗收。
