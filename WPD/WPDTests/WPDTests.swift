import XCTest
#if canImport(WPD)
@testable import WPD
#else
@testable import LeafCore
#endif

final class WPDTests: XCTestCase {
    let w = 240, h = 180
    let green: [UInt8] = [40, 150, 50, 255]
    let yellow: [UInt8] = [210, 170, 30, 255]
    let brown: [UInt8] = [115, 65, 25, 255]
    func fixture(_ color: (Int, Int) -> [UInt8]?) -> [UInt8] {
        var bytes: [UInt8] = []; bytes.reserveCapacity(w*h*4)
        for y in 0..<h { for x in 0..<w { bytes += color(x,y) ?? [245,245,245,255] } }
        return bytes
    }
    func ellipse(_ x: Int, _ y: Int, cx: Double = 120, cy: Double = 90, rx: Double = 65, ry: Double = 12) -> Bool {
        pow((Double(x)-cx)/rx,2)+pow((Double(y)-cy)/ry,2) <= 1
    }
    func analyze(_ bytes: [UInt8], parameters: AnalysisParameters = .init()) -> AnalysisResult {
        LeafAnalyzer().analyze(rgba: bytes, width: w, height: h, parameters: parameters)
    }
    func testSingleGreenLeaf() {
        let r = analyze(fixture { x,y in self.ellipse(x,y) ? self.green : nil })
        XCTAssertEqual(r.leaves.count,1); XCTAssertEqual(r.healthy,1); XCTAssertEqual(r.yellowAreaRatio,0)
    }
    func testSingleYellowLeaf() {
        let r = analyze(fixture { x,y in self.ellipse(x,y) ? self.yellow : nil })
        XCTAssertEqual(r.yellow,1); XCTAssertEqual(r.yellowAreaRatio,1)
    }
    func testMixedLeafIsOneObject() {
        let r = analyze(fixture { x,y in self.ellipse(x,y) ? (x < 120 ? self.green : self.yellow) : nil })
        XCTAssertEqual(r.leaves.count,1); XCTAssertEqual(r.yellow,1)
        XCTAssertEqual(r.yellowAreaRatio,0.5,accuracy:0.02)
    }
    func testYellowTipAndLocalSpotsDoNotBecomeLeaves() {
        let r = analyze(fixture { x,y in self.ellipse(x,y) ? (x>170 || (x>100 && x<110) ? self.yellow : self.green) : nil })
        XCTAssertEqual(r.leaves.count,1); XCTAssertEqual(r.healthy,1); XCTAssertGreaterThan(r.yellowAreaRatio,0)
    }
    func testBrownDryTissue() {
        let r = analyze(fixture { x,y in self.ellipse(x,y) ? self.brown : nil })
        XCTAssertEqual(r.yellow,1); XCTAssertEqual(r.yellowAreaRatio,1)
    }
    func testSeparateLeaves() {
        let r = analyze(fixture { x,y in
            if self.ellipse(x,y,cy:50) { return self.green }
            if self.ellipse(x,y,cy:130) { return self.yellow }
            return nil
        })
        XCTAssertEqual(r.total,2); XCTAssertEqual(r.healthy,1); XCTAssertEqual(r.yellow,1)
        XCTAssertEqual(r.yellowCountRatio,0.5); XCTAssertEqual(r.yellowAreaRatio,0.5,accuracy:0.01)
    }
    func testSmallNoiseRemoved() {
        let r = analyze(fixture { x,y in self.ellipse(x,y) || (x==10 && y==10) || (x==220 && y==160) ? self.green : nil })
        XCTAssertEqual(r.total,1)
    }
    func testContactSplitsAreProvisionalAndConserveArea() {
        let bytes = fixture { x,y in
            self.ellipse(x,y,cx:65,rx:45) || self.ellipse(x,y,cx:175,rx:45) || (x>=105 && x<=135 && abs(y-90)<=2) ? self.green : nil
        }
        let r = analyze(bytes)
        XCTAssertEqual(r.leaves.count,2); XCTAssertEqual(r.pendingCount,2); XCTAssertEqual(r.total,0)
        let pixels = r.leaves.flatMap(\.pixels)
        XCTAssertEqual(Set(pixels).count,pixels.count)
        var p = AnalysisParameters(); p.splitContacts = false
        XCTAssertEqual(analyze(bytes,parameters:p).leaves.reduce(0){$0+$1.pixels.count},pixels.count)
    }
    func testWhiteAndBlueBackgroundsDoNotCount() {
        XCTAssertEqual(analyze(fixture { _,_ in nil }).leaves.count,0)
        XCTAssertEqual(analyze(fixture { _,_ in [30,50,220,255] }).leaves.count,0)
    }
    func testPlantColoredBackgroundIsPending() {
        let r = analyze(fixture { _,_ in self.green })
        XCTAssertEqual(r.total,0); XCTAssertGreaterThan(r.pendingCount,0)
    }
    func testBranchedPlantNotAcceptedAsOneLeaf() {
        let r = analyze(fixture { x,y in
            (abs(x-120)<5 && y>25 && y<155) || (abs(y-85)<7 && x>40 && x<200) ? self.green : nil
        })
        XCTAssertEqual(r.total,0); XCTAssertGreaterThan(r.pendingCount,0)
    }
    func testThresholdChangesCategoryNotArea() {
        let bytes = fixture { x,y in self.ellipse(x,y) ? (x<120 ? self.green : self.yellow) : nil }
        var p = AnalysisParameters(); p.yellowThreshold = 0.8
        let a = analyze(bytes), b = analyze(bytes,parameters:p)
        XCTAssertEqual(a.yellow,1); XCTAssertEqual(b.healthy,1); XCTAssertEqual(a.yellowAreaRatio,b.yellowAreaRatio)
    }
    func testWeightedAreaNotAverageOfLeafRatios() {
        let r = analyze(fixture { x,y in
            if self.ellipse(x,y,cy:50,rx:70,ry:14) { return self.green }
            if self.ellipse(x,y,cy:130,rx:35,ry:7) { return self.yellow }
            return nil
        })
        XCTAssertEqual(r.total,2); XCTAssertEqual(r.yellowCountRatio,0.5)
        XCTAssertEqual(r.yellowAreaRatio,0.2,accuracy:0.025)
    }
    func testManualPolygonOwnsPixelsExclusively() {
        let bytes = fixture { x,y in self.ellipse(x,y) ? self.green : nil }
        var r = analyze(bytes)
        XCTAssertTrue(LeafAnalyzer().addPolygon([.init(x:0.48,y:0.38),.init(x:0.85,y:0.38),.init(x:0.85,y:0.62),.init(x:0.48,y:0.62)],to:&r,rgba:bytes))
        let all = r.leaves.flatMap(\.pixels)
        XCTAssertEqual(Set(all).count,all.count); XCTAssertEqual(r.leaves.count,2)
        XCTAssertTrue(r.leaves.last!.manual); XCTAssertTrue(r.leaves.first!.pending)
    }
    func testDeterministicIDsAndNoTemporalAccumulation() {
        let bytes = fixture { x,y in self.ellipse(x,y) ? self.green : nil }
        let a = analyze(bytes), b = analyze(bytes)
        XCTAssertEqual(a.leaves.map(\.id),b.leaves.map(\.id)); XCTAssertEqual(b.total,1)
    }
    func testCodableRoundTrip() throws {
        let r = analyze(fixture { x,y in self.ellipse(x,y) ? self.yellow : nil })
        let decoded = try JSONDecoder().decode(AnalysisResult.self,from:JSONEncoder().encode(r))
        XCTAssertEqual(decoded.yellow,1); XCTAssertEqual(decoded.leaves[0].pixels,r.leaves[0].pixels)
    }
    func testInvalidInputAndEmptyDenominator() {
        let r = LeafAnalyzer().analyze(rgba: [],width:0,height:0,parameters:.init())
        XCTAssertEqual(r.total,0); XCTAssertEqual(r.yellowAreaRatio,0); XCTAssertEqual(r.yellowCountRatio,0)
    }
}

