import Foundation

struct AnalysisParameters: Codable, Equatable {
    var yellowThreshold = 0.30
    var saturationMinimum = 0.22
    var valueMinimum = 0.12
    var hueMinimum = 15.0
    var hueMaximum = 165.0
    var yellowHueMaximum = 68.0
    var minimumAreaFraction = 0.0006
    var closingRadius = 1
    var splitContacts = true
    // Optional for backwards-compatible decoding of saved parameters and records.
    var recoverGreen: Bool? = true
    var modelConfidence: Double? = 0.25
}

struct LeafPoint: Codable, Equatable {
    var x: Double
    var y: Double
}

struct LeafObject: Codable, Identifiable {
    var id: Int
    var pixels: [Int]
    var boundary: [Int]
    var center: LeafPoint
    var yellowPixels: Int
    var validPixels: Int
    var isYellow: Bool
    var warnings: [String]
    var reviewed = false
    var manual = false
    var contours: [[LeafPoint]] = []
    var confidence: Double?
    var yellowRatio: Double { validPixels == 0 ? 0 : Double(yellowPixels) / Double(validPixels) }
    var pending: Bool { !warnings.isEmpty && !reviewed }
}

struct AnalysisResult: Codable {
    var width: Int
    var height: Int
    var leaves: [LeafObject]
    var parameters: AnalysisParameters
    var milliseconds: Double = 0
    var recognitionModel: String?
    var accepted: [LeafObject] { leaves.filter { !$0.pending } }
    var healthy: Int { accepted.filter { !$0.isYellow }.count }
    var yellow: Int { accepted.filter(\.isYellow).count }
    var total: Int { accepted.count }
    var pendingCount: Int { leaves.filter(\.pending).count }
    var yellowCountRatio: Double { total == 0 ? 0 : Double(yellow) / Double(total) }
    var yellowAreaRatio: Double {
        let area = accepted.reduce(0) { $0 + $1.validPixels }
        return area == 0 ? 0 : Double(accepted.reduce(0) { $0 + $1.yellowPixels }) / Double(area)
    }
}

/// Pure Swift, deterministic, no model/network. Pixel coordinates use a top-left origin.
struct LeafAnalyzer {
    func analyze(rgba: [UInt8], width w: Int, height h: Int, parameters p: AnalysisParameters) -> AnalysisResult {
        let start = Date()
        guard w >= 3, h >= 3, rgba.count == w * h * 4 else {
            return AnalysisResult(width: w, height: h, leaves: [], parameters: p)
        }
        let colors = classify(rgba: rgba, parameters: p, width: w, height: h)
        let raw = colors.map { $0 > 0 }
        var mask = raw
        // Closing connects small holes within a leaf; tiny components are removed by area.
        for _ in 0..<max(0, min(3, p.closingRadius)) { mask = morphology(mask, w, h, dilate: true) }
        for _ in 0..<max(0, min(3, p.closingRadius)) { mask = morphology(mask, w, h, dilate: false) }
        let minimum = max(12, Int(Double(w * h) * p.minimumAreaFraction))
        var leaves: [LeafObject] = []
        for component in components(mask, w, h) where component.count >= minimum {
            let groups = p.splitContacts && component.count <= w*h/3 ? split(component, w, h, minimum) : [component]
            for group in groups where group.count >= minimum {
                var object = makeObject(group, colors, w, h, p, id: leaves.count + 1)
                if groups.count > 1 { object.warnings.append("接触区域自动分离，请核对边界") }
                leaves.append(object)
            }
        }
        leaves.sort { $0.center.y == $1.center.y ? $0.center.x < $1.center.x : $0.center.y < $1.center.y }
        for i in leaves.indices { leaves[i].id = i + 1 }
        return AnalysisResult(width: w, height: h, leaves: leaves, parameters: p,
                              milliseconds: Date().timeIntervalSince(start) * 1000)
    }

