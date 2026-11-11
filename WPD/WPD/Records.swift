import Foundation
import SwiftUI

struct HistoryRecord: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var result: AnalysisResult

    var annotatedFile: String { "\(id.uuidString)-annotated.jpg" }
    var legacyOriginalFile: String { "\(id.uuidString)-original.jpg" }
}

@MainActor final class RecordStore: ObservableObject {
    @Published private(set) var records: [HistoryRecord] = []
    @Published var error: String?
    private let directory: URL
    private var readFailed = false

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WheatVision", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: recordsURL.path) {
                records = try JSONDecoder().decode([HistoryRecord].self, from: Data(contentsOf: recordsURL))
            }
        } catch {
            readFailed = true
            self.error = "无法读取历史"
        }
    }

    private var recordsURL: URL { directory.appendingPathComponent("records.json") }

    func imageURL(_ record: HistoryRecord) -> URL { directory.appendingPathComponent(record.annotatedFile) }

    func save(_ record: HistoryRecord, annotatedJPEG: Data) throws {
        guard !readFailed else { throw HistoryError.unavailable }
        var compact = record
        for index in compact.result.leaves.indices {
            compact.result.leaves[index].pixels = []
            compact.result.leaves[index].boundary = []
            compact.result.leaves[index].contours = []
        }
        let url = imageURL(record)
        try annotatedJPEG.write(to: url, options: .atomic)
        do {
            try persist([compact] + records)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func delete(_ record: HistoryRecord) throws {
        try persist(records.filter { $0.id != record.id })
        let files = [imageURL(record), directory.appendingPathComponent(record.legacyOriginalFile)]
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    private func persist(_ updated: [HistoryRecord]) throws {
        try JSONEncoder().encode(updated).write(to: recordsURL, options: .atomic)
        records = updated
    }

    private enum HistoryError: LocalizedError {
        case unavailable
        var errorDescription: String? { "历史文件无法读取，未保存。" }
    }
}
