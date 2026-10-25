# iPhoneCam v2 — 開發交接文件（Handoff）

> 日期：2026-10-12｜狀態：功能完成、OBS 驗證通過，待實機驗收
> 交接對象：合作開發者｜先讀本文件，再讀 `AGENTS.md`（專案記憶）與 `SPEC-v3.md`（規格）

---

## 1. 專案一句話

手機鏡頭 → PC 虛擬攝影機：Android 手機擷取＋硬編碼經網路送到 PC，PC 解碼後同時做三件事——控制台預覽、寫入共享記憶體、經 Media Foundation 虛擬攝影機餵給 OBS／Discord／Teams。

## 2. 架構總覽

| 元件 | 技術 | 角色 | 關鍵檔案 |
|---|---|---|---|
| `AndroidSender/` | Kotlin＋Compose、Camera2、MediaCodec | 手機端：擷取＋硬編 H.264／HEVC；TCP 伺服器＋UDP 影像發送 | `core/StreamEngine.kt`、`MainActivity.kt` |
| `iPhoneCam.Net/` | C#、net10.0（無 UI 相依） | PC：協定／解碼（FFmpeg）／共享記憶體／統計 | `SharedFrame.cs`、`SharedConfig.cs`、`Cam1Protocol.cs` |
| `iPhoneCam.App/` | C#、WPF（.NET 10） | PC 控制台：裝置清單、預覽、參數、統計、深色玻璃 UI | `MainWindow.xaml(.cs)` |
| `iPhoneCam.Source/` | C#、Media Foundation COM DLL | 虛擬攝影機（`MFCreateVirtualCamera`＋`IMFMediaSource`，輸出 NV12） | `FrameGenerator.cs`、`MediaStream.cs`、`Shared.cs`、`Activator.cs` |

資料流：`手機 Camera2 → MediaCodec → TCP/UDP → PC Cam1Client → FfmpegDecoder → (a) WPF 預覽；(b) SharedFrame MMF → Source DLL → OBS`

## 3. 凍結常數（勿改，改了兩端一起壞）

- TCP 控制 **19300**（手機監聽、PC 連入）；UDP 信標 **19301**；UDP 影像 CUM1 **19302**
- CAM1 訊框：`[MAGIC "CAM1" 4B][型別 1B][tsUs 8B][len 4B]`；`0x01` 影像、`0x03` 控制
- CUM1 分片：`[0x43554D31][seq u32][tsUs u64][flags 1B][fragIdx u16][fragTotal u16][payload ≤1400B]`
- 共享記憶體：影格 `Global\iPhoneCam.Frame.v2`（**三重緩衝＋原子 writeIdx，無鎖**）、畫布 `Global\iPhoneCam.Config`
- 虛擬攝影機 CLSID：橫向 `{8136b935-e87f-4c31-9456-31eedfd84776}`、直向 `{7e5c1a20-9b34-4d61-8f22-3c6a9b0d1e54}`
- 畫布尺寸寫 `HKLM\SOFTWARE\iPhoneCam`（Source 跑在 SYSTEM 看不到 HKCU；App 有管理員 manifest 負責寫）
- 檔位（4:3 滿幅不裁切）：960×720／1440×1080／1920×1440／2880×2160；FPS 30／60；碼率 4／8／16／32 Mbps；2K 以上用 HEVC

## 4. 目前進度（2026-10-11 完成）

### 4.1 已完成 ✅

- **PC 端全面重寫**：`iPhoneCam.Net`（Cam1Protocol/Cam1Client/Cam1Server/BeaconListener/UdpVideoReceiver/FfmpegDecoder，移除舊 `H264Preview`）、`iPhoneCam.App`（深色＋Liquid Glass 玻璃 UI、可縮放無邊框主視窗、待機畫面、裝置/系統頁）；`dotnet build` 0 警告 0 錯誤
- **Android 端全面重寫為 Kotlin＋Compose**：Cam1／StreamEngine（Camera2＋硬編＋背景安全序列防閃退）／NetServer／SenderViewModel／MainActivity（Compose UI、預覽 transform 修正）；`assembleDebug` 成功
- **預覽系列 bug 修復**：預覽縮左上（CoverTextureView＋抵消 TextureView 拉伸）、portrait 鎖定、換檔閃退、CMOS 比例壓縮、PC 預覽旋轉固定 0°、預覽框比例＝輸入短邊:長邊
- **S21 多鏡頭**：依 facing＋等效焦距列舉（後超廣角 13mm／主 26mm／長焦 29mm 原廠鎖住標示未開放／前 26mm）；美顏等無用功能已移除
- **雙虛擬相機**：橫向＋直向各一個 CLSID；FPS／碼率檔；方向變就重建畫框
- **OBS 閃爍／條紋／卡住根因修復**（最大的一仗，`AGENTS.md` §11 有完整實錄）：
  單 buffer＋mutex → 三重緩衝無鎖；slot 索引錯位修正；allocator 實際 pitch 有 64-byte padding（1080→1088、1440→1472）→ `Lock2DSize` 查實際 pitch 逐列拷；交付 buffer 一律 packed；duration 改實測到達間隔
