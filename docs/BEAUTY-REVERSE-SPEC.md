# 無他相機（Wuta Camera）美顏系統逆向規格

> 樣本：`Wuta Camera 7.1.5.167`（APKPure，99.3 MB，arm64-v8a／armeabi-v7a）
> 分析日期：2026-10-12｜目的：作為 iPhoneCam 美顏模組的設計依據
> 結論先講：**美顏核心是不可移植的閉源二進位；但資料格式與參數系統完全可讀，足以自製等價模組。**

---

## 1. 架構真相

無他的美顏不是「一套自家演算法」，而是三層組合：

| 層 | 元件 | 性質 | 能否取用 |
|---|---|---|---|
| 人臉感知 | `libst_mobile.so`（5.76 MB）＋ `assets/sense/M_SenseME_*.model` | **商湯 SenseTime ST Mobile SDK**（商業授權、閉源） | ❌ 有 license 驗證，不可轉授權 |
| 影像處理 | `libwtcore.so`（10.54 MB） | 無他自製 C++ GL 框架（`znative::`＋`wuta::`），閉源 | ❌ 只有二進位 |
| 資料資產 | `assets/filter_res/`、`assets/*.ms`、`assets/postproc/` | 遮罩、LUT、位移圖、模型 | ✅ 格式可讀 |

### 1.1 商湯 SDK 的職責（`libst_mobile.so`，113 個 `st_*` 匯出）

人臉／人體**感知**，不含美顏：

- `st_mobile_human_action_detect`／`create_with_sub_models` → 人臉 240 點特徵＋動作
- `st_mobile_human_action_get_mesh_info` → Face Mesh
- `st_mobile_face_attribute_detect2` → 性別／年齡／膚色等屬性
- `st_mobile_human_action_get_segment_foreground`／`gpu_segment_refine` → 人像分割
- `st_mobile_tracker_animal_face_*` → 貓臉
- **授權機制（關鍵）**：`st_mobile_check_has_license`、`st_mobile_generate_activecode`、`st_mobile_get_license_expiredtime`

→ 授權綁 package name＋簽章，**把 .so 複製到別的 App 不會通過驗證**；且轉授權違反商業授權條款。

### 1.2 無他自製的 GL 框架（`libwtcore.so`，命名空間即架構）

```
znative::                      wuta::
├─ BaseFilter                  ├─ PostProcRender（主後處理）
│   ├─ TextureFilter           │   render(mode, scene, pipeline, ...)
│   ├─ SharpenFilter           │   applyHdrEffect / applyImageStyle
│   │   setStrength(f)          │   renderPreview / renderSave
│   │   setResolution(w,h)     ├─ RenderCtrller
│   ├─ BaseYuvFilter           │   setSlider(key, float)  ← 美顏參數入口
│   └─ RgbaToI420Filter        │   setParams / setComponent
│       setInputTexture        │   hintFaceContourSmooth
├─ Program / GLUtil            │   lockFramebufferByTexId
├─ GLCoord / GLRect            ├─ CamRenderFrame（fillYUV420888 / fillTexture）
├─ GLFastReader                ├─ TextureRender::render(...)
└─ core_jni_glPassMainFilter   └─ GLUtils（loadShader/createProgram/FBO）
```

- 全域物件：`_ZN4wuta14_sharpenFilterE`（銳化）、`_ZN4wuta10_sharpenFbE`
- JNI 入口：`core_jni_glPassMainFilter`
- 動態註冊（`RegisterNatives`，JNI 類別路徑 `com/benqu/nativ/core/`）

**管線（由符號與資產推斷）**：

```
Camera2 (YUV/OES)
  → CamRenderFrame.fill / fillYUV420888        （上傳紋理）
  → 臉部偵測（商湯 240 點）
  → BaseFilter 串接：
       磨皮 blur（ROI 遮罩加權）
       銳化 SharpenFilter（ROI 限定）
       膚色 3D LUT
       妝容疊合（blend/screen/overlay + mask）
       變形（位移圖／特徵點 warp）
  → PostProcRender.render(...)                  （合成／色調／HDR）
  → RgbaToI420Filter                            （轉 NV12/I420 給編碼器）
  → MediaCodec
```

