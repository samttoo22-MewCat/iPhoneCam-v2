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
            do { renderer = try BeautyRenderer(frames: camera.frames) }
            catch { renderError = error.localizedDescription }
        }
        .onChange(of: scenePhase) { _, phase in camera.setActive(phase == .active) }
        .sheet(isPresented: $beauty, onDismiss: { camera.comparing = false }) {
            ScrollView {
                VStack(spacing: 16) {
                    HStack {
                        Text("自然美顏").font(.title2.bold())
                        Spacer()
                        Button("完成") { beauty = false }.modifier(NativeGlassButton())
                    }
                    beautyControls
                    Text("即時處理手機影像；不會傳送到電腦。")
                        .font(.footnote).foregroundStyle(Palette.muted)
                }.padding(20)
            }
            .presentationDetents([.height(520), .large])
            .presentationDragIndicator(.visible)
            .tint(Palette.cyan)
        }
        .sheet(isPresented: $connection) {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("連接電腦").font(.title2.bold())
                    Spacer()
                    Button("完成") { connection = false }.modifier(NativeGlassButton())
                }
                Label("視訊鏡頭輸出尚未接入", systemImage: "desktopcomputer")
                    .foregroundStyle(Palette.cyan)
                Text("這一版提供手機端預覽、美顏與相機控制，不會啟動直播或傳送影像。")
                Text("USB、CAM1/CUM1、編碼碼率及 Windows 接收端屬於下一階段。")
                    .foregroundStyle(Palette.muted)
                Spacer()
            }.padding(24)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
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
                Label("僅預覽", systemImage: "iphone").font(.caption.weight(.medium))
                    .frame(minHeight: 32)
            }
            .modifier(NativeGlassButton())
            .accessibilityLabel("連線與輸出設定，目前僅手機預覽")
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
            Text("中央橢圓區域加權，未啟用人臉追蹤。清晰度也會影響背景。")
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

    private var help: some View {
        ScrollView {
            VStack(spacing: 14) {
                card("使用方式") {
                    Text("1. 允許相機權限，首頁顯示即時預覽。\n2. 到「設定」選鏡頭、畫質與 FPS。\n3. 開啟「美顏」即時調整，使用「對比原圖」比較。\n4. 離開 App 會暫停相機，返回後恢復。")
                        .font(.callout).lineSpacing(8)
                }
                card("本版範圍") {
                    Text("保留 iOS 原生 Liquid Glass、系統面板與觸覺回饋。美顏在手機 GPU 處理，不上傳影像。")
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
