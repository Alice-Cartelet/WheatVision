import SwiftUI
import PhotosUI

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @StateObject private var store = RecordStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var item: PhotosPickerItem?
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                VStack(spacing: 12) {
                    ZStack {
                        Color.black
                        CameraPreview(session: camera.session)
                        if let result = camera.result {
                            GeometryReader { proxy in
                                let scale = min(proxy.size.width / CGFloat(result.width),
                                                proxy.size.height / CGFloat(result.height))
                                LeafOverlay(result: result)
                                    .frame(width: CGFloat(result.width) * scale,
                                           height: CGFloat(result.height) * scale)
                                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                            }
                            .allowsHitTesting(false)
                        }
                        if let error = camera.error {
                            Text(error)
                                .font(.subheadline)
                                .multilineTextAlignment(.center)
                                .padding(12)
                                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
                                .foregroundStyle(.white)
                        } else if !camera.ready {
                            ProgressView().tint(.white)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    StatisticsView(result: camera.result)
                    HStack(spacing: 36) {
                        PhotosPicker(selection: $item, matching: .images) {
                            Image(systemName: "photo.on.rectangle").font(.title2).frame(width: 48, height: 48)
                        }
                        .accessibilityLabel("导入照片")
                        .disabled(importing || camera.capturing)
                        Button { camera.capture() } label: {
                            ZStack {
                                Circle().stroke(.primary, lineWidth: 2).frame(width: 64, height: 64)
                                Circle().fill(.tint).frame(width: 54, height: 54)
                            }
                        }
                        .disabled(!camera.ready || camera.capturing || importing)
                        .accessibilityLabel("拍照分析")
                        Group {
                            if importing || camera.capturing { ProgressView() } else { Color.clear }
                        }
                        .frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 6)
                .navigationTitle("识别")
                .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("识别", systemImage: "camera.viewfinder") }.tag(0)
            HistoryView(store: store)
                .tabItem { Label("历史", systemImage: "clock.arrow.circlepath") }.tag(1)
        }
        .tint(Color(red: 0.16, green: 0.55, blue: 0.36))
        .onAppear { updateCamera() }
        .onChange(of: tab) { _, _ in updateCamera() }
        .onChange(of: scenePhase) { _, _ in updateCamera() }
        .onChange(of: item) { _, new in
            guard let new else { return }
            importing = true
            Task {
                defer { importing = false; item = nil }
                do {
                    guard let data = try await new.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { throw Imaging.ImageError.invalid }
                    camera.stop()
                    camera.photo = .init(image: image, date: Date())
                } catch {
                    importError = error.localizedDescription
                }
            }
        }
        .fullScreenCover(item: $camera.photo, onDismiss: updateCamera) { photo in
            PhotoAnalysisView(image: photo.image, date: photo.date, store: store)
        }
        .alert("导入失败", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("好") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private func updateCamera() {
        if tab == 0 && scenePhase == .active && camera.photo == nil { camera.start() } else { camera.stop() }
    }
}

struct StatisticsView: View {
    let result: AnalysisResult?

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                metric("健康", result.map { String($0.healthy) } ?? "—", .green)
                metric("枯黄", result.map { String($0.yellow) } ?? "—", .orange)
                metric("总数", result.map { String($0.total) } ?? "—", .primary)
                metric("枯黄占比", result?.yellowRatioText ?? "—", .primary)
            }
            if let result, result.pendingCount > 0 {
                Text("\(result.pendingCount) 片待复核，暂不计入")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func metric(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

extension AnalysisResult {
    var yellowRatioText: String {
        total == 0 ? "—" : yellowCountRatio.formatted(.percent.precision(.fractionLength(1)))
    }
}

struct LeafImageView: View {
    let image: UIImage
    let result: AnalysisResult
    var polygon: [LeafPoint] = []
    var onTap: ((LeafPoint) -> Void)?

    var body: some View {
        GeometryReader { proxy in
            let aspect = image.size.width / image.size.height
            let width = min(proxy.size.width, proxy.size.height * aspect)
            let height = width / aspect
            Image(uiImage: image).resizable().frame(width: width, height: height)
                .overlay { LeafOverlay(result: result, polygon: polygon) }
                .contentShape(Rectangle())
                .onTapGesture { point in
                    onTap?(LeafPoint(x: max(0, min(1, point.x / width)), y: max(0, min(1, point.y / height))))
                }
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }
}

struct LeafOverlay: View {
    let result: AnalysisResult
    var polygon: [LeafPoint] = []

    var body: some View {
        Canvas { context, size in
            let sx = size.width / CGFloat(result.width), sy = size.height / CGFloat(result.height)
            for leaf in result.leaves {
                let color: Color = leaf.pending ? .pink : leaf.isYellow ? .orange : .green
                if leaf.contours.isEmpty {
                    var path = Path()
                    for pixel in leaf.boundary {
                        path.addRect(CGRect(x: CGFloat(pixel % result.width) * sx,
                                            y: CGFloat(pixel / result.width) * sy,
                                            width: max(1, sx), height: max(1, sy)))
                    }
                    context.fill(path, with: .color(color))
                } else {
                    for contour in leaf.contours {
                        guard let first = contour.first else { continue }
                        var path = Path()
                        path.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
                        for point in contour.dropFirst() {
                            path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height))
                        }
                        path.closeSubpath()
                        context.stroke(path, with: .color(color), lineWidth: 1.5)
                    }
                }
                context.draw(Text("\(leaf.id)\(leaf.pending ? "?" : "")").font(.caption.bold()).foregroundColor(color),
                             at: CGPoint(x: leaf.center.x * size.width, y: leaf.center.y * size.height))
            }
            if let first = polygon.first {
                var path = Path()
                path.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
                for point in polygon.dropFirst() {
                    path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height))
                }
                context.stroke(path, with: .color(.cyan), lineWidth: 2)
                for point in polygon {
                    let rect = CGRect(x: point.x * size.width - 3, y: point.y * size.height - 3, width: 6, height: 6)
                    context.fill(Path(ellipseIn: rect), with: .color(.cyan))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