### 1.3 shader 現況

- **明文可見**：通用頂點 shader、`rgba_factor`/`rgba_offset` 線性調色、YUV420 打包、`alpha` 疊合、以及完整的混合函式庫
  （`blend`／`screen`／`lighten`／`hardLight`／`overlay`／`insideBox`／`getPin0..N`）
- **不可見**：美顏主體（磨皮／變形）shader 未以明文存在 `.so`，推測加密或由伺服器下發
- 片段證據：`lowp vec4 result = sharpen(uv, getPin0(uv), strength);`（dex 內明文）

---

## 2. 參數系統（`RenderCtrller::setSlider(key, float)`）

從 dex 抽出的**完整 key 表**，即無他美顏的 API 規格。`a_*` 為漢語拼音命名，`cos_*` 為妝容。

### 2.1 膚質（不需特徵點，純濾鏡）

| key | 意義 | 實作方式 |
|---|---|---|
| `blur_skin` / `smooth_skin` | 磨皮 | 保邊模糊（bilateral／guided）＋ROI 遮罩 |
| `blur_args` / `blur_box` | 模糊強度/半徑 | uniform |
| `white` / `face_color` | 美白／膚色 | 3D LUT（`face_color/lookup_table*.png`） |
| `white_teeth` | 美白牙齒 | 唇齒 ROI＋LUT |
| `remove_freckle` / `remove_spots_acne` | 祛斑／去痘 | `freckle_roi/freckleROI.png` 遮罩＋中值 |
| `skin` / `skinseg` | 皮膚分割 | `skinseg/EmptyskinMask.png` |
| `hdr` | HDR | `hdr/hdr.bin`（713 KB，加密） |
| `face_lift` | 拉提 | 位移 |

### 2.2 臉型（需特徵點＋位移圖）

| key | 意義 |
|---|---|
| `a_smallface` / `a_xiaolian` | 小臉 |
| `a_shoulian` | 瘦臉 |
| `thin_face` | 瘦臉 |
| `a_xiaotou` | 小頭 |
| `a_toubaolian` | 頭部變形（`toubaolian/TBLOffsetMap.png` 500×500） |
| `a_contoursmooth` / `contour_smooth` | 輪廓平滑 |
| `a_xiaba` | 下巴 |
| `a_xiahexian` | 下顎線（`jawline/sucai*.jpg`） |
| `a_quangu` | 顴骨 |
| `a_facetheme` | 臉型主題 |
| `face_reshape` / `face_boarder` | 臉型重塑／臉部邊界 |
| `a_falingwen` | 法令紋 |

### 2.3 五官

| key | 意義 |
|---|---|
| `big_eye` / `a_dayan` | 大眼 |
| `eye_angle` / `eye_dist` | 眼角／眼距 |
| `eye_bright` / `a_liangyan` | 亮眼 |
| `a_yandai` / `pouch` | 眼袋（`removepouch/standardEyePouchROI1.png`） |
| `a_yanjiao` / `a_yanju` | 眼角／眼距 |
| `a_shuangyanpi_new` | 雙眼皮 |
| `a_meitong_new` | 美瞳 |
| `thin_nose` / `thin_nose_body` / `a_shoubi` | 瘦鼻 |
| `a_changbi` / `a_longbi` | 長鼻 |
| `a_shangen` | 山根 |
| `a_biyi` | 鼻翼 |
| `nose_3d` | 鼻 3D（`nose_3d/pyVal.dat` 128 KB uint16） |
| `a_renzhong` | 人中 |
| `a_zuixing` | 嘴型 |
| `lip_reshape` | 唇形（`lip_reshape/fengchunSucai.png`） |
| `a_duduchun` | 嘟嘟唇 |
| `a_falin` / `falin` | 髮際（`falin/standardFalinROI.png`） |

### 2.4 妝容（`cos_*`，口罩＋混合模式）

