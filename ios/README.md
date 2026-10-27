# Phone Lens：iOS 相機與美顏原型

以 iPhoneCam-v2 `17c3e1a` 的 Android 版面、配色與操作流程為基準移植。2026-10-27 版本已能把真機的美顏 H.264 影像經 USB/usbmuxd 送到 macOS `PhoneLensReceiver` 預覽；這不等於 macOS 系統虛擬攝影機、OBS 或視訊通話已完成。

## 已提供

- 深紫黑底、青／紫／粉配色、首頁／設定／幫助導覽，繁體中文及 SF Symbols。
- iOS 26+ 原生 `.glass`、`.glassProminent`、`GlassEffectContainer`；iOS 17–25 採標準 bordered 樣式。
- 系統 sheet、磨皮／美白／清晰／紅潤／補光、重設與原圖對比，以及面板／導覽切換觸覺回饋。
- 面板顯示時隱藏底層控制，避免有色按鈕穿透造成光塊。
- 開源人臉偵測引擎 `PhoneLens/FaceEngine`（C++）：SCRFD `det_10g` 偵測＋`2d106det` 106 點＋IoU 追蹤（穩定 track_id＋EMA 平滑）＋solvePnP 頭姿＋年齡/性別屬性模型；onnxruntime-c 1.17.1＋OpenCV2 pod。美顏橢圓遮罩跟隨鎖定人臉（臉中心＝眼線／嘴線加權）；沒有可信追蹤時效果淡出為原圖，絕不猜測畫面中央。預覽疊層顯示鎖定狀態（id／張數／yaw／耗時）。僅真機連結引擎（CocoaPods 的 OpenCV2 無 arm64-simulator slice）；模擬器顯示「模擬器無相機」。
- 20 項 106 點臉部 mesh 微調（瘦臉、大眼、鼻型、嘴型、下頜線等），採用 Delaunay 三角形 warp；翻面或退化三角形會被 C++ 端剔除。內建「自然／清新／上鏡／明顯」為本專案原創參數，不使用第三方美顏預設。自製三張 512px ROI mask 已隨 App bundle 打包。
- AVFoundation → BGRA 最新幀 → FaceEngine（偵測佇列 latest-wins）＋Metal 單 pass → MTKView；丟棄過時影格，GPU 完成前保留 Core Video buffer。參數歸零或停用時為原圖直通。
- 列舉實體前／後鏡頭、4:3 解析度檔位與 30／60 FPS；選最接近的裝置支援尺寸並顯示實際值。不支援所選 FPS 時保留原設定並顯示錯誤。設定提交、解除裝置鎖定後才啟動 session；背景暫停、返回恢復（使用者手動暫停則保持暫停）。
- VideoToolbox H.264（Annex-B）編碼與 PLNS v1 串流：手機端以 loopback `127.0.0.1:8765` 監聽，12 幀有界佇列、keyframe 優先、CONFIG 重播與 keep-alive；macOS receiver 以原生 usbmuxd 連線，不依賴 iproxy／Homebrew。
- 同一個 offscreen IOSurface pixel buffer 同時供預覽與編碼使用，避免預覽被 sheet 遮住時 USB 串流停止。
- `UILaunchScreen` 與直向宣告；根畫面頂端對齊並只使用系統安全區。此為手機控制介面的直向版，尚未實作橫向 UI。

## 尚未提供

參數只保留本次執行，尚無持久化。美顏遮罩與 mesh 已由開源人臉引擎驅動（偵測→追蹤→錨定）；清晰效果也影響背景。**真機實拍的人臉跟蹤、mesh 變形品質、耗時與發熱尚未驗收**。補光是 iOS 保留控制。USB 串流只提供 Mac Receiver 預覽；尚無錄影、macOS 系統虛擬攝影機、OBS 設定或 Windows USB 實機驗收。FPS 數字分為設定值與擷取回呼實測值，不代表 GPU 呈現率或端到端效能。

Simulator 不會請求或開啟任何相機，顯示「模擬器沒有相機 · 可操作介面」。無法用它驗證鏡頭切換、實拍美顏品質、發熱或實體觸覺。

此模板的 Phone Lens 名稱與配色是本次 iOS 設計提案；不取代根目錄 SPEC-v3.md 的既有 Windows／Android 規格。未來對接應遵守該文件的協定與解析度要求。

## CocoaPods

本機不追蹤 `Pods/`。先安裝 CocoaPods，再在 `ios/` 目錄執行：

```sh
pod install
```

## 建置

