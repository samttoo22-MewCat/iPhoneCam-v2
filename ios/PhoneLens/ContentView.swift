import SwiftUI

private enum Palette {
    static let bg = Color(red: 13/255, green: 13/255, blue: 36/255)
    static let panel = Color(red: 18/255, green: 18/255, blue: 42/255)
    static let line = Color(red: 42/255, green: 42/255, blue: 74/255)
    static let muted = Color(red: 154/255, green: 163/255, blue: 192/255)
    static let cyan = Color(red: 53/255, green: 214/255, blue: 255/255)
    static let pink = Color(red: 255/255, green: 95/255, blue: 210/255)
    static let purple = Color(red: 139/255, green: 92/255, blue: 246/255)
    static let neon = LinearGradient(colors: [cyan, purple, pink], startPoint: .leading, endPoint: .trailing)
}

struct ContentView: View {
    @EnvironmentObject private var camera: CameraController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var page = 0
    @State private var beauty = false
    @State private var connection = false
    @State private var renderer: BeautyRenderer?
    @State private var renderError: String?
    @State private var showingMaskTest = false
    @State private var debugFaceMask: FaceMask?
    @State private var debugTrackerRect: CGRect?
    @State private var debugBufferSize = CGSize.zero
    @State private var debugUpdateSequence = 0
    @State private var frameSinkCount = 0
    @StateObject private var streamServer = StreamServer()

    fileprivate struct FaceMask: Equatable {
        let cx: Float
        let cy: Float
        let rx: Float
        let ry: Float
    }

    private var effectiveBeauty: BeautyParams {
        var result = camera.beauty
        if camera.comparing { result.enabled = false }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch page {
                case 1: settings
                case 2: help
                default: home
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.bg.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            navigation.opacity(beauty || connection ? 0 : 1)
                .accessibilityHidden(beauty || connection)
        }
        .preferredColorScheme(.dark)
        .tint(Palette.cyan)
        .sensoryFeedback(.selection, trigger: page)
        .sensoryFeedback(.selection, trigger: beauty)
        .sensoryFeedback(.selection, trigger: connection)
        .sensoryFeedback(.selection, trigger: camera.comparing)
        .task {
            guard renderer == nil else { return }
            do {
                let newRenderer = try BeautyRenderer(frames: camera.frames)
                camera.faceSink = { anchor in
                    DispatchQueue.main.async {
                        if let v = anchor {
                            debugFaceMask = FaceMask(cx: v.cx, cy: v.cy, rx: v.rx, ry: v.ry)
                        } else {
                            debugFaceMask = nil
                        }
                    }
                    if let v = anchor {
                        newRenderer.faceState.update(valid: v.valid, cx: v.cx, cy: v.cy,
                                                     rx: v.rx, ry: v.ry, sequence: v.sequence)
                    } else {
                        newRenderer.faceState.updateLost()
                    }
                }
                camera.faceMeshSink = { points, width, height, sequence in
                    newRenderer.faceState.updateMesh(points, width: width, height: height,
                                                     sequence: sequence)
                }
                camera.faceDebugSink = { rect, width, height, sequence in
                    DispatchQueue.main.async {
                        debugTrackerRect = rect
                        debugBufferSize = CGSize(width: width, height: height)
                        debugUpdateSequence = sequence
                    }
                }
                newRenderer.streamFrameSink = { buffer, _ in
                    streamServer.deliverFrame(buffer)
                }
                camera.frameSink = { buffer, sequence in
                    guard streamServer.isStreaming else { return }
                    frameSinkCount += 1
                    newRenderer.renderForStream(buffer, sequence: sequence)
                }
                renderer = newRenderer
                if ProcessInfo.processInfo.arguments.contains("--autostream") {
                    streamServer.start()
                }
            } catch { renderError = error.localizedDescription }
        }
        .onChange(of: scenePhase) { _, phase in camera.setActive(phase == .active) }
        .onChange(of: streamServer.isStreaming) { _, streaming in
            UIApplication.shared.isIdleTimerDisabled = streaming
        }
        .sheet(isPresented: $beauty, onDismiss: { camera.comparing = false }) {
            ScrollView {
                VStack(spacing: 16) {
                    HStack {
                        Text("自然美顏").font(.title2.bold())
                        Spacer()
                        Button("完成") { beauty = false }.modifier(NativeGlassButton())
                    }
                    beautyControls
                    Text("預覽在手機端即時處理；開始 USB 串流後才會傳送美顏畫面。")
                        .font(.footnote).foregroundStyle(Palette.muted)
                }.padding(20)
            }
            .presentationDetents([.height(520), .large])
            .presentationDragIndicator(.visible)
            .tint(Palette.cyan)
        }
        .sheet(isPresented: $connection) {
            connectSheet
        }
    }