| key | 意義 | 資產 |
|---|---|---|
| `cos_eyebrow` / `a_meimao_new` | 眉 | `blureyebrow/standardEyebrowROI.png`、`GifEyebrow` |
| `cos_eyelash` / `a_jiemao_new` | 睫毛 | `GifEyebrowReplace` |
| `cos_eyelid` | 眼瞼 | — |
| `cos_eyeline` / `a_yanxian_new` | 眼線 | — |
| `cos_eyeshadow` / `a_yanying_new` | 眼影 | `eyeshadow/ESmask.png`、`ESmask512.png` |
| `cos_blusher` / `a_saihong_new` | 腮紅 | `cosmetic/blusher/blusherMask.png` |
| `cos_lip` / `a_kouhong_new` | 口紅 | `lip/lipMask{Hard,Medium,Soft,YC}.png` |
| `cos_mole` | 痣 | — |
| `cos_shadow_mask` / `a_xiurong_new` | 修容 | `shadowmask/shadowMask.png` |
| `a_meiya` | 美牙 | — |
| `a_yanzhuang` | 眼妝（組合） | — |
| `beauty_effect` / `beautypreset` | 一鍵美顏預設 | `Preset_beauty` |

### 2.5 濾鏡／風格

- `imagestyle/*`（13 種：abao／charm／elegant／fandel／floral／iris／juicy／mystical／peach／pomelo／rococo／snowy／summer／sweet）
- `postproc/colors.txt`：48 個 ARGB 色票（調色盤 UI）
- `face_color/lookup_table*`：5 組膚色 LUT（預設／MAN／MY／QY／gray）

---

## 3. 資料資產格式（可直接沿用設計）

| 資產 | 尺寸／格式 | 用途 | 解讀 |
|---|---|---|---|
| `face_color/lookup_table.png` | **64×64 RGBA** | 膚色 | **8×8×8 3D LUT**（標準 Android GPUImage 佈局：512 像素排 8×8 格） |
| `lookup_table_gray.png` | 256×1 RGB | 灰階曲線 | 1D LUT |
| `face_roi/faceSmoothROI.png` | 512×512 RGBA | 磨皮遮罩 | 臉框歸一化 ROI |
| `faceSmoothMoreROI.png` | 512×512 | 強磨皮遮罩 | 同上（分級） |
| `faceSharpenROI.png` | 512×512 | 銳化遮罩 | 只銳化臉，避開背景 |
| `faceBoarder.png` | — | 臉部邊界 | 防溢出 |
| `toubaolian/TBLOffsetMap.png` | **500×500 RGB** | 頭部變形 | 位移圖（R/G = dx/dy） |
| `nose_3d/pyVal.dat` | 131072 B | 鼻 3D | **uint16 陣列**（0,1,2,3… 遞增索引） |
| `hdr/hdr.bin` | 713664 B | HDR | 高熵（加密／壓縮） |
| `angle.ms`／`corner.ms`／`detect.ms` | MSL2 magic | 自製模型 | detect 679 KB／corner 380 KB／angle 126 KB |
| `sense/M_SenseME_*.model` | 1.5–2.1 MB | 商湯模型 | Face_Video／Face_Extra／Attribute／Iris／Segment_Figure／CatFace |

---

## 4. 對 iPhoneCam 的落地設計

### 4.1 不可做的事（法律與技術紅線）

1. **不可** bundle `libst_mobile.so`＋模型：license 綁 package／簽章，且轉授權違法。
2. **不可** bundle `libwtcore.so`：無授權、無符號、ABI 綁定。
3. **不可** 複製 `filter_res` 資產：美術資源受著作權保護（遮罩／LUT 屬視聽作品衍生）。

→ 但**架構、參數分類、資料格式、管線順序**屬技術思想，可自由參考實作。

### 4.2 自製模組架構（`BeautyEngine`）

```
Camera2
  → SurfaceTexture (OES tex)
  → [BeautyEngine] GL 執行緒
        ├─ 上傳 OES → RGBA（FBO A）
        ├─ 人臉偵測：MediaPipe Face Mesh（Apache-2.0，468 點）
        ├─ 磨皮：保邊模糊（雙邊／引導濾波）+ 自製臉部 ROI 權重
        ├─ 美白：自製 8×8×8 3D LUT（可換風格）
        ├─ 銳化：unsharp mask，臉部權重
        ├─ 變形（第二階段）：特徵點位移 warp（大眼／瘦臉／瘦鼻）
        └─ 輸出雙目標：預覽 Surface ＋ MediaCodec input Surface
  → MediaCodec
```