以 Xcode 27 開啟 **`PhoneLens.xcworkspace`**（CocoaPods：onnxruntime-c 1.17.1、OpenCV2），選擇 `PhoneLens` scheme。最低部署版本 iOS 17。模型來源與發行限制見 `PhoneLens/FaceEngine/Models/README.md`。2026-10-26 使用者重新授權真機安裝，最新版已簽署建置並安裝至 iPhone 14 Pro（`tw.phonecamera.phonelens`）；安裝成功不代表實拍驗收。自動 UI 驗收維持本地 Simulator，不使用 QuickTime／Mac 相機。

從儲存庫根目錄執行：

```sh
# 模擬器（引擎排除、UI 可驗證）
xcodebuild -workspace ios/PhoneLens.xcworkspace -scheme PhoneLens \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/phonelens-template-build build CODE_SIGNING_ALLOWED=NO

# 真機（iPhone 14 Pro，UDID 見 devicectl list devices）
xcodebuild -workspace ios/PhoneLens.xcworkspace -scheme PhoneLens \
  -sdk iphoneos -destination 'id=<UDID>' DEVELOPMENT_TEAM=<team> \
  -allowProvisioningUpdates -derivedDataPath /tmp/phonelens-wfd-dev build
xcrun devicectl device install app --device <UDID> \
  /tmp/phonelens-wfd-dev/Build/Products/Debug-iphoneos/PhoneLens.app
```

## 驗證範圍

2026-10-21 已在 Xcode 27 / iPhone 14 iOS 27 Simulator 安裝、啟動並目視檢查首頁和美顏面板：控制文字未溢出、三個滑桿同時可見、面板沒有底層彩色光塊。2026-10-23 PR 整理時重新建置。

2026-10-26：macOS 上以正式 `BeautyRenderer`／Metal shader 跑離屏 GPU 測試，驗證參數界限、NaN、停用直通、UV／通道順序、五項效果確實改變像素及遮罩範圍。iPhone 14 iOS 27 Simulator 已安裝並檢查首頁頂端對齊、三頁導覽、面板開關、五項控制完整顯示、美顏停用／重設／原圖對比。這不代表相機完整管線或實拍效果已驗收。Device Hub 的 slider AX setValue 未使 SwiftUI 數字同步，座標拖曳回報 noWindowsAvailable，因此滑桿拖曳到影像的互動仍需再驗證；不能用 AX 值變動假稱成功。

2026-10-26（人臉引擎整合）：模擬器 generic build 通過；真機 Debug build（`DEVELOPMENT_TEAM`＋`-allowProvisioningUpdates`）通過並安裝至 iPhone 14 Pro；離屏 GPU 回歸測試（uniforms 擴為 10 個：5 控制＋臉遮罩 5 值）全 PASS。未啟動 App／相機，實拍跟蹤品質未驗收。

2026-10-27（mesh 接線）：遠端 Linux 引擎對 lena 實測 214 個 identity triangles（最大 source/destination 誤差 `0`、無非有限數）；變形輸出 200 個有效 triangles、0 個翻面。Xcode generic simulator／iphoneos build 均通過，既有離屏 Metal 五效果回歸全 PASS；未簽署、安裝、啟動 App 或相機，尚不能作為真機 mesh 效果驗收。

2026-10-27（追蹤修正）：tracker 現在會將 landmark refresh 回存至穩定 track，避免 106 點 mesh 每幀遺失；屬性模型改為可選，載入失敗不再中斷偵測／106 點／美顏流程。預覽 overlay 會明確顯示人臉引擎載入錯誤，而非誤報為未偵測到人臉。Simulator 和 signed iPhone build 均通過，已覆蓋安裝至 iPhone 14 Pro；未啟動 App 或相機，追蹤實拍仍待驗收。

2026-10-27（遮罩安全修正）：移除舊有「未鎖定時使用畫面中央橢圓」fallback。現在只有可信 106 點追蹤時才會套用臉部美顏，失去鎖定則淡出至原圖。GPU 回歸新增「預設非零美顏且無人臉時輸出必須等於原圖」檢查並通過；Simulator、signed iPhone build 均通過，已覆蓋安裝至 iPhone 14 Pro，未啟動 App 或相機。

2026-10-27（位置測試）：首頁新增「位置測試」按鈕及美顏面板的同名 toggle。它只顯示與 Metal shader 相同的追蹤橢圓，不改變相機影像；若無可信人臉鎖定，會顯示「目前不套用臉部美顏」。Simulator、signed iPhone build 均通過，已覆蓋安裝至 iPhone 14 Pro，未啟動 App 或相機。

2026-10-27（位置測試閘門修正）：移除頭姿角度額外閘門。此前 detector 顯示「人臉鎖定」時，角度條件仍可能清除美顏遮罩，導致位置測試錯報未鎖定；現在只要 tracker 有有效人臉即顯示並使用該範圍。