#if canImport(WPD)
import UIKit
extension WPDTests {
    func testImageRasterOrientationAndVisionContours() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size:CGSize(width:240,height:180),format:format).image { _ in
            UIColor.white.setFill(); UIRectFill(CGRect(x:0,y:0,width:240,height:180))
            UIColor(red:40/255,green:150/255,blue:50/255,alpha:1).setFill()
            UIBezierPath(ovalIn:CGRect(x:40,y:25,width:150,height:25)).fill()
        }
        let prepared = try Imaging.prepare(image,maximum:240)
        var result = analyze(prepared.rgba)
        XCTAssertEqual(result.healthy,1)
        XCTAssertLessThan(result.leaves[0].center.y,0.3)
        Imaging.refineContours(&result)
        XCTAssertFalse(result.leaves[0].contours.isEmpty)
        XCTAssertLessThan(result.leaves[0].contours.flatMap{$0}.map(\.y).max() ?? 1,0.35)
    }
    @MainActor func testHistoryPersistenceAndDeletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordStore(directory: directory)
        let result = analyze(fixture { x,y in self.ellipse(x,y) ? self.green : nil })
        let record = HistoryRecord(date: Date(), result: result)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        try store.save(record, annotatedJPEG: XCTUnwrap(image.jpegData(compressionQuality: 0.9)))

        let index = directory.appendingPathComponent("records.json")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [[String: Any]])
        legacy[0]["material"] = "旧材料"
        legacy[0]["group"] = "A"
        legacy[0]["plant"] = 3
        legacy[0]["corrections"] = []
        try JSONSerialization.data(withJSONObject: legacy).write(to: index)

        let reopened = RecordStore(directory: directory)
        XCTAssertEqual(reopened.records.count, 1)
        XCTAssertEqual(reopened.records.first?.result.total, 1)
        XCTAssertEqual(reopened.records.first?.result.leaves.first?.pixels.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.imageURL(record).path))
        try reopened.delete(record)
        XCTAssertEqual(RecordStore(directory: directory).records.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.imageURL(record).path))
    }

}
#endif