**關鍵設計決定**：

- **GL 路徑為選配**：`beautyEnabled=false` 時完全走現有 zero-copy 直通（保護已驗證的穩定性）。
- **參數模型對齊無他 key**：`BeautyParams.blurSkin`、`white`、`bigEye`…，方便未來對照與 UI 文案。
- **不做妝容**（第一階段）：需要美術資產，且 ROI 對位要求高。
- **人臉偵測降頻**：每 2–3 幀偵測一次，其餘幀沿用上次特徵點（省電、穩 60fps）。

### 4.3 分階段交付

| 階段 | 內容 | 依賴 | 風險 |
|---|---|---|---|
| P0 | 逆向規格（本文件） | — | — |
| P1 | GL 管線骨架＋磨皮／美白／銳化（免特徵點） | 無 | 中（動到串流路徑） |
| P2 | MediaPipe 特徵點＋大眼／瘦臉／瘦鼻 | MediaPipe Tasks Vision | 中高（+20 MB、延遲） |
| P3 | 妝容（腮紅／唇／眼影） | 自製遮罩資產 | 高（美術＋對位） |

---

## 5. 佐證清單（可重現）

- 匯出符號：`libst_mobile.so` 113 個 `st_*`；`libwtcore.so` 1329 個 FUNC
- dex 字串：454,706 條唯一字串；參數 key 491 條（本文件 §2）
- 資產：`assets/filter_res/` 54 檔、`assets/sense/` 6 個模型
- 分析腳本暫存：`C:\Users\Bubbles\AppData\Local\Temp\opencode\wuta_re\*.py`

---

## 6. PC 端（wuta_vcam 1.5.2.6）逆向結果

> 路徑：`C:\Program Files (x86)\wuta_vcam`｜.NET Framework 4.6.2（managed，IL 可讀）

### 6.1 架構

| 元件 | 角色 |
|---|---|
| `wuta_vcam.exe`（5.13 MB, .NET） | 控制台＋渲染管線 |
| `1080p/`, `720p/` 各 4 個 DLL | **DirectShow** 虛擬攝影機（`wuta_vcam(64)`、`wuta_vcam_vertical(64)`） |
| `wuta_native.dll` | native 核心 |
| `OpenTK.dll` / `OpenTK.GLControl.dll` | **OpenGL 渲染** |
| `wt_opencv_dll.dll`（12.64 MB） | OpenCV |
| `avcodec-57` / `swscale-4` / `libyuv_internal` | H.264 解碼＋色彩轉換 |
| `wtimobiledevice-net.dll` | iOS 裝置（libimobiledevice） |
| `for_android/wuta_adb.exe` | Android 透過 adb |
| `default*.yuv` | 待機畫面（預先轉好的 YUV） |

### 6.2 渲染管線（C# 類別名直讀）

```
wuta_vcam.RenderManager
 ├─ wuta_vcam.opengl.YuvFilter      YUV420 → RGB（BT.601 mat3）
 ├─ wuta_vcam.opengl.TexFilter      紋理處理
 ├─ wuta_vcam.opengl.SharpenFilter  5-tap unsharp mask
 └─ wuta_vcam.opengl.GLProgram / GLUtils / GLDisplayView
```

**關鍵結論：PC 端只有銳化（SharpenFilter），沒有美顏。** 美顏在手機端做完才編碼傳送。
（`SharpenFilter` 的完整 GLSL 已取得：頂點算 5 個鄰居座標，片段做
`center*(1+4k) - (left+right+top+bottom)*k`。）

### 6.3 對本專案的決策

- 照無他：**美顏留在手機端**（預覽所見即所得），PC 端未來可加銳化。
- 我們的實作優於它：SurfaceView＋**零 FBO、單 pass、OES 直通**（PC 端它是 3 紋理＋多 pass）。
