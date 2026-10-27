# iOS 相機與美顏原型

修改 iOS UI、相機、美顏或建置設定前，讀本目錄 `README.md` 的建置與驗證範圍。2026-10-27 已有 iPhone 端美顏→H.264→USB/usbmuxd→macOS Receiver 的 console 證據（4000+ 影格／100 MB+／逐段內容雜湊變動）；人眼預覽、OBS 與系統虛擬攝影機仍未驗收。2026-10-26 已移植 Android `17c3e1a` 的三頁介面與配色，GPU shader 有像素測試，不再只是美顏預設。

原生 Liquid Glass API 保留 iOS 26 availability guard，較舊版本使用標準元件。相機設定與啟動在同一 serial queue 執行，先 `commitConfiguration()` 才 `startRunning()`。

2026-10-26 使用者重新授權安裝至實體 iPhone；已建置並安裝到 iPhone 14 Pro，本次不啟動 App 或相機。後續自動 UI 驗收仍使用本地 Device Hub Simulator，不使用 QuickTime／Mac 相機。Simulator 無相機是預期狀態，影像效果用 `tests/BeautyTests.swift` 測正式 Metal shader。美顏遮罩已由開源人臉引擎（SCRFD＋106 點＋IoU 追蹤，`PhoneLens/FaceEngine`）驅動：真機上遮罩跟隨鎖定人臉，沒有可信人臉時直通原圖；模擬器不連結引擎（顯示無相機）。預訓練 ONNX 權重為 InsightFace AntelopeV2，公開倉庫不追蹤，來源與限制見 `PhoneLens/FaceEngine/Models/README.md`。實拍跟蹤品質未驗收前不得宣稱完成。禁止以 AX slider 值更新代替 App 數字／影像的讀回證據。

實作傳輸前先讀根目錄 `SPEC-v3.md`，遵守既有 CAM1/CUM1 規格。UI 模板建置或 Simulator 畫面不構成真機、USB、美顏或 virtual camera 驗收。

2026-10-27 起手機端已實作 USB 串流（PLNS v1，手機 NWListener 監聽 127.0.0.1:8765，桌面經 usbmuxd 轉送；macOS receiver 為 `receiver-macos/PhoneLensReceiver.swift` 原生 usbmuxd client，Windows 需 iproxy）。協定語意以 Android `StreamProtocol.kt`／`UsbTunnelWriter.kt` 為正本；改佇列／重連行為時兩端同步。美顏輸出走 offscreen IOSurface pixel buffer，預覽與串流同源；修改 `BeautyRenderer.draw()` 時不可破壞此路徑與 `streamFrameSink` 的 GPU-completed 時機。連接 sheet 狀態須遵守 `ios-first-camera-ui-spec.md`：串流中不等於 virtual camera 已註冊，不得宣稱 cameraReady。