    func classify(rgba: [UInt8], parameters p: AnalysisParameters, width: Int = 0, height: Int = 0) -> [UInt8] {
        var colors = [UInt8](repeating: 0, count: rgba.count / 4)
        var weakGreen = [Bool](repeating: false, count: colors.count)
        for i in colors.indices {
            let r = Double(rgba[i * 4]) / 255, g = Double(rgba[i * 4 + 1]) / 255, b = Double(rgba[i * 4 + 2]) / 255
            let v = max(r, g, b), low = min(r, g, b), d = v - low
            guard d > 0, v > 0 else { continue }
            var hue: Double
            if v == r { hue = 60 * ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if v == g { hue = 60 * ((b - r) / d + 2) }
            else { hue = 60 * ((r - g) / d + 4) }
            if hue < 0 { hue += 360 }
            guard hue >= p.hueMinimum && hue <= p.hueMaximum else { continue }
            if v >= p.valueMinimum && d / v >= p.saturationMinimum {
                colors[i] = hue <= p.yellowHueMaximum ? 2 : 1
            } else if p.recoverGreen != false && hue > p.yellowHueMaximum &&
                        v >= p.valueMinimum * 0.55 && d / v >= max(0.06, p.saturationMinimum * 0.45) &&
                        g > r * 1.035 && g > b * 1.06 && 2*g-r-b > 0.035 {
                weakGreen[i] = true
            }
        }
        // Hysteresis: only grow weak green from a strong green seed. A pale green
        // backdrop with no seed stays background; hue limits still apply.
        if width > 0 && height > 0 && width * height == colors.count {
            var queue = colors.indices.filter { colors[$0] == 1 }, head = 0
            while head < queue.count {
                let i = queue[head]; head += 1
                for n in neighbors(i, width, height) where weakGreen[n] && colors[n] == 0 {
                    colors[n] = 1; queue.append(n)
                }
            }
        }
        return colors
    }

    func neighbors(_ i: Int, _ w: Int, _ h: Int) -> [Int] {
        let x = i % w, y = i / w
        var n: [Int] = []
        if x > 0 { n.append(i - 1) }; if x + 1 < w { n.append(i + 1) }
        if y > 0 { n.append(i - w) }; if y + 1 < h { n.append(i + w) }
        return n
    }

    func morphology(_ mask: [Bool], _ w: Int, _ h: Int, dilate: Bool) -> [Bool] {
        var out = mask
        for y in 0..<h { for x in 0..<w {
            var value = !dilate
            for dy in -1...1 { for dx in -1...1 {
                let xx = x + dx, yy = y + dy
                let on = xx >= 0 && xx < w && yy >= 0 && yy < h ? mask[yy * w + xx] : false
                if dilate { value = value || on } else { value = value && on }
            } }
            out[y * w + x] = value
        } }
        return out
    }

    func components(_ mask: [Bool], _ w: Int, _ h: Int) -> [[Int]] {
        var seen = [Bool](repeating: false, count: mask.count), result: [[Int]] = []
        for i in mask.indices where mask[i] && !seen[i] {
            var queue = [i], head = 0
            seen[i] = true
            while head < queue.count {
                let current = queue[head]; head += 1
                for n in neighbors(current, w, h) where mask[n] && !seen[n] { seen[n] = true; queue.append(n) }
            }
            result.append(queue)
        }
        return result
    }

    /// Erosion-derived markers and a geodesic multi-source flood (marker watershed approximation).
    /// Splits are ALWAYS provisional: a narrow neck can also belong to one damaged leaf.
    func split(_ component: [Int], _ w: Int, _ h: Int, _ minimum: Int) -> [[Int]] {
        let xs = component.map { $0 % w }, ys = component.map { $0 / w }
        let x0 = max(0, xs.min()! - 1), y0 = max(0, ys.min()! - 1)
        let cw = min(w - 1, xs.max()! + 1) - x0 + 1, ch = min(h - 1, ys.max()! + 1) - y0 + 1
        var local = [Bool](repeating: false, count: cw * ch)
        for i in component { local[(i / w - y0) * cw + i % w - x0] = true }
        // Distal centerline branches survive when all leaf bases share a broad crown.
        // Use them before erosion; erosion alone loses thin leaves before the crown separates.
        let graph = centerline(component,w)
        if let graph {
            let paths = terminalPaths(graph)
            if paths.count == 2, let path = paths.first, let a = path.first, let b = path.last {
                let chord = hypot(Double(a%graph.w-b%graph.w),Double(a/graph.w-b/graph.w))
                var arc = 0.0
                for i in 1..<path.count {
                    arc += hypot(Double(path[i]%graph.w-path[i-1]%graph.w),Double(path[i]/graph.w-path[i-1]/graph.w))
                }
                // A long, unbranched curved blade must not be broken by square erosion.
                if arc > chord * 1.18 && pow(arc*Double(graph.step),2)/Double(component.count) > 4.5 { return [component] }
            }
        }
        if let branches = splitBranches(component, w, h, minimum, graph: graph) { return branches }
        var eroded = local
        for _ in 0..<min(10, max(2, min(cw, ch) / 8)) {
            eroded = morphology(eroded, cw, ch, dilate: false)
            let seeds = components(eroded, cw, ch).filter { $0.count >= max(8, minimum / 3) }
            if seeds.count > 1 && seeds.count <= 12 {
                var labels = [Int](repeating: -1, count: local.count), queue: [Int] = []
                for (label, seed) in seeds.enumerated() { for i in seed { labels[i] = label; queue.append(i) } }
                var head = 0
                while head < queue.count {
                    let i = queue[head]; head += 1
                    for n in neighbors(i, cw, ch) where local[n] && labels[n] == -1 {
                        labels[n] = labels[i]; queue.append(n)
                    }
                }
                var groups = [[Int]](repeating: [], count: seeds.count)
                for i in local.indices where labels[i] >= 0 { groups[labels[i]].append((i / cw + y0) * w + i % cw + x0) }
                if groups.allSatisfy({ $0.count >= minimum }) { return groups }
            }
            if seeds.isEmpty { break }
        }
        return [component]
    }

    func makeObject(_ pixels: [Int], _ colors: [UInt8], _ w: Int, _ h: Int, _ p: AnalysisParameters, id: Int) -> LeafObject {
        let set = Set(pixels)
        let boundary = pixels.filter { i in neighbors(i, w, h).count < 4 || neighbors(i, w, h).contains { !set.contains($0) } }
        let cx = pixels.reduce(0.0) { $0 + Double($1 % w) } / Double(max(1, pixels.count))
        let cy = pixels.reduce(0.0) { $0 + Double($1 / w) } / Double(max(1, pixels.count))
        var xx = 0.0, yy = 0.0, xy = 0.0
        for i in pixels { let x = Double(i % w) - cx, y = Double(i / w) - cy; xx += x*x; yy += y*y; xy += x*y }
        let delta = sqrt((xx-yy)*(xx-yy) + 4*xy*xy)
        let elongation = sqrt((xx+yy+delta) / max(1, xx+yy-delta))
        let angle = 0.5 * atan2(2*xy, xx-yy), c = cos(angle), s = sin(angle)
        var minA = Double.infinity, maxA = -Double.infinity, minB = Double.infinity, maxB = -Double.infinity
        for i in pixels {
            let x = Double(i % w) - cx, y = Double(i / w) - cy
            let a = x*c+y*s, b = -x*s+y*c
            minA = min(minA,a); maxA = max(maxA,a); minB = min(minB,b); maxB = max(maxB,b)
        }
        let fill = Double(pixels.count) / max(1, (maxA-minA+1)*(maxB-minB+1))
        var warnings: [String] = []
        let skeleton = pixels.count <= w*h/3 ? centerline(pixels, w) : nil
        let tips = skeleton.map { terminalPaths($0).count } ?? 0
        // Arc-length / effective width recognizes a bent blade, unlike a straight PCA box.
        let length = skeleton.map { Double($0.mask.filter { $0 }.count * $0.step) } ?? 0
        let curvedBlade = tips == 2 && length * length / Double(max(1,pixels.count)) >= 4.5
        if tips > 2 { warnings.append("骨架存在多个叶尖：可能为连接植株，请人工划分") }
        if !curvedBlade && (elongation < 2.0 || fill < 0.42) { warnings.append("形状不明确：可能为整株、重叠或背景") }
        if pixels.count > w*h/3 { warnings.append("区域过大，请检查背景或整株连接") }
        if pixels.contains(where: { $0 % w <= 1 || $0 % w >= w-2 || $0 / w <= 1 || $0 / w >= h-2 }) { warnings.append("叶片接近画面边缘") }
        let valid = pixels.filter { colors[$0] > 0 }.count
        let yellow = pixels.filter { colors[$0] == 2 }.count
        if valid < pixels.count * 3 / 4 { warnings.append("区域内部颜色不确定") }
        let ratio = valid == 0 ? 0 : Double(yellow)/Double(valid)
        if abs(ratio-p.yellowThreshold) < 0.04 { warnings.append("接近分类阈值") }
        return LeafObject(id: id, pixels: pixels, boundary: boundary,
                          center: LeafPoint(x: cx/Double(w), y: cy/Double(h)), yellowPixels: yellow,
                          validPixels: valid, isYellow: ratio >= p.yellowThreshold, warnings: warnings)
    }

    struct Centerline {
        var mask: [Bool]
        let w: Int
        let h: Int
        let x0: Int
        let y0: Int
        let step: Int
    }

    func graphNeighbors(_ i: Int, _ graph: Centerline) -> [Int] {
        let w = graph.w, h = graph.h, x = i % w, y = i / w
        var result: [Int] = []
        for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
            let xx = x+dx, yy = y+dy
            guard xx >= 0, xx < w, yy >= 0, yy < h, graph.mask[yy*w+xx] else { continue }
            // Suppress diagonal shortcuts around a right-angle skeleton junction.
            if dx != 0 && dy != 0 && (graph.mask[y*w+xx] || graph.mask[yy*w+x]) { continue }
            result.append(yy*w+xx)
        } }
        return result
    }

    func terminalPaths(_ graph: Centerline) -> [[Int]] {
        var paths: [[Int]] = []
        for i in graph.mask.indices where graph.mask[i] && graphNeighbors(i, graph).count == 1 {
            var path = [i], previous = -1, current = i
            while path.count <= graph.mask.count {
                let next = graphNeighbors(current,graph).filter { $0 != previous }
                guard next.count == 1 else { break }
                previous = current; current = next[0]
                path.append(current)
                if graphNeighbors(current,graph).count != 2 { break }
            }
            paths.append(path)
        }
        return paths
    }

    /// Bounded Zhang–Suen thinning with removal of short contour spurs.
    func centerline(_ pixels: [Int], _ width: Int) -> Centerline? {
        guard let first = pixels.first else { return nil }
        var x0 = first % width, x1 = x0, y0 = first / width, y1 = y0
        for p in pixels { x0 = min(x0,p % width); x1 = max(x1,p % width); y0 = min(y0,p / width); y1 = max(y1,p / width) }
        let step = max(1, (max(x1-x0,y1-y0)+256)/256)
        let w = (x1-x0)/step+5, h = (y1-y0)/step+5
        var mask = [Bool](repeating: false, count: w*h)
        for p in pixels { mask[((p/width-y0)/step+2)*w+(p%width-x0)/step+2] = true }
        // Close sampling pinholes so leaf veins do not create false centerline loops.
        mask = morphology(morphology(mask,w,h,dilate:true),w,h,dilate:false)
        for _ in 0..<max(w,h) {
            var changed = false
            for phase in 0...1 {
                var remove: [Int] = []
                for y in 1..<(h-1) { for x in 1..<(w-1) {
                    let i = y*w+x
                    guard mask[i] else { continue }
                    let n = [mask[i-w],mask[i-w+1],mask[i+1],mask[i+w+1],mask[i+w],mask[i+w-1],mask[i-1],mask[i-w-1]]
                    let count = n.filter { $0 }.count
                    guard count >= 2 && count <= 6 else { continue }
                    var transitions = 0
                    for k in 0..<8 { if !n[k] && n[(k+1)%8] { transitions += 1 } }
                    guard transitions == 1 else { continue }
                    let a = phase == 0 ? n[0] && n[2] && n[4] : n[0] && n[2] && n[6]
                    let b = phase == 0 ? n[2] && n[4] && n[6] : n[0] && n[4] && n[6]
                    if !a && !b { remove.append(i) }
                } }
                if !remove.isEmpty { changed = true; for i in remove { mask[i] = false } }
            }
            if !changed { break }
        }
        var graph = Centerline(mask:mask,w:w,h:h,x0:x0-2*step,y0:y0-2*step,step:step)
        for _ in 0..<8 {
            let paths = terminalPaths(graph)
            let limit = max(3,Int(Double(paths.map(\.count).max() ?? 0)*0.08))
            let spurs = paths.filter { $0.count < limit && graphNeighbors($0.last!,graph).count > 2 }
            if spurs.isEmpty { break }
            for path in spurs { for i in path.dropLast() { graph.mask[i] = false } }
        }
        return graph
    }

    func skeletonEndpoints(_ pixels: [Int], _ width: Int) -> Int {
        centerline(pixels,width).map { terminalPaths($0).count } ?? 0
    }

    /// Terminal centerlines seed a geodesic instance partition. The crown / stem gets
    /// its own residual marker and is never silently assigned to a healthy leaf.
    func splitBranches(_ pixels: [Int], _ w: Int, _ h: Int, _ minimum: Int, graph: Centerline?) -> [[Int]]? {
        guard let graph else { return nil }
        let paths = terminalPaths(graph)
        let longest = paths.map(\.count).max() ?? 0
        let candidates = paths.filter { $0.count >= max(8,Int(Double(longest)*0.16)) }
        guard candidates.count >= 3, candidates.count <= 16 else { return nil }
        let x0 = pixels.map { $0%w }.min()!, y0 = pixels.map { $0/w }.min()!
        let cw = pixels.map { $0%w }.max()!-x0+1, ch = pixels.map { $0/w }.max()!-y0+1
        var inside = [Bool](repeating:false,count:cw*ch)
        for i in pixels { inside[(i/w-y0)*cw+i%w-x0] = true }
        var labels = [Int](repeating:-1,count:inside.count), queue: [Int] = []
        // Continue through a junction only along a compatible tangent. Shared
        // continuation stays ambiguous rather than being owned by the first leaf.
        let distal = Set(candidates.flatMap { $0.dropLast() })
        var extended: [[Int]] = []
        for original in candidates {
            var path = original, visited = Set(original)
            while path.count < original.count * 2 {
                let current = path.last!, anchor = path[max(0,path.count-7)]
                let vx = Double(current%graph.w-anchor%graph.w), vy = Double(current/graph.w-anchor/graph.w)
                let norm = hypot(vx,vy)
                guard norm > 0 else { break }
                let options = graphNeighbors(current,graph).filter { !visited.contains($0) && !distal.contains($0) }
                let ranked = options.map { node -> (Int,Double) in
                    let dx = Double(node%graph.w-current%graph.w), dy = Double(node/graph.w-current/graph.w)
                    return (node,(vx*dx+vy*dy)/(norm*hypot(dx,dy)))
                }.sorted { $0.1 > $1.1 }
                guard let best = ranked.first, best.1 >= 0.55 else { break }
                // Near-equal outgoing directions cannot be resolved from this silhouette.
                if ranked.count > 1 && best.1-ranked[1].1 < 0.12 { break }
                path.append(best.0); visited.insert(best.0)
            }
            extended.append(path)
        }
        var owners = [Int](repeating:-1,count:graph.mask.count)
        for (label,path) in extended.enumerated() {
            for node in path.dropLast(2) {
                if owners[node] == -1 { owners[node] = label }
                else if owners[node] != label { owners[node] = -2 }
            }
        }
        func seed(_ node: Int, _ label: Int) {
            let gx = graph.x0+(node%graph.w)*graph.step, gy = graph.y0+(node/graph.w)*graph.step
            for dy in 0..<graph.step { for dx in 0..<graph.step {
                let x = gx+dx-x0, y = gy+dy-y0
                if x >= 0 && x < cw && y >= 0 && y < ch {
                    let i = y*cw+x
                    if inside[i] && labels[i] == -1 { labels[i] = label; queue.append(i) }
                }
            } }
        }
        for node in graph.mask.indices where graph.mask[node] && owners[node] >= 0 { seed(node,owners[node]) }
        let residual = candidates.count
        for node in graph.mask.indices where graph.mask[node] && owners[node] < 0 { seed(node,residual) }
        var head = 0
        while head < queue.count {
            let i = queue[head]; head += 1
            for n in neighbors(i,cw,ch) where inside[n] && labels[n] == -1 {
                labels[n] = labels[i]; queue.append(n)
            }
        }
        var groups = [[Int]](repeating:[],count:candidates.count+1)
        for i in inside.indices where inside[i] {
            let label = labels[i] < 0 ? residual : labels[i]
            groups[label].append((i/cw+y0)*w+i%cw+x0)
        }
        // Require multiple substantial distal regions, otherwise keep the unsplit object.
        guard groups.prefix(candidates.count).filter({$0.count >= minimum}).count >= 3 else { return nil }
        return groups.filter { !$0.isEmpty }
    }

    /// Manual polygons own their pixels exclusively. Existing objects lose these pixels.
    func addPolygon(_ points: [LeafPoint], to result: inout AnalysisResult, rgba: [UInt8]) -> Bool {
        guard points.count >= 3 else { return false }
        let w = result.width, h = result.height
        var pixels: [Int] = []
        for y in 0..<h { for x in 0..<w {
            let px = (Double(x)+0.5)/Double(w), py = (Double(y)+0.5)/Double(h)
            var inside = false, j = points.count-1
            for i in points.indices {
                let a = points[i], b = points[j]
                if (a.y > py) != (b.y > py), px < (b.x-a.x)*(py-a.y)/(b.y-a.y)+a.x { inside.toggle() }
                j = i
            }
            if inside { pixels.append(y*w+x) }
        } }
        guard pixels.count >= 5 else { return false }
        let colors = classify(rgba: rgba, parameters: result.parameters, width: w, height: h), claimed = Set(pixels)
        let nextID = (result.leaves.map(\.id).max() ?? 0) + 1
        result.leaves = result.leaves.compactMap { old in
            let remaining = old.pixels.filter { !claimed.contains($0) }
            guard !remaining.isEmpty else { return nil }
            if remaining.count == old.pixels.count { return old }
            var revised = makeObject(remaining, colors, w, h, result.parameters, id: old.id)
            if result.recognitionModel != nil { revised.isYellow = old.isYellow }
            revised.warnings.append("人工划分后剩余区域，请复核")
            return revised
        }
        var leaf = makeObject(pixels, colors, w, h, result.parameters, id: nextID)
        // A human traced the whole tissue: include low saturation pixels in its effective area.
        leaf.validPixels = pixels.count
        leaf.isYellow = leaf.yellowRatio >= result.parameters.yellowThreshold
        leaf.manual = true
        if result.recognitionModel == nil {
            leaf.reviewed = true
        } else {
            leaf.isYellow = false
            leaf.warnings = ["请为新增叶片选择健康或枯黄"]
        }
        result.leaves.append(leaf)
        return true
    }
}
