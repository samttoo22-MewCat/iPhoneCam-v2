# 預訓練模型

這個目錄含人臉流程使用的檔名與本專案生成的 ROI PNG。

目前 FaceEngine 使用下列權重：

- det_10g.onnx
- 2d106det.onnx
- genderage.onnx（目前流程不會載入）

本機使用的三個 ONNX 檔案，SHA-256 分別為：

- det_10g.onnx：5838f7fe053675b1c7a08b633df49e7af5495cee0493c7dcf6697200b85b5b91
- 2d106det.onnx：f001b856447c413801ef5c42091ed0cd516fcd21f2d6b79635b1e733a7109dbf
- genderage.onnx：4fde69b1c810857b88c64a335084f1c3fe8f01246c9a191b48c7bb756d6652fb

這些雜湊對應 InsightFace AntelopeV2 模型套件。重構的 iOS/C++ 整合程式與模型權重是不同來源：InsightFace 程式碼採 MIT，但官方把公開預訓練模型列為非商業研究用途。產品發布或重新散布權重前，必須確認模型本身的條款與商用授權：<https://github.com/deepinsight/insightface#license>。

因此公開專案不追蹤這三個 ONNX 檔案，Xcode project 也不會自動把它們打包。具有相容授權時，把檔案放回本目錄並在 Xcode 將它們加入 PhoneLens target 的 Copy Bundle Resources；缺少權重時 App 會顯示人臉引擎載入錯誤，不會對畫面套用臉部效果。