- **除錯知識已建成專案 skill**：`.opencode/skills/mf-virtualcam-debug/SKILL.md`（重開 opencode 後自動載入）

### 4.2 已驗證 ✅

- Android 模擬器（Pixel 7／Pixel 5）：預覽、換檔、切鏡頭正常
- PC App 啟動＋預覽正常（截圖確認）
- **OBS 橫向＋直向皆成功顯示**（10-11 當晚的最終驗收）

### 4.3 待辦 ⏳

1. **實機驗收**：真機（S21 系列）＋實體 PC 跑完整鏈路，確認 60fps／4K 檔位的發熱與碼率
2. Release APK 簽署（目前只有 `app-debug.apk`，`versionCode=2`、`versionName="2.0"`）
3. 發布用安裝流程（管理員 `register.bat`＋HKLM 寫入的打包方式未定）

## 5. 環境與建置

| 工具 | 版本 |
|---|---|
| .NET SDK | 10（含 WPF 工作負載），Target `net10.0-windows10.0.22621.0`，NuGet `DirectNCore 1.18.0` |
| JDK／Gradle | JDK 21、AGP 8.5.2、Gradle 8.7 |
| Android | `compileSdk/targetSdk 34`、`minSdk 26`、Compose BOM 2024.06.00、包名 `com.iphonecam.sender` |

```powershell
# PC（repo 根目錄，iPhoneCam.slnx）
dotnet build iPhoneCam.slnx          # Debug；Release 加 -c Release

# Android（AndroidSender/ 目錄）
.\gradlew.bat :app:assembleDebug     # 或 assembleRelease
```

產出物：

- PC 主程式：`iPhoneCam.App\bin\Debug\net10.0-windows10.0.22621.0\iPhoneCam.App.exe`（Release 同結構）
- 虛擬相機 DLL：`iPhoneCam.Source\bin\...\iPhoneCam.Source.dll`（附 `.comhost.dll`，COM hosting 用）
- 手機 APK：`AndroidSender\app\build\outputs\apk\debug\app-debug.apk`

## 6. 執行／測試流程（順序有講究）

1. **管理員 PowerShell**：`Stop-Service FrameServer -Force`（不然 DLL 被鎖住無法覆蓋），關掉舊 App
2. 註冊虛擬相機（新增 CLSID 或換機器時才需）：管理員執行 `iPhoneCam.Source/register.bat`（內含 `regsvr32`）
3. 啟動 `iPhoneCam.App.exe`（管理員，否則寫不了 HKLM 畫布）
4. 手機安裝 APK → 開 App → 選鏡頭／檔位 → 開始串流；PC 控制台連入（TCP 19300）
5. OBS：**刪除舊來源重加**（OBS 會快取舊格式）→ 選「iPhoneCam」橫向或直向

## 7. 維運地雷（先查再改，血淚換來的）

1. 交給下游的 buffer 一律 **packed（pitch＝寬）**，宣告與實際一致；**永不假設 allocator pitch＝寬**（實測 1080→1088、1440→1472）
2. 跨進程餵幀用多重緩衝＋原子索引，不用 mutex；斷訊才凍結上一幀
3. 手機／PC 跑 4:3 原生、CMOS 滿幅不裁切；方向不重啟編碼，PC 端轉正
4. session 失敗要能逐檔降（4K→2K→1080P→720P→30fps）；drain 執行緒防重入（`encGen`）
5. 診斷日誌：預覽 `C:\Temp\ipc-preview.log`、DLL `C:\Temp\ipcdll.log`（內含 `GEN`／`START`／`HB`／`2D pitch=` 診斷標籤，先看 log 再改 code）
6. PC 預覽正常＝上游沒問題，收斂到 DLL→OBS 交界即可（buffer 版面、宣告、時間戳三者之一）
7. 反編譯參考（僅本機）：PC `C:\Users\Bubbles\AppData\Local\Temp\opencode\wuta_decomp`、Android `...\wuta_android`、解包 `...\wuta_apk\ext2`

## 8. 參考文件

- `SPEC-v3.md`：產品規格（動手前先讀）
- `AGENTS.md`：專案記憶＋§11 虛擬相機除錯完整實錄
- `.opencode/skills/mf-virtualcam-debug/SKILL.md`：除錯 skill（精煉操作版）
- `README.md`：產品簡介
- 全域設計規範：`C:\Users\Bubbles\.config\opencode\AGENTS.md`（2026 起所有 UI 以 Apple Liquid Glass 為基礎——玻璃只用於導航層、膠囊控制項、同心圓角）
