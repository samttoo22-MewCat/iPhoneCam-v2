# iOS 相機與美顏原型

修改 iOS UI、相機、美顏或建置設定前，讀本目錄 `README.md` 的建置與驗證範圍。2026-10-26 已移植 Android `17c3e1a` 的三頁介面與配色，GPU shader 有像素測試，不再只是美顏預設；相機完整管線仍待真機驗收，串流與桌面輸出未接入。

原生 Liquid Glass API 保留 iOS 26 availability guard，較舊版本使用標準元件。相機設定與啟動在同一 serial queue 執行，先 `commitConfiguration()` 才 `startRunning()`。

2026-10-26 使用者重新授權安裝至實體 iPhone；已建置並安裝到 iPhone 14 Pro，本次不啟動 App 或相機。後續自動 UI 驗收仍使用本地 Device Hub Simulator，不使用 QuickTime／Mac 相機。Simulator 無相機是預期狀態，影像效果用 `tests/BeautyTests.swift` 測正式 Metal shader。美顏為固定橢圓遮罩，不宣稱人臉追蹤。禁止以 AX slider 值更新代替 App 數字／影像的讀回證據。

實作傳輸前先讀根目錄 `SPEC-v3.md`，遵守既有 CAM1/CUM1 規格。UI 模板建置或 Simulator 畫面不構成真機、USB、美顏或 virtual camera 驗收。