2026-10-27（遮罩座標修正）：遮罩中心與大小改直接取 IoU/EMA tracker 的 `rect`，不再由眼／嘴 keypoint 另行推算。位置測試橢圓因此與 tracker 的實際移動使用同一來源；真機仍需以此 overlay 目視驗收。

2026-10-27（低延遲追蹤）：完整 SCRFD 偵測改為每 6 幀校正一次；中間幀以 KLT optical flow 推進已鎖定 track 的 106 點、五點與人臉框。iOS detector input 由 480 降至 384、執行緒由 4 降至 3、單次只追蹤 1 張臉，並完全停用與美顏無關的年齡/性別模型。遠端引擎及 iOS build 通過；實拍延遲與品質仍待驗收。（2026-10-27 追加：`detect_interval` 由 6 降為 3。）

2026-10-27（preview/analysis 雙路徑）：人臉分析在 C++ 端先縮到最大邊 720，偵測結果再映回原始 camera buffer 座標；Metal preview 保持原尺寸。未啟用 mesh 微調時，preview 從兩個 Metal pass 減為單一 pass。遠端引擎、Simulator、GPU regression 與 signed iPhone build 通過，已覆蓋安裝；真機可見延遲與追蹤品質仍待驗收。

2026-10-27（快速移動 recovery）：KLT 沒有足夠有效點時，tracker 立即清除舊狀態並以**目前**最新畫面完整重偵測；偵測或光流未確認的 grace-period track 不得輸出到可見美顏，改為原圖直通。鏡頭/格式重設亦會清空 tracker。遠端引擎、Simulator 和 signed iPhone build 通過，已覆蓋安裝至 iPhone 14 Pro；極端快速移動下的實拍品質仍待驗收。

2026-10-27（幀序一致性）：相機 buffer 帶單調序號，FaceEngine 與 106 點 mesh 結果標記其來源幀序；`FaceState.apply(to:frameSequence:)` 在顯示幀超前分析幀 3 幀以上時視為過時（faceValid=0），快速移動時美顏不再用舊分析結果平移。離屏 GPU 回歸 7 項全 PASS。

2026-10-27（USB 串流）：新增 `StreamProtocol.swift`（PLNS v1）、`H264StreamEncoder.swift`（VideoToolbox RealTime、6 Mbps、Annex-B）與 `PlnsServer.swift`（loopback 127.0.0.1:8765、12 幀有界佇列、CONFIG 重播與 keyframe 優先）。`BeautyRenderer` 的 offscreen IOSurface buffer 同時供預覽及編碼，手機預覽與 USB 輸出同源。對應 macOS `receiver-macos/PhoneLensReceiver.swift` 使用原生 usbmuxd 解碼並顯示。真機→Mac 連續處理 4000+ 影格／100 MB+，逐段內容雜湊變動；**Mac 預覽的人眼即時性仍待使用者確認**，Windows 路徑未驗證。

執行實際 GPU 回歸測試（需要支援 Metal 的 Mac）：

```sh
xcrun swiftc ios/PhoneLens/BeautyParams.swift ios/PhoneLens/BeautyRenderer.swift ios/tests/BeautyTests.swift -o /tmp/phonelens-beauty-tests
/tmp/phonelens-beauty-tests
```

真機相機控制、畫面方向、前置鏡像、背景返回、4K/60fps 發熱及舊版 OS fallback 尚未驗收。USB 串流可在連接 sheet 手動啟動（手機監聽 loopback 8765，經 usbmux 轉送）；Mac receiver 有 console 連續資料證據，但桌面 virtual camera 註冊、OBS／Zoom 選用與使用者人眼預覽仍未驗收。

## 端到端驗收步驟（待執行）

1. iPhone 以 USB 線接 Mac（信任此電腦），開 PhoneLens → 開啟相機 → 「連接電腦」→「開始串流到電腦」。
2. Mac 執行 `receiver-macos/PhoneLensReceiver.swift` 編出的 `PhoneLensReceiver`（見下），應顯示美顏處理後的即時影像；視窗狀態列出 fps/kbps 與「收到 H.264 參數集」。
3. 拔線重插應自動重連（receiver 每 1s 重試；手機端重連後重播 CONFIG 並強送 keyframe）。

建置 receiver（零相依，不使用 brew/iproxy）：

```sh
cd receiver-macos
xcrun swiftc -O PhoneLensReceiver.swift -o /tmp/phonelens-recv/PhoneLensReceiver \
  -framework AVFoundation -framework AppKit -framework CoreMedia -framework CoreVideo -framework Foundation
```
