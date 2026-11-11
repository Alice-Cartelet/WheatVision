import UIKit
import CoreImage
import Vision
import Accelerate
import AVFoundation
import SwiftUI

struct PreparedImage {
    let image: UIImage
    let rgba: [UInt8]
    let width: Int
    let height: Int
}

enum Imaging {
    static let context = CIContext(options: [.cacheIntermediates: false])
    static func prepare(_ image: UIImage, maximum: Int) throws -> PreparedImage {
        let ratio = min(1, CGFloat(maximum) / max(image.size.width, image.size.height))
        let w = max(3, Int(image.size.width * ratio)), h = max(3, Int(image.size.height * ratio))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let normalized = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { _ in
            UIColor.white.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: w, height: h))
            image.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return try rasterize(normalized, width: w, height: h)
    }

    static func prepareVideo(_ buffer: CVPixelBuffer) throws -> PreparedImage {
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = min(1, 512 / max(image.extent.width, image.extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { throw ImageError.invalid }
        return try rasterize(UIImage(cgImage: cg), width: cg.width, height: cg.height)
    }

    private static func rasterize(_ normalized: UIImage, width w: Int, height h: Int) throws -> PreparedImage {
        var bytes = [UInt8](repeating: 0, count: w*h*4)
        let success = bytes.withUnsafeMutableBytes { ptr -> Bool in
            guard let cg = normalized.cgImage, let ctx = CGContext(data: ptr.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        guard success else { throw ImageError.invalid }
        return PreparedImage(image: normalized, rgba: bytes, width: w, height: h)
    }
    /// Vision extracts ordered contours from each instance mask, never counts color patches.
    static func refineContours(_ result: inout AnalysisResult) {
        let w = result.width, h = result.height
        for index in result.leaves.indices {
            let pixels = result.leaves[index].pixels
            guard let first = pixels.first else { continue }
            var x0 = first % w, x1 = x0, y0 = first / w, y1 = y0
            for p in pixels { x0 = min(x0,p%w); x1 = max(x1,p%w); y0 = min(y0,p/w); y1 = max(y1,p/w) }
            x0 = max(0,x0-2); y0 = max(0,y0-2); x1 = min(w-1,x1+2); y1 = min(h-1,y1+2)
            let cw = x1-x0+1, ch = y1-y0+1
            var mask = [UInt8](repeating: 0, count: cw*ch)
            for p in pixels { mask[(p/w-y0)*cw+p%w-x0] = 255 }
            // Accelerate bounds the contour workload for large still-image masks.
            let factor = min(1.0,512.0/Double(max(cw,ch)))
            let sw = max(3,Int(Double(cw)*factor)), sh = max(3,Int(Double(ch)*factor))
            var scaled = [UInt8](repeating:0,count:sw*sh)
            let status = mask.withUnsafeMutableBytes { src in scaled.withUnsafeMutableBytes { dst in
                var source = vImage_Buffer(data:src.baseAddress,height:vImagePixelCount(ch),width:vImagePixelCount(cw),rowBytes:cw)
                var target = vImage_Buffer(data:dst.baseAddress,height:vImagePixelCount(sh),width:vImagePixelCount(sw),rowBytes:sw)
                return vImageScale_Planar8(&source,&target,nil,vImage_Flags(kvImageHighQualityResampling))
            } }
            guard status == kvImageNoError, let provider = CGDataProvider(data: Data(scaled) as CFData),
                  let cg = CGImage(width:sw,height:sh,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:sw,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:[],provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else { continue }
            let request = VNDetectContoursRequest(); request.detectsDarkOnLight = false; request.maximumImageDimension = 512
            do {
                try VNImageRequestHandler(cgImage:cg).perform([request])
                guard let observation = request.results?.first else { continue }
                result.leaves[index].contours = observation.topLevelContours.map { contour in
                    contour.normalizedPoints.map { point in
                        LeafPoint(x:(Double(x0)+Double(point.x)*Double(cw))/Double(w), y:(Double(y0)+(1-Double(point.y))*Double(ch))/Double(h))
                    }
                }
            } catch { /* Raster boundaries remain available if Vision cannot trace this mask. */ }
        }
    }

    static func annotated(_ image: UIImage, result: AnalysisResult) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: format).image { renderer in
            image.draw(at: .zero)
            let ctx = renderer.cgContext
            let sx = image.size.width / CGFloat(result.width), sy = image.size.height / CGFloat(result.height)
            for leaf in result.leaves {
                let color: UIColor = leaf.isYellow ? .systemOrange : .systemGreen
                ctx.setFillColor(color.cgColor)
                for i in leaf.boundary { ctx.fill(CGRect(x: CGFloat(i % result.width)*sx, y: CGFloat(i / result.width)*sy, width: max(1,sx), height: max(1,sy))) }
                let text = "#\(leaf.id)\(leaf.pending ? " ?" : "")"
                text.draw(at: CGPoint(x: leaf.center.x*image.size.width, y: leaf.center.y*image.size.height),
                          withAttributes: [.font: UIFont.boldSystemFont(ofSize: max(16,image.size.width/45)), .foregroundColor: leaf.pending ? UIColor.systemPink : color, .backgroundColor: UIColor.black.withAlphaComponent(0.65)])
            }
        }
    }
    enum ImageError: LocalizedError { case invalid; var errorDescription: String? { "无法读取图像，请选择其他照片。" } }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.videoGravity = .resizeAspect
        view.previewLayer.session = session
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        if let connection = view.previewLayer.connection,
           connection.isVideoRotationAngleSupported(90), connection.videoRotationAngle != 90 {
            connection.videoRotationAngle = 90
        }
    }
}

final class CameraController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    @Published var result: AnalysisResult?
    @Published var ready = false
    @Published var capturing = false
    @Published var error: String?
    @Published var photo: CapturedPhoto?
    struct CapturedPhoto: Identifiable { let id = UUID(); let image: UIImage; let date: Date }

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "WheatVision.camera", qos: .userInitiated)
    private let inferenceQueue = DispatchQueue(label: "WheatVision.inference", qos: .userInitiated)
    private let output = AVCapturePhotoOutput()
    private let parameters = AnalysisParameters()
    // Accessed from the UI/main queue.
    private var requested = false
    // Accessed from the capture queue.
    private var configured = false
    private var active = false
    private var analyzing = false
    private var generation = 0
    private var lastFrame = 0.0
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        observers.append(NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { [weak self] _ in
            guard let self, self.requested else { return }
            self.ready = false; self.result = nil; self.error = "相机中断"
        })
        observers.append(NotificationCenter.default.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main) { [weak self] _ in
            guard let self, self.requested else { return }
            self.ready = false; self.result = nil; self.error = "相机暂不可用"
        })
        observers.append(NotificationCenter.default.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: .main) { [weak self] _ in
            guard let self, self.requested else { return }
            self.ready = true; self.error = nil
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func start() {
        guard !requested else { return }
        requested = true
        error = nil
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: activate()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.requested else { return }
                    if granted { self.activate() } else { self.error = "请允许相机访问，或导入照片。" }
                }
            }
        default: error = "请允许相机访问，或导入照片。"
        }
    }

    private func activate() {
        queue.async {
            do {
                if !self.configured { try self.configure() }
                self.generation += 1
                self.active = true
                self.lastFrame = 0
                if !self.session.isRunning { self.session.startRunning() }
                let running = self.session.isRunning
                DispatchQueue.main.async {
                    guard self.requested else { return }
                    self.ready = running
                    self.error = running ? nil : "相机无法启动"
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.requested else { return }
                    self.error = error.localizedDescription
                    self.ready = false
                }
            }
        }
    }

    private func configure() throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        else { throw CameraError.unavailable }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard session.canAddInput(input) else { throw CameraError.unavailable }
        session.addInput(input)
        let video = AVCaptureVideoDataOutput()
        video.alwaysDiscardsLateVideoFrames = true
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        video.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(video), session.canAddOutput(output) else {
            session.removeInput(input)
            throw CameraError.unavailable
        }
        session.addOutput(video)
        session.addOutput(output)
        for connection in [video.connection(with: .video), output.connection(with: .video)].compactMap({ $0 }) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        }
        if let dimensions = device.activeFormat.supportedMaxPhotoDimensions.last { output.maxPhotoDimensions = dimensions }
        output.maxPhotoQualityPrioritization = .quality
        configured = true
    }

    func stop() {
        guard requested else { return }
        requested = false
        ready = false
        result = nil
        queue.async {
            self.active = false
            self.generation += 1
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func capture() {
        guard ready, !capturing else { return }
        capturing = true
        queue.async {
            guard self.active else { DispatchQueue.main.async { self.capturing = false }; return }
            let settings = AVCapturePhotoSettings()
            settings.maxPhotoDimensions = self.output.maxPhotoDimensions
            settings.photoQualityPrioritization = .quality
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard active, !analyzing, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let thermal = ProcessInfo.processInfo.thermalState
        let reducedRate = thermal == .serious || thermal == .critical || ProcessInfo.processInfo.isLowPowerModeEnabled
        guard now - lastFrame >= (reducedRate ? 0.40 : 0.12) else { return }
        lastFrame = now
        analyzing = true
        let currentGeneration = generation
        // The preview layer never waits for analysis. Skip frames while inference is busy.
        inferenceQueue.async {
            let outcome = autoreleasepool {
                Result {
                    let image = try Imaging.prepareVideo(buffer)
                    return try YOLOLeafAnalyzer.bundled.get().analyze(image, parameters: self.parameters)
                }
            }
            self.queue.async {
                self.analyzing = false
                guard self.active, self.generation == currentGeneration else { return }
                DispatchQueue.main.async {
                    guard self.requested, self.ready else { return }
                    switch outcome {
                    case .success(let result): self.result = result; self.error = nil
                    case .failure(let error): self.result = nil; self.error = error.localizedDescription
                    }
                }
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let date = Date()
        DispatchQueue.main.async {
            self.capturing = false
            guard self.requested else { return }
            if let error { self.error = error.localizedDescription; return }
            guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
                self.error = "拍照失败"
                return
            }
            self.stop()
            self.photo = CapturedPhoto(image: image, date: date)
        }
    }

    private enum CameraError: LocalizedError {
        case unavailable
        var errorDescription: String? { "相机不可用，请导入照片。" }
    }
}
