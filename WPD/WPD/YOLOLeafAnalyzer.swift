import Accelerate
import CoreML
import UIKit

/// Decodes the bundled YOLO11 segmentation export and maps masks to the displayed image.
final class YOLOLeafAnalyzer {
    static let bundled = Result { try YOLOLeafAnalyzer() }
    static let modelName = "YOLO11n-seg · wheat-qh"
    static let defaultConfidence = 0.25

    private static let side = 512
    private static let maskSide = 128
    private static let maskChannels = 32
    private let model: MLModel
    private let predictionLock = NSLock()

    init(bundle: Bundle = .main, computeUnits: MLComputeUnits = .all) throws {
        guard let url = bundle.url(forResource: "WheatLeaf", withExtension: "mlmodelc") else {
            throw ModelError.missing
        }
        let configuration = MLModelConfiguration()
        #if targetEnvironment(simulator)
        configuration.computeUnits = .cpuOnly
        #else
        configuration.computeUnits = computeUnits
        #endif
        model = try MLModel(contentsOf: url, configuration: configuration)
    }

    func analyze(_ image: PreparedImage, parameters: AnalysisParameters) throws -> AnalysisResult {
        let start = ProcessInfo.processInfo.systemUptime
        let transform = Letterbox(width: image.width, height: image.height)
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(pixelBuffer: try transform.buffer(from: image))
        ])
        let output = try predict(input)
        let arrays = output.featureNames.compactMap { output.featureValue(for: $0)?.multiArrayValue }
        guard let prediction = arrays.first(where: { $0.shape.map(\.intValue) == [1, 38, 5376] }),
              let masks = arrays.first(where: { $0.shape.map(\.intValue) == [1, 32, 128, 128] })
        else { throw ModelError.output }

        let threshold = Float(parameters.modelConfidence ?? Self.defaultConfidence)
        let candidates = try candidates(from: prediction, threshold: threshold)
        let prototypes = candidates.isEmpty ? [] : try Tensor(masks).values()
        var leaves: [LeafObject] = []
        for candidate in candidates {
            let pixels = maskPixels(for: candidate, prototypes: prototypes, transform: transform)
            guard pixels.count >= 5 else { continue }
            // Two classes may predict the same leaf. Compare masks, since long leaves
            // crossing one another often have overlapping bounding boxes.
            guard !leaves.contains(where: { Self.maskIoU($0.pixels, pixels) > 0.60 }) else { continue }
            let foreground = Set(pixels)
            let w = image.width
            let boundary = pixels.filter { pixel in
                pixel % w == 0 || pixel % w == w - 1 ||
                    !foreground.contains(pixel - 1) || !foreground.contains(pixel + 1) ||
                    !foreground.contains(pixel - w) || !foreground.contains(pixel + w)
            }
            let x = Double(pixels.reduce(0) { $0 + $1 % w }) / Double(pixels.count)
            let y = Double(pixels.reduce(0) { $0 + $1 / w }) / Double(pixels.count)
            let warnings = candidate.score < 0.35 ? ["模型置信度较低，请核对叶片和类别"] : []
            leaves.append(LeafObject(
                id: leaves.count + 1, pixels: pixels, boundary: boundary,
                center: LeafPoint(x: x / Double(w), y: y / Double(image.height)),
                yellowPixels: 0, validPixels: pixels.count, isYellow: candidate.isYellow,
                warnings: warnings, confidence: Double(candidate.score)
            ))
        }
        return AnalysisResult(
            width: image.width, height: image.height, leaves: leaves, parameters: parameters,
            milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000,
            recognitionModel: Self.modelName
        )
    }

    private func predict(_ input: MLFeatureProvider) throws -> MLFeatureProvider {
        predictionLock.lock()
        defer { predictionLock.unlock() }
        return try model.prediction(from: input)
    }

    private struct Candidate {
        let rect: CGRect
        let score: Float
        let isYellow: Bool
        let coefficients: [Float]
    }

    private func candidates(from prediction: MLMultiArray, threshold: Float) throws -> [Candidate] {
        let values = try Tensor(prediction).values()
        let columns = prediction.shape[2].intValue
        let imageBounds = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        var proposed: [Candidate] = []
        for index in 0..<columns {
            let healthy = values[4 * columns + index]
            let yellowed = values[5 * columns + index]
            let score = max(healthy, yellowed)
            guard score.isFinite, score >= threshold else { continue }

            let x = values[index], y = values[columns + index]
            let w = values[2 * columns + index], h = values[3 * columns + index]
            guard x.isFinite, y.isFinite, w.isFinite, h.isFinite, w > 0, h > 0 else { continue }
            let rect = CGRect(x: CGFloat(x - w / 2), y: CGFloat(y - h / 2),
                              width: CGFloat(w), height: CGFloat(h)).intersection(imageBounds)
            guard !rect.isNull, !rect.isEmpty else { continue }
            let coefficients = (0..<Self.maskChannels).map { values[(6 + $0) * columns + index] }
            proposed.append(Candidate(rect: rect, score: score, isYellow: yellowed > healthy, coefficients: coefficients))
        }

        var selected: [Candidate] = []
        for candidate in proposed.sorted(by: { $0.score > $1.score }).prefix(300) {
            if selected.contains(where: { $0.isYellow == candidate.isYellow && Self.boxIoU($0.rect, candidate.rect) > 0.70 }) {
                continue
            }
            selected.append(candidate)
            if selected.count == 48 { break }
        }
        return selected
    }

    private func maskPixels(for candidate: Candidate, prototypes: [Float], transform t: Letterbox) -> [Int] {
        let side = Self.maskSide
        let area = side * side
        var logits = [Float](repeating: 0, count: area)
        cblas_sgemv(CblasRowMajor, CblasTrans, Int32(Self.maskChannels), Int32(area), 1,
                    prototypes, Int32(area), candidate.coefficients, 1, 0, &logits, 1)
        let r = candidate.rect
        let x0 = max(0, Int(floor((r.minX - t.left) / t.scaleX)))
        let y0 = max(0, Int(floor((r.minY - t.top) / t.scaleY)))
        let x1 = min(t.width, Int(ceil((r.maxX - t.left) / t.scaleX)))
        let y1 = min(t.height, Int(ceil((r.maxY - t.top) / t.scaleY)))
        guard x0 < x1, y0 < y1 else { return [] }

        var pixels: [Int] = []
        let shrink = Double(side) / Double(Self.side)
        // Sample logits at the source pixel centers, undoing the letterbox first.
        for y in y0..<y1 {
            let my = min(Double(side - 1), max(0, ((Double(y) + 0.5) * t.scaleY + t.top) * shrink - 0.5))
            let yLow = Int(my), yHigh = min(side - 1, yLow + 1)
            let dy = Float(my - Double(yLow))
            for x in x0..<x1 {
                let mx = min(Double(side - 1), max(0, ((Double(x) + 0.5) * t.scaleX + t.left) * shrink - 0.5))
                let xLow = Int(mx), xHigh = min(side - 1, xLow + 1)
                let dx = Float(mx - Double(xLow))
                let top = logits[yLow * side + xLow] * (1 - dx) + logits[yLow * side + xHigh] * dx
                let bottom = logits[yHigh * side + xLow] * (1 - dx) + logits[yHigh * side + xHigh] * dx
                if top * (1 - dy) + bottom * dy > 0 {
                    pixels.append(y * t.width + x)
                }
            }
        }
        return pixels
    }

    private static func boxIoU(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let shared = intersection.width * intersection.height
        return shared / (a.width * a.height + b.width * b.height - shared)
    }

    private static func maskIoU(_ a: [Int], _ b: [Int]) -> Double {
        var i = 0, j = 0, shared = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { shared += 1; i += 1; j += 1 }
            else if a[i] < b[j] { i += 1 }
            else { j += 1 }
        }
        return Double(shared) / Double(a.count + b.count - shared)
    }

    private struct Letterbox {
        let width: Int
        let height: Int
        let resizedWidth: Int
        let resizedHeight: Int
        let left: Double
        let top: Double
        var scaleX: Double { Double(resizedWidth) / Double(width) }
        var scaleY: Double { Double(resizedHeight) / Double(height) }

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            let scale = Double(YOLOLeafAnalyzer.side) / Double(max(width, height))
            resizedWidth = max(1, Int((Double(width) * scale).rounded()))
            resizedHeight = max(1, Int((Double(height) * scale).rounded()))
            left = Double((YOLOLeafAnalyzer.side - resizedWidth) / 2)
            top = Double((YOLOLeafAnalyzer.side - resizedHeight) / 2)
        }

        func buffer(from image: PreparedImage) throws -> CVPixelBuffer {
            let side = YOLOLeafAnalyzer.side
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA,
                                      nil, &buffer) == kCVReturnSuccess, let buffer,
                  image.rgba.count == width * height * 4
            else { throw ModelError.input }
            guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw ModelError.input }
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

            guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw ModelError.input }
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<side {
                for x in 0..<side {
                    let index = y * stride + x * 4
                    bytes[index] = 114
                    bytes[index + 1] = 114
                    bytes[index + 2] = 114
                    bytes[index + 3] = 255
                }
            }

            // Match the training pipeline: bilinear RGB resize with neutral padding.
            let xSamples = (0..<resizedWidth).map { sample($0, scale: scaleX, limit: width) }
            let padX = Int(left), padY = Int(top)
            for y in 0..<resizedHeight {
                let ys = sample(y, scale: scaleY, limit: height)
                for (x, xs) in xSamples.enumerated() {
                    let target = (y + padY) * stride + (x + padX) * 4
                    let a = (ys.low * width + xs.low) * 4
                    let b = (ys.low * width + xs.high) * 4
                    let c = (ys.high * width + xs.low) * 4
                    let d = (ys.high * width + xs.high) * 4
                    for channel in 0..<3 {
                        let upper = Float(image.rgba[a + channel]) * (1 - xs.fraction)
                                  + Float(image.rgba[b + channel]) * xs.fraction
                        let lower = Float(image.rgba[c + channel]) * (1 - xs.fraction)
                                  + Float(image.rgba[d + channel]) * xs.fraction
                        bytes[target + 2 - channel] = UInt8(clamping: Int(
                            (upper * (1 - ys.fraction) + lower * ys.fraction).rounded()
                        ))
                    }
                }
            }
            return buffer
        }

        private func sample(_ pixel: Int, scale: Double, limit: Int) -> (low: Int, high: Int, fraction: Float) {
            let value = min(Double(limit - 1), max(0, (Double(pixel) + 0.5) / scale - 0.5))
            let low = Int(value)
            return (low, min(limit - 1, low + 1), Float(value - Double(low)))
        }
    }

    private struct Tensor {
        let array: MLMultiArray
        init(_ array: MLMultiArray) { self.array = array }

        /// Flatten in logical axis order, including padding used by some compute units.
        func values() throws -> [Float] {
            let shape = array.shape.map(\.intValue)
            let strides = array.strides.map(\.intValue)
            let channels = shape[1]
            let rows = shape.count == 4 ? shape[2] : 1
            let columns = shape.last!
            let rowStride = shape.count == 4 ? strides[2] : 0
            let columnStride = strides.last!
            let channelStride = strides[1]
            return try array.withUnsafeBytes { raw in
                let read: (Int) -> Float
                switch array.dataType {
                case .float32:
                    let pointer = raw.bindMemory(to: Float.self)
                    if columnStride == 1, channelStride == rows * columns,
                       rows == 1 || rowStride == columns {
                        return Array(pointer.prefix(channels * rows * columns))
                    }
                    read = { pointer[$0] }
                case .float16:
                    let pointer = raw.bindMemory(to: UInt16.self)
                    read = { Self.fromHalf(pointer[$0]) }
                case .double:
                    let pointer = raw.bindMemory(to: Double.self)
                    read = { Float(pointer[$0]) }
                default: throw ModelError.output
                }
                var values: [Float] = []
                values.reserveCapacity(channels * rows * columns)
                for c in 0..<channels {
                    for y in 0..<rows {
                        let base = c * channelStride + y * rowStride
                        for x in 0..<columns { values.append(read(base + x * columnStride)) }
                    }
                }
                return values
            }
        }

        private static func fromHalf(_ half: UInt16) -> Float {
            let sign = UInt32(half & 0x8000) << 16
            let exponent = UInt32((half >> 10) & 31)
            let fraction = UInt32(half & 1023)
            if exponent == 0 {
                return (sign == 0 ? 1 : -1) * Float(fraction) / 16_777_216
            }
            let adjusted: UInt32 = exponent == 31 ? 255 : exponent + 112
            return Float(bitPattern: sign | (adjusted << 23) | (fraction << 13))
        }
    }

    private enum ModelError: LocalizedError {
        case missing, input, output
        var errorDescription: String? {
            switch self {
            case .missing: return "找不到内置的小麦识别模型。"
            case .input: return "无法准备模型所需的图像。"
            case .output: return "小麦识别模型返回了不兼容的结果。"
            }
        }
    }
}