    private var connectSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("連接電腦").font(.title2.bold())
                Spacer()
                Button("完成") { connection = false }.modifier(NativeGlassButton())
            }
            HStack(spacing: 10) {
                Image(systemName: streamServer.clientConnected ? "checkmark.circle.fill" : "desktopcomputer")
                    .foregroundStyle(streamServer.clientConnected ? Color.green : Palette.cyan)
                Text(streamServer.stateText)
                    .font(.subheadline.weight(.medium))
            }
            if streamServer.clientConnected {
                Text("串流 \(streamServer.sentFPS) fps · \(streamServer.sentKbps) kbps")
                    .font(.caption.monospacedDigit()).foregroundStyle(Palette.muted)
                Text("GPU \(streamServer.renderedFPS) fps · H.264 \(streamServer.encoderPackets) 封包")
                    .font(.caption2.monospacedDigit()).foregroundStyle(Palette.muted)
            }
            if let error = streamServer.lastError {
                Text(error).font(.footnote).foregroundStyle(Palette.pink)
            }
            if camera.status.contains("模擬器") {
                Text("模擬器沒有相機，無法串流影像。").font(.footnote).foregroundStyle(Palette.muted)
            }
            Button {
                if streamServer.clientConnected || streamServer.stateText.contains("監聽") {
                    streamServer.stop()
                } else {
                    streamServer.start()
                }
            } label: {
                Label(streamServer.stateText.contains("監聽") || streamServer.clientConnected
                        ? "停止串流" : "開始串流到電腦",
                      systemImage: streamServer.stateText.contains("監聽") || streamServer.clientConnected
                        ? "stop.circle" : "play.circle")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .modifier(NativeGlassButton(prominent: true))
            .disabled(camera.status.contains("模擬器"))
            VStack(alignment: .leading, spacing: 8) {
                Text("電腦端設定").font(.subheadline.weight(.semibold))
                Text("1. 用 USB 線連接 iPhone 與電腦。")
                Text("2. macOS：啟動 PhoneLensReceiver（自動透過 usbmux 轉送）。")
                Text("3. Windows：先執行 iproxy 8765 8765，再按 USB 監聽。")
                Text("影像以美顏處理後的 H.264 經 PLNS 傳至 Mac Receiver 預覽；系統虛擬攝影機仍待啟用。")
                    .font(.footnote).foregroundStyle(Palette.muted)
            }
            .font(.footnote)
            .foregroundStyle(Palette.muted)
            Spacer()
        }
        .padding(24)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .tint(Palette.cyan)
        .onDisappear { streamServer.stop() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "video.fill").foregroundStyle(Palette.neon)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("泡泡直播助手").font(.headline).foregroundStyle(Palette.pink)
                Text("PHONE LENS · iPhone").font(.caption2).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 4)
            Button { connection = true } label: {
                Label(streamServer.clientConnected ? "串流中" : "連接電腦",
                      systemImage: streamServer.clientConnected ? "desktopcomputer" : "desktopcomputer.and.arrow.down")
                    .font(.caption.weight(.medium))
                    .frame(minHeight: 32)
            }
            .modifier(NativeGlassButton())
            .accessibilityLabel(streamServer.clientConnected
                    ? "連線與輸出設定，正在串流到電腦" : "連接電腦")
        }.padding(.horizontal, 18).padding(.vertical, 10)
            .accessibilityIdentifier("appHeader")
    }

    private var home: some View {
        VStack(spacing: 12) {
            GeometryReader { geometry in
                let width = min(geometry.size.width, geometry.size.height * camera.aspect)
                preview
                    .frame(width: max(1, width), height: max(1, width / camera.aspect))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minHeight: 180)
            NativeGlassGroup {
                HStack(spacing: 12) {
                    Button { beauty = true } label: {
                        Label("美顏", systemImage: "sparkles").frame(maxWidth: .infinity, minHeight: 32)
                    }.modifier(NativeGlassButton())
                    Button { camera.comparing.toggle() } label: {
                        Label(camera.comparing ? "返回美顏" : "對比原圖", systemImage: "circle.lefthalf.filled")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }.modifier(NativeGlassButton())
                    Button { showingMaskTest.toggle() } label: {
                        Label(showingMaskTest ? "隱藏位置" : "位置測試",
                              systemImage: showingMaskTest ? "viewfinder" : "viewfinder.circle")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }.modifier(NativeGlassButton())
                }
            }.opacity(beauty || connection ? 0 : 1)
                .accessibilityHidden(beauty || connection)
            Button { camera.togglePreview() } label: {
                Label(camera.isRunning ? "暫停預覽" : "開啟預覽",
                      systemImage: camera.isRunning ? "pause.fill" : "play.fill")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
            }
            .tint(Palette.purple)
            .modifier(NativeGlassButton(prominent: true))
            .disabled(!camera.isConfigured || camera.busy || renderError != nil)
            .opacity(beauty || connection ? 0 : 1)
            .accessibilityHidden(beauty || connection)
        }.padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 8)
    }

    private var preview: some View {
        ZStack {
            if let renderer, camera.isRunning {
                CameraPreview(renderer: renderer, params: effectiveBeauty, running: camera.isRunning)
            } else {
                LinearGradient(colors: [Palette.bg, Palette.panel], startPoint: .top, endPoint: .bottom)
                VStack(spacing: 14) {
                    Image(systemName: camera.permissionDenied ? "camera.badge.ellipsis" : "video")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(Palette.cyan)
                        .padding(22).background(Palette.cyan.opacity(0.08), in: Circle())
                        .overlay(Circle().stroke(Palette.neon, lineWidth: 1))
                    Text(renderError ?? camera.status).font(.callout).multilineTextAlignment(.center)
                    if camera.permissionDenied {
                        Button("開啟系統設定") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }.modifier(NativeGlassButton())
                    }
                }.padding(20)
            }
            VStack {
                HStack {
                    Text(!camera.isRunning ? "預覽未啟動" : (camera.comparing || !camera.beauty.enabled ? "原始畫面" : "GPU 美顏"))
                        .foregroundStyle(Palette.cyan)
                    Spacer()
                    Text("\(camera.fps) FPS 設定")
                }
                Spacer()
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(camera.dimensions) · 取樣 \(camera.measuredFPS) FPS")
                        .monospacedDigit()
                    if camera.isRunning {
                        Text(camera.faceStatus).foregroundStyle(Palette.pink)
                    }
                    Text(camera.status).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption2.weight(.medium))
            .padding(10)
            .background(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.65)],
                               startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
            .allowsHitTesting(false)
            if showingMaskTest {
                FaceMaskOverlay(mask: debugFaceMask, trackerRect: debugTrackerRect,
                                bufferSize: debugBufferSize, sequence: debugUpdateSequence)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.cyan.opacity(0.8), lineWidth: 1))
        .accessibilityIdentifier("cameraPreview")
    }

    private var settings: some View {
        ScrollView {
            VStack(spacing: 14) {
                card("相機設定") {
                    LabeledContent("鏡頭切換") {
                        if camera.lenses.isEmpty { Text("無可用鏡頭").foregroundStyle(Palette.muted) }
                        else {
                            Picker("鏡頭切換", selection: Binding(get: { camera.lensID }, set: { camera.select(lens: $0) })) {
                                ForEach(camera.lenses) { Text($0.name).tag($0.id) }
                            }.labelsHidden().disabled(camera.busy || !camera.isConfigured)
                        }
                    }
                    .frame(minHeight: 44)
                    LabeledContent("解析度檔位") {
                        Picker("解析度檔位", selection: Binding(get: { camera.quality }, set: { camera.select(quality: $0) })) {
                            Text("720p").tag(720)
                            Text("1080p").tag(1080)
                            Text("2K").tag(1440)
                            Text("4K").tag(2160)
                        }.labelsHidden().disabled(camera.busy || !camera.isConfigured)
                    }.frame(minHeight: 44)
                    LabeledContent("相機 FPS") {
                        Picker("相機 FPS", selection: Binding(get: { camera.fps }, set: { camera.select(fps: $0) })) {
                            Text("30 FPS").tag(30)
                            Text("60 FPS").tag(60)
                        }.labelsHidden().disabled(camera.busy || !camera.isConfigured)
                    }.frame(minHeight: 44)
                    Text("實際擷取：\(camera.dimensions) · \(camera.fps) FPS\n依鏡頭支援選擇最接近的 4:3 尺寸。")
                        .font(.footnote).foregroundStyle(Palette.muted)
                }
                if camera.busy { ProgressView("正在套用相機設定…") }
                Text(camera.status).font(.footnote).foregroundStyle(Palette.muted)
                card("美顏") { beautyControls }
                card("桌面輸出") {
                    Text("碼率與直播尚未啟用").font(.subheadline)
                    Button("查看連線說明") { connection = true }.modifier(NativeGlassButton())
                }
            }.padding(14)
        }
    }

    private var beautyControls: some View {
        VStack(spacing: 6) {
            Toggle("GPU 美顏", isOn: $camera.beauty.enabled)
                .font(.headline).padding(.bottom, 6)
            beautySlider("磨皮", value: $camera.beauty.smooth)
            beautySlider("美白", value: $camera.beauty.white)
            beautySlider("清晰", value: $camera.beauty.sharpen)
            beautySlider("紅潤", value: $camera.beauty.pink)
            beautySlider("補光", value: $camera.beauty.fill)
            Toggle("顯示美顏位置測試", isOn: $showingMaskTest)
                .font(.subheadline)
                .padding(.vertical, 4)
            Divider().padding(.vertical, 4)
            Text("臉部微調").font(.subheadline.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(Array(BeautyParams.reshapePresets.enumerated()), id: \.offset) { _, preset in
                        Button(preset.name) { camera.beauty.reshape = preset.values }
                            .modifier(NativeGlassButton())
                            .disabled(!camera.beauty.enabled)
                    }
                    Button("清除") { camera.beauty.reshape = [Float](repeating: 0, count: 20) }
                        .modifier(NativeGlassButton())
                        .disabled(!camera.beauty.enabled)
                }.padding(.vertical, 2)
            }
            ForEach(BeautyParams.reshapeControls, id: \.slot) { control in
                beautySlider(control.name, value: reshapeBinding(control.slot))
            }
            Text("開源人臉引擎（SCRFD 偵測＋106 點＋IoU 追蹤）跟隨鎖定人臉；沒有可信人臉時不套用臉部美顏。清晰度也會影響背景。")
                .font(.caption).foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            HStack {
                Button("重設") { camera.beauty = BeautyParams(); camera.comparing = false }
                Spacer()
                Button(camera.comparing ? "返回美顏" : "對比原圖") { camera.comparing.toggle() }
            }.modifier(NativeGlassButton()).frame(minHeight: 44)
        }
    }

    private func beautySlider(_ label: String, value: Binding<Float>) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.subheadline).frame(width: 36, alignment: .leading)
            Slider(value: value, in: 0...1)
                .accessibilityLabel(label)
                .accessibilityValue("\(Int(value.wrappedValue * 100))")
                .disabled(!camera.beauty.enabled)
            Text("\(Int(value.wrappedValue * 100))").font(.caption.monospacedDigit())
                .frame(width: 28, alignment: .trailing)
        }.frame(minHeight: 44)
    }

    private func reshapeBinding(_ slot: Int) -> Binding<Float> {
        Binding(get: { camera.beauty.reshape.indices.contains(slot) ? camera.beauty.reshape[slot] : 0 },
                set: { value in
                    guard camera.beauty.reshape.indices.contains(slot) else { return }
                    camera.beauty.reshape[slot] = value
                })
    }

    private var help: some View {
        ScrollView {
            VStack(spacing: 14) {
                card("使用方式") {
                    Text("1. 允許相機權限，首頁顯示即時預覽。\n2. 到「設定」選鏡頭、畫質與 FPS。\n3. 開啟「美顏」即時調整，使用「對比原圖」比較。\n4. 離開 App 會暫停相機，返回後恢復。")
                        .font(.callout).lineSpacing(8)
                }
                card("本版範圍") {
                    Text("保留 iOS 原生 Liquid Glass、系統面板與觸覺回饋。人臉偵測與美顏都在手機上處理，不上傳影像。")
                    Text("尚無 USB／Wi-Fi 串流、錄影或桌面虛擬攝影機輸出。")
                        .foregroundStyle(Palette.muted)
                }
            }.padding(14)
        }
    }

    private func card<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.subheadline.bold()).foregroundStyle(Palette.pink)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line, lineWidth: 1))
    }

    private var navigation: some View {
        NativeGlassGroup {
            HStack(spacing: 8) {
                navItem("首頁", icon: "house.fill", index: 0)
                navItem("設定", icon: "slider.horizontal.3", index: 1)
                navItem("幫助", icon: "info.circle", index: 2)
            }
        }.padding(.horizontal, 14).padding(.vertical, 8)
            .background(Palette.bg)
    }

    private func navItem(_ name: String, icon: String, index: Int) -> some View {
        Button { page = index; camera.comparing = false } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 18))
                Text(name).font(.caption)
            }.frame(maxWidth: .infinity, minHeight: 44)
        }.tint(page == index ? Palette.pink : Palette.muted)
            .modifier(NativeGlassButton(prominent: page == index))
            .accessibilityAddTraits(page == index ? .isSelected : [])
    }
}

