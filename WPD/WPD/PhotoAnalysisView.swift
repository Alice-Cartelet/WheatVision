import SwiftUI

@MainActor final class PhotoModel: ObservableObject {
    @Published var prepared: PreparedImage?
    @Published var result: AnalysisResult?
    @Published var busy = true
    @Published var error: String?
    private var undoStack: [AnalysisResult] = []
    var canUndo: Bool { !undoStack.isEmpty }

    func analyze(_ image: UIImage, parameters: AnalysisParameters) async {
        do {
            let output = try await Task.detached(priority: .userInitiated) { () -> (PreparedImage, AnalysisResult) in
                let prepared = try Imaging.prepare(image, maximum: 1600)
                var result = try YOLOLeafAnalyzer.bundled.get().analyze(prepared, parameters: parameters)
                Imaging.refineContours(&result)
                return (prepared, result)
            }.value
            prepared = output.0
            result = output.1
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }

    func edit(_ change: (inout AnalysisResult) -> Void) {
        guard var value = result else { return }
        undoStack.append(value)
        if undoStack.count > 12 { undoStack.removeFirst() }
        change(&value)
        result = value
    }

    func undo() {
        if let old = undoStack.popLast() { result = old }
    }

    @discardableResult
    func add(_ polygon: [LeafPoint]) -> Bool {
        guard let prepared, var value = result,
              LeafAnalyzer().addPolygon(polygon, to: &value, rgba: prepared.rgba) else {
            error = "请沿叶片边缘至少选 3 个点。"
            return false
        }
        edit { $0 = value }
        return true
    }
}

struct PhotoAnalysisView: View {
    let image: UIImage
    let date: Date
    @ObservedObject var store: RecordStore
    @StateObject private var model = PhotoModel()
    @Environment(\.dismiss) private var dismiss
    @State private var zoom = 1.0
    @State private var gestureZoom = 1.0
    @State private var drawing = false
    @State private var polygon: [LeafPoint] = []
    @State private var saved = false
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Group {
                if model.busy {
                    ProgressView("识别中")
                } else if let prepared = model.prepared, let result = model.result {
                    ScrollView {
                        VStack(spacing: 14) {
                            photoPreview(prepared, result: result)
                            StatisticsView(result: result)
                            if !saved {
                                correctionControls
                                ForEach(result.leaves) { leaf in leafMenu(leaf) }
                            }
                        }
                        .padding()
                    }
                } else {
                    ContentUnavailableView("无法识别", systemImage: "photo.badge.exclamationmark",
                                           description: Text(model.error ?? "请选择其他照片。"))
                }
            }
            .navigationTitle("照片识别")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("返回") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(saved ? "已保存" : saving ? "保存中" : "保存") { save() }
                        .disabled(saved || saving || model.result == nil || drawing)
                }
            }
            .task { await model.analyze(image, parameters: AnalysisParameters()) }
            .alert("提示", isPresented: Binding(
                get: { model.error != nil && model.result != nil },
                set: { if !$0 && model.result != nil { model.error = nil } }
            )) {
                Button("好") { model.error = nil }
            } message: {
                Text(model.error ?? "")
            }
        }
    }

    private func photoPreview(_ prepared: PreparedImage, result: AnalysisResult) -> some View {
        GeometryReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LeafImageView(image: prepared.image, result: result, polygon: polygon,
                              onTap: { if drawing { polygon.append($0) } })
                    .frame(width: proxy.size.width * zoom, height: 340 * zoom)
                    .simultaneousGesture(MagnificationGesture()
                        .onChanged { zoom = min(5, max(1, gestureZoom * $0)) }
                        .onEnded { _ in gestureZoom = zoom })
            }
        }
        .frame(height: 340)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var correctionControls: some View {
        HStack {
            if drawing {
                Button("取消") { drawing = false; polygon = [] }
                Spacer()
                Button("退回一点") { polygon.removeLast() }.disabled(polygon.isEmpty)
                Button("完成") {
                    if model.add(polygon) { drawing = false; polygon = [] }
                }
                .disabled(polygon.count < 3)
            } else {
                Button("补标", systemImage: "pencil.tip.crop.circle") { drawing = true }
                Spacer()
                Button("撤销", systemImage: "arrow.uturn.backward") { model.undo() }.disabled(!model.canUndo)
            }
        }
        .font(.subheadline)
        .disabled(saving)
    }

    private func leafMenu(_ leaf: LeafObject) -> some View {
        Menu {
            Button("设为健康") { classify(leaf.id, yellow: false) }
            Button("设为枯黄") { classify(leaf.id, yellow: true) }
            Button("删除", role: .destructive) { model.edit { $0.leaves.removeAll { $0.id == leaf.id } } }
        } label: {
            HStack {
                Text("#\(leaf.id)").monospacedDigit()
                Spacer()
                Text(leaf.pending ? "待复核" : leaf.isYellow ? "枯黄" : "健康")
                    .foregroundStyle(leaf.pending ? Color.pink : leaf.isYellow ? .orange : .green)
                Image(systemName: "ellipsis.circle")
            }
            .padding(10)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        }
        .disabled(saving || drawing)
    }

    private func classify(_ id: Int, yellow: Bool) {
        model.edit { result in
            if let index = result.leaves.firstIndex(where: { $0.id == id }) {
                result.leaves[index].isYellow = yellow
                result.leaves[index].reviewed = true
            }
        }
    }

    private func save() {
        guard let result = model.result, let prepared = model.prepared else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                let jpeg = try await Task.detached(priority: .userInitiated) {
                    guard let data = Imaging.annotated(prepared.image, result: result).jpegData(compressionQuality: 0.92)
                    else { throw Imaging.ImageError.invalid }
                    return data
                }.value
                try store.save(HistoryRecord(date: date, result: result), annotatedJPEG: jpeg)
                saved = true
            } catch {
                model.error = error.localizedDescription
            }
        }
    }
}

struct HistoryView: View {
    @ObservedObject var store: RecordStore
    @State private var deleting: HistoryRecord?

    var body: some View {
        NavigationStack {
            List {
                if let error = store.error { Text(error).foregroundStyle(.red) }
                if store.records.isEmpty {
                    ContentUnavailableView("暂无历史", systemImage: "clock")
                }
                ForEach(store.records) { record in
                    NavigationLink { detail(record) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.date.formatted(date: .abbreviated, time: .shortened))
                            Text("\(record.result.yellow) / \(record.result.total) 片枯黄 · \(record.result.yellowRatioText)")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { deleting = record }
                    }
                }
            }
            .navigationTitle("历史")
            .confirmationDialog("删除这次识别？", isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            ), titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let record = deleting {
                        do { try store.delete(record) }
                        catch { store.error = error.localizedDescription }
                    }
                    deleting = nil
                }
            }
        }
    }

    private func detail(_ record: HistoryRecord) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                if let image = UIImage(contentsOfFile: store.imageURL(record).path) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                StatisticsView(result: record.result)
            }
            .padding()
        }
        .navigationTitle(record.date.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
    }
}