extension WPDTests {
    func testWeakGreenRecoveredOnlyWhenConnectedToStrongGreen() {
        let pale: [UInt8] = [157,180,151,255] // saturation 16%, below the old 22% cutoff
        let bytes = fixture { x,y in
            if self.ellipse(x,y) { return x < 90 ? self.green : pale }
            // A separate weak-green background patch must NOT be promoted.
            if x > 10 && x < 35 && y > 10 && y < 30 { return pale }
            return nil
        }
        let a = LeafAnalyzer()
        let recovered = a.classify(rgba:bytes,parameters:.init(),width:w,height:h)
        var p = AnalysisParameters(); p.recoverGreen = false
        let original = a.classify(rgba:bytes,parameters:p,width:w,height:h)
        XCTAssertEqual(original[90*w+150],0)
        XCTAssertEqual(recovered[90*w+150],1)
        XCTAssertEqual(recovered[20*w+20],0)
        let result = analyze(bytes)
        XCTAssertEqual(result.healthy,1)
        XCTAssertGreaterThan(result.leaves[0].pixels.count,2000)
    }
    func testShadowGreenRecoveredWithoutRecoveringGrayShadow() {
        let bytes = fixture { x,y in
            if self.ellipse(x,y) { return x < 90 ? self.green : [15,26,14,255] }
            if x > 10 && x < 35 && y > 10 && y < 30 { return [25,25,25,255] }
            return nil
        }
        let colors = LeafAnalyzer().classify(rgba:bytes,parameters:.init(),width:w,height:h)
        XCTAssertEqual(colors[90*w+150],1); XCTAssertEqual(colors[20*w+20],0)
    }
    func testCurvedLeafAcceptedWithoutStraightBoundingBox() {
        // A U-shaped blade has poor PCA elongation but a long unbranched centerline.
        let bytes = fixture { x,y in
            let dx = Double(x-120), dy = Double(y-80)
            let radius = sqrt(dx*dx+dy*dy)
            return radius > 52 && radius < 63 && y >= 55 ? self.green : nil
        }
        let r = analyze(bytes)
        XCTAssertEqual(r.leaves.count,1)
        XCTAssertEqual(r.healthy,1, "A curved single blade should not be rejected as a whole plant: \(r.leaves.map(\.warnings))")
    }
    func testConnectedCrownHasDistinctDistalLeafCandidates() {
        let bytes = fixture { x,y in
            let cy = Double(y)
            let stem = abs(x-120) <= 6 && y > 105 && y < 158
            let vertical = abs(x-120) <= 7 && y > 22 && y < 130
            let left = y > 40 && y < 135 && abs(Double(x)-(35+(cy-40)*0.90)) < 6
            let right = y > 40 && y < 135 && abs(Double(x)-(205-(cy-40)*0.90)) < 6
            return stem || vertical || left || right ? self.green : nil
        }
        let r = analyze(bytes)
        XCTAssertGreaterThanOrEqual(r.leaves.count,3)
        XCTAssertEqual(r.total,0) // Ambiguous split is not a measured count.
        XCTAssertEqual(r.pendingCount,r.leaves.count)
        let pixels = r.leaves.flatMap(\.pixels)
        XCTAssertEqual(pixels.count,Set(pixels).count)
        var p = AnalysisParameters(); p.splitContacts = false
        let whole = analyze(bytes,parameters:p)
        XCTAssertGreaterThan(Double(pixels.count)/Double(whole.leaves[0].pixels.count),0.95)
        XCTAssertLessThan(r.leaves.map{ $0.pixels.count }.max()!,whole.leaves[0].pixels.count*3/4)
    }
    func testOldParametersDecodeWithoutNewGreenSetting() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AnalysisParameters())) as? [String:Any])
        json.removeValue(forKey:"recoverGreen")
        let p = try JSONDecoder().decode(AnalysisParameters.self,from:JSONSerialization.data(withJSONObject:json))
        XCTAssertNotEqual(p.recoverGreen,false)
    }
}

#if canImport(WPD) && canImport(UIKit)
import UIKit

extension WPDTests {
    @MainActor
    func testBundledYOLOOnDemoPhoto() async throws {
        let url = try XCTUnwrap(Bundle(for: WPDTests.self).url(forResource: "YOLODemoFixture", withExtension: "png"))
        let image = try XCTUnwrap(UIImage(contentsOfFile: url.path))
        let photo = PhotoModel()
        await photo.analyze(image, parameters: AnalysisParameters())
        XCTAssertNil(photo.error)
        let result = try XCTUnwrap(photo.result)
        XCTAssertEqual(result.recognitionModel, YOLOLeafAnalyzer.modelName)
        // Compare visible instances with the desktop prediction at the same threshold.
        XCTAssertEqual(result.leaves.count, 4)
        XCTAssertTrue(result.leaves.allSatisfy { !$0.pixels.isEmpty && $0.confidence != nil })
        XCTAssertEqual(result.total + result.pendingCount, result.leaves.count)
    }
}
#endif