/// Visualizes the exact normalized ellipse that the Metal shader receives.
/// It is intentionally an overlay only and never changes the camera texture.
private struct FaceMaskOverlay: View {
    let mask: ContentView.FaceMask?
    let trackerRect: CGRect?
    let bufferSize: CGSize
    let sequence: Int

    var body: some View {
        GeometryReader { geometry in
            if let mask {
                if let trackerRect, bufferSize.width > 0, bufferSize.height > 0 {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Palette.pink, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                        .frame(width: trackerRect.width / bufferSize.width * geometry.size.width,
                               height: trackerRect.height / bufferSize.height * geometry.size.height)
                        .position(x: trackerRect.midX / bufferSize.width * geometry.size.width,
                                  y: trackerRect.midY / bufferSize.height * geometry.size.height)
                }
                Ellipse()
                    .stroke(Palette.cyan, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .background(Ellipse().fill(Palette.cyan.opacity(0.10)))
                    .frame(width: CGFloat(mask.rx) * geometry.size.width * 2,
                           height: CGFloat(mask.ry) * geometry.size.height * 2)
                    .position(x: CGFloat(mask.cx) * geometry.size.width,
                              y: CGFloat(mask.cy) * geometry.size.height)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("青：美顏範圍 / 粉：tracker 框")
                            Text(String(format: "#%d  uv %.3f, %.3f  r %.3f, %.3f",
                                        sequence, mask.cx, mask.cy, mask.rx, mask.ry))
                            if let trackerRect {
                                Text(String(format: "px %.0f,%.0f %.0fx%.0f / %.0fx%.0f",
                                            trackerRect.origin.x, trackerRect.origin.y,
                                            trackerRect.width, trackerRect.height,
                                            bufferSize.width, bufferSize.height))
                            }
                        }
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .background(Palette.cyan.opacity(0.85), in: Capsule())
                            .foregroundStyle(Palette.bg)
                            .offset(x: 8, y: 8)
                    }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "face.dashed")
                    Text("尚未鎖定人臉\n目前不套用臉部美顏")
                        .multilineTextAlignment(.center)
                }
                .font(.caption.bold())
                .foregroundStyle(Palette.pink)
                .padding(12)
                .background(.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityIdentifier("faceMaskTestOverlay")
    }
}

// Native materials preserve system accessibility and iOS 17–25 fallbacks.
private struct NativeGlassButton: ViewModifier {
    var prominent = false
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if prominent { content.buttonStyle(.glassProminent) }
            else { content.buttonStyle(.glass) }
        } else if prominent { content.buttonStyle(.borderedProminent) }
        else { content.buttonStyle(.bordered) }
    }
}

private struct NativeGlassGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var body: some View {
        if #available(iOS 26.0, *) { GlassEffectContainer(spacing: 12) { content() } }
        else { content() }
    }
}

#Preview {
    ContentView().environmentObject(CameraController())
}
