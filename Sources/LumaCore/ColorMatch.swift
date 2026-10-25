import Foundation
import CoreImage

// Independent implementation of Lab cluster transfer and quantile tone mapping.
// Input/output RGB is extended, linear Display P3, including values outside 0...1.
public struct LabColor: Equatable {
    public var lightness: Double
    public var a: Double
    public var b: Double
    public init(lightness: Double, a: Double, b: Double) {
        self.lightness = lightness; self.a = a; self.b = b
    }
    public static func fromLinearP3(_ rgb: [Double]) -> LabColor {
        precondition(rgb.count == 3)
        let x = (0.4865709486 * rgb[0] + 0.2656676932 * rgb[1] + 0.1982172852 * rgb[2]) / 0.9504559271
        let y = 0.2289745641 * rgb[0] + 0.6917385218 * rgb[1] + 0.0792869141 * rgb[2]
        let z = (0.0451133819 * rgb[1] + 1.0439443689 * rgb[2]) / 1.0890577508
        func f(_ t: Double) -> Double { t > 0.00885645168 ? cbrt(t) : 7.787037037 * t + 4.0 / 29 }
        let fx = f(x), fy = f(y), fz = f(z)
        return LabColor(lightness: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }
    public var linearP3: [Double] {
        let fy = (lightness + 16) / 116, fx = fy + a / 500, fz = fy - b / 200
        func inverse(_ t: Double) -> Double { t > 6.0 / 29 ? t * t * t : (t - 4.0 / 29) / 7.787037037 }
        let x = inverse(fx) * 0.9504559271, y = inverse(fy), z = inverse(fz) * 1.0890577508
        return [2.4934969119 * x - 0.9313836179 * y - 0.4027107845 * z,
                -0.8294889696 * x + 1.7626640603 * y + 0.02362468584 * z,
                0.03584583024 * x - 0.07617238927 * y + 0.95688452401 * z]
    }
}

public struct ColorCluster: Codable, Equatable {
    public var meanA: Double
    public var meanB: Double
    public var meanL: Double
    public var stdA: Double
    public var stdB: Double
    public var weight: Double
    public init(meanA: Double, meanB: Double, meanL: Double, stdA: Double, stdB: Double, weight: Double) {
        self.meanA = meanA; self.meanB = meanB; self.meanL = meanL
        self.stdA = stdA; self.stdB = stdB; self.weight = weight
    }
    public var linearP3Swatch: [Double] { LabColor(lightness: meanL, a: meanA, b: meanB).linearP3 }
    fileprivate var vector: CIVector { CIVector(x: meanA, y: meanB, z: stdA, w: stdB) }
}

public struct MatchAnalysis: Equatable {
    public let clusters: [ColorCluster]
    public let lightnessSamples: [Double]
    public init(clusters: [ColorCluster], lightnessSamples: [Double]) {
        self.clusters = clusters; self.lightnessSamples = lightnessSamples
    }
    public static func analyze(_ samples: [LabColor], clusterCount: Int) throws -> MatchAnalysis {
        guard (1...5).contains(clusterCount) else { throw EditorError.message("颜色分组应为 1 到 5。") }
        let points = samples.filter { $0.lightness.isFinite && $0.a.isFinite && $0.b.isFinite &&
            (-400...400).contains($0.a) && (-400...400).contains($0.b) }
        guard points.count >= 32 else { throw EditorError.message("有效像素太少，无法分析追色。") }
        try Task.checkCancellation()
        func distance(_ p: LabColor, _ q: LabColor) -> Double {
            let a = p.a - q.a, b = p.b - q.b; return a * a + b * b
        }
        // Deterministic farthest-point initialization; flat images naturally use fewer groups.
        let mean = LabColor(lightness: 0,
                            a: points.reduce(0) { $0 + $1.a } / Double(points.count),
                            b: points.reduce(0) { $0 + $1.b } / Double(points.count))
        var centers = [points.min(by: { distance($0, mean) < distance($1, mean) })!]
        var nearest = points.map { distance($0, centers[0]) }
        while centers.count < clusterCount {
            let index = nearest.indices.max(by: { nearest[$0] < nearest[$1] })!
            guard nearest[index] > 0.04 else { break }
            centers.append(points[index])
            for i in points.indices { nearest[i] = min(nearest[i], distance(points[i], points[index])) }
        }
        var assignments = [Int](repeating: 0, count: points.count)
        for _ in 0..<32 {
            try Task.checkCancellation()
            var sumsA = [Double](repeating: 0, count: centers.count), sumsB = sumsA
            var counts = [Int](repeating: 0, count: centers.count)
            for (i, point) in points.enumerated() {
                var best = 0, bestDistance = Double.infinity
                for k in centers.indices {
                    let d = distance(point, centers[k])
                    if d < bestDistance { best = k; bestDistance = d }
                }
                assignments[i] = best; sumsA[best] += point.a; sumsB[best] += point.b; counts[best] += 1
            }
            var movement = 0.0
            for k in centers.indices where counts[k] > 0 {
                let next = LabColor(lightness: 0, a: sumsA[k] / Double(counts[k]), b: sumsB[k] / Double(counts[k]))
                movement = max(movement, distance(centers[k], next)); centers[k] = next
            }
            if movement < 0.0001 { break }
        }
        // Reassign against the final centers, then compute population variance.
        var counts = [Int](repeating: 0, count: centers.count)
        var sumA = [Double](repeating: 0, count: centers.count), sumB = sumA, sumL = sumA
        for (i, point) in points.enumerated() {
            let k = centers.indices.min(by: { distance(point, centers[$0]) < distance(point, centers[$1]) })!
            assignments[i] = k; counts[k] += 1
            sumA[k] += point.a; sumB[k] += point.b; sumL[k] += point.lightness
        }
        var varA = [Double](repeating: 0, count: centers.count), varB = varA
        for (i, point) in points.enumerated() {
            let k = assignments[i], count = Double(counts[k])
            varA[k] += pow(point.a - sumA[k] / count, 2); varB[k] += pow(point.b - sumB[k] / count, 2)
        }
        let clusters = centers.indices.compactMap { k -> ColorCluster? in
            guard counts[k] > 0 else { return nil }
            let n = Double(counts[k])
            return ColorCluster(meanA: sumA[k] / n, meanB: sumB[k] / n,
                                meanL: min(100, max(0, sumL[k] / n)),
                                stdA: max(1.5, sqrt(varA[k] / n)), stdB: max(1.5, sqrt(varB[k] / n)),
                                weight: n / Double(points.count))
        }.sorted { lhs, rhs in
            if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
            if lhs.meanA != rhs.meanA { return lhs.meanA < rhs.meanA }
            return lhs.meanB < rhs.meanB
        }
        return MatchAnalysis(clusters: clusters, lightnessSamples: points.map { min(100, max(0, $0.lightness)) }.sorted())
    }
}

public struct ColorMatch: Codable, Equatable {
    public let algorithm: String
    public let sourceClusters: [ColorCluster]
    public let referenceClusters: [ColorCluster]
    public let referenceName: String
    public let referenceSHA256: String
    public let toneCurve: [Double]
    public var colorStrength = 0.75
    public var luminanceStrength = 0.0
    public var dominance = 0.25

    public static func make(source: MatchAnalysis, reference: MatchAnalysis,
                            referenceName: String, referenceSHA256: String) throws -> ColorMatch {
        guard source.lightnessSamples.count >= 32, reference.lightnessSamples.count >= 32,
              source.lightnessSamples.allSatisfy({ $0.isFinite && (0...100).contains($0) }),
              reference.lightnessSamples.allSatisfy({ $0.isFinite && (0...100).contains($0) }) else {
            throw EditorError.message("追色分析的明暗分布无效。")
        }
        let value = ColorMatch(algorithm: "lab-clusters-quantiles-v2", sourceClusters: source.clusters,
                               referenceClusters: reference.clusters, referenceName: referenceName,
                               referenceSHA256: referenceSHA256,
                               toneCurve: makeToneCurve(source.lightnessSamples.sorted(), reference.lightnessSamples.sorted()))
        try value.validate(); return value
    }
    public func validate() throws {
        func valid(_ clusters: [ColorCluster]) -> Bool {
            (1...5).contains(clusters.count) && clusters.allSatisfy {
                [$0.meanA, $0.meanB, $0.meanL, $0.stdA, $0.stdB, $0.weight].allSatisfy { $0.isFinite } &&
                (-400...400).contains($0.meanA) && (-400...400).contains($0.meanB) && (0...100).contains($0.meanL) &&
                (1.5...400).contains($0.stdA) && (1.5...400).contains($0.stdB) && (0.0000001...1).contains($0.weight)
            } && abs(clusters.reduce(0) { $0 + $1.weight } - 1) < 0.00001
        }
        guard ["lab-clusters-quantiles-v1", "lab-clusters-quantiles-v2"].contains(algorithm), valid(sourceClusters), valid(referenceClusters),
              !referenceName.isEmpty, referenceName.count <= 1024,
              referenceSHA256.count == 64, referenceSHA256.allSatisfy({ $0.isHexDigit }),
              [colorStrength, luminanceStrength, dominance].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              toneCurve.count == 257, toneCurve.allSatisfy({ $0.isFinite && (0...100).contains($0) }),
              toneCurve.first == 0, toneCurve.last == 100,
              zip(toneCurve, toneCurve.dropFirst()).allSatisfy({ $0 <= $1 }) else {
            throw EditorError.message("追色配方包含无效的颜色分组、强度或明暗曲线。")
        }
    }
    public func mappedReferenceClusters() -> [ColorCluster] {
        func score(_ source: ColorCluster, _ ref: ColorCluster) -> Double {
            let color = (pow(source.meanA - ref.meanA, 2) + pow(source.meanB - ref.meanB, 2)) / 14400
            return (1 - dominance + 0.000001) * color + dominance * pow(source.weight - ref.weight, 2)
        }
        // Preserve existing embedded recipes; only newly analyzed matches use
        // a global assignment that represents as many reference groups as possible.
        if algorithm == "lab-clusters-quantiles-v2" {
            let required = min(sourceClusters.count, referenceClusters.count)
            var bestCost = Double.infinity, best: [Int] = []
            func search(_ assignment: [Int], used: Set<Int>, cost: Double) {
                guard cost < bestCost,
                      used.count + sourceClusters.count - assignment.count >= required else { return }
                if assignment.count == sourceClusters.count {
                    if used.count == required { best = assignment; bestCost = cost }
                    return
                }
                for index in referenceClusters.indices {
                    if sourceClusters.count <= referenceClusters.count && used.contains(index) { continue }
                    search(assignment + [index], used: used.union([index]),
                           cost: cost + score(sourceClusters[assignment.count], referenceClusters[index]))
                }
            }
            search([], used: [], cost: 0)
            return best.map { referenceClusters[$0] }
        }
        return sourceClusters.map { source in
            referenceClusters.min { lhs, rhs in
                return score(source, lhs) < score(source, rhs)
            }!
        }
    }
    public func mapped(_ lab: LabColor) -> LabColor {
        var result = lab
        if colorStrength > 0 {
            var sumA = 0.0, sumB = 0.0, sumWeight = 0.0
            for (source, reference) in zip(sourceClusters, mappedReferenceClusters()) {
                let da = lab.a - source.meanA, db = lab.b - source.meanB
                let weight = 1 / (da * da + db * db + 0.001)
                let a = reference.meanA + da * min(2, max(0.5, reference.stdA / source.stdA))
                let b = reference.meanB + db * min(2, max(0.5, reference.stdB / source.stdB))
                sumA += a * weight; sumB += b * weight; sumWeight += weight
            }
            result.a += colorStrength * (sumA / sumWeight - lab.a)
            result.b += colorStrength * (sumB / sumWeight - lab.b)
        }
        // Preserve extended highlights/blacks; the statistical tone curve covers SDR L* only.
        if luminanceStrength > 0 && (0...100).contains(lab.lightness) {
            let position = lab.lightness * 2.56, lower = min(255, Int(position)), fraction = position - Double(lower)
            let mappedL = toneCurve[lower] * (1 - fraction) + toneCurve[lower + 1] * fraction
            result.lightness += luminanceStrength * (mappedL - lab.lightness)
        }
        return result
    }
    private static func makeToneCurve(_ source: [Double], _ reference: [Double]) -> [Double] {
        func quantile(_ sorted: [Double], _ p: Double) -> Double {
            let position = p * Double(sorted.count - 1), index = Int(position), fraction = position - Double(index)
            return sorted[index] * (1 - fraction) + sorted[min(index + 1, sorted.count - 1)] * fraction
        }
        let identity = (0...256).map { Double($0) * 100 / 256 }
        guard quantile(source, 0.99) - quantile(source, 0.01) >= 1 else { return identity }
        // 63 interior quantiles prevent a staircase CDF; endpoints keep black/white anchored.
        var anchors: [(Double, Double)] = [(0, 0)]
        for i in 1..<64 {
            let p = Double(i) / 64, x = quantile(source, p), y = quantile(reference, p)
            guard x > 0.00001, x < 99.99999 else { continue }
            if let last = anchors.last, abs(last.0 - x) < 0.00001 {
                anchors[anchors.count - 1].1 = y // Rightmost quantile for repeated values.
            } else { anchors.append((x, y)) }
        }
        anchors.append((100, 100))
        var index = 0
        return identity.map { l in
            while index + 1 < anchors.count - 1 && l > anchors[index + 1].0 { index += 1 }
            let (x0, y0) = anchors[index], (x1, y1) = anchors[index + 1]
            let t = (l - x0) / (x1 - x0)
            return min(100, max(0, y0 + t * (y1 - y0)))
        }
    }

    // The same floating-point kernel is used for previews and full-resolution exports.
    func applying(to image: CIImage) throws -> CIImage {
        try validate()
        if colorStrength == 0 && luminanceStrength == 0 { return image }
        guard let kernel = Self.kernel else { throw EditorError.message("此系统无法创建追色渲染内核。") }
        let curvePixels = toneCurve.flatMap { [Float($0 / 100), Float(0), Float(0), Float(1)] }
        let curve = curvePixels.withUnsafeBytes { bytes in
            CIImage(bitmapData: Data(bytes), bytesPerRow: 257 * 16, size: CGSize(width: 257, height: 1), format: .RGBAf, colorSpace: ImageEngine.workingSpace)
        }
        let mapped = mappedReferenceClusters()
        var arguments: [Any] = [image, curve, Double(sourceClusters.count), colorStrength, luminanceStrength]
        for i in 0..<5 {
            arguments.append(sourceClusters[min(i, sourceClusters.count - 1)].vector)
            arguments.append(mapped[min(i, mapped.count - 1)].vector)
        }
        guard let result = kernel.apply(extent: image.extent, roiCallback: { index, rect in index == 1 ? curve.extent : rect }, arguments: arguments) else {
            throw EditorError.message("追色渲染失败。")
        }
        return result
    }

    // Core Image Kernel Language is compiled by Core Image, with no external shader toolchain.
    private static let kernel = CIKernel(source: """
        float labf(float t) { return t > 0.00885645168 ? pow(t, 0.3333333333) : 7.787037037 * t + 0.1379310345; }
        float labinv(float t) { return t > 0.2068965517 ? t*t*t : (t - 0.1379310345) / 7.787037037; }
        vec3 contribution(vec2 ab, vec4 source, vec4 target) {
            vec2 d = ab - source.xy;
            float w = 1.0 / (dot(d, d) + 0.001);
            vec2 mapped = target.xy + d * clamp(target.zw / source.zw, vec2(0.5), vec2(2.0));
            return vec3(mapped * w, w);
        }
        kernel vec4 colorMatch(__sample pixel, sampler curve, float count, float colorStrength, float toneStrength,
                               vec4 s0, vec4 t0, vec4 s1, vec4 t1, vec4 s2, vec4 t2, vec4 s3, vec4 t3, vec4 s4, vec4 t4) {
            if (pixel.a <= 0.00001) return pixel;
            vec3 rgb = pixel.rgb / pixel.a;
            float x = dot(rgb, vec3(0.4865709486, 0.2656676932, 0.1982172852)) / 0.9504559271;
            float y = dot(rgb, vec3(0.2289745641, 0.6917385218, 0.0792869141));
            float z = dot(rgb, vec3(0.0, 0.0451133819, 1.0439443689)) / 1.0890577508;
            float fx = labf(x), fy = labf(y), fz = labf(z);
            float lightness = 116.0 * fy - 16.0;
            vec2 ab = vec2(500.0 * (fx - fy), 200.0 * (fy - fz));
            if (colorStrength > 0.0) {
                vec3 sum = contribution(ab, s0, t0);
                if (count > 1.5) sum += contribution(ab, s1, t1);
                if (count > 2.5) sum += contribution(ab, s2, t2);
                if (count > 3.5) sum += contribution(ab, s3, t3);
                if (count > 4.5) sum += contribution(ab, s4, t4);
                ab = mix(ab, sum.xy / sum.z, colorStrength);
            }
            if (toneStrength > 0.0 && lightness >= 0.0 && lightness <= 100.0) {
                float position = lightness * 2.56;
                float lower = min(255.0, floor(position));
                float l0 = sample(curve, vec2(lower + 0.5, 0.5)).r * 100.0;
                float l1 = sample(curve, vec2(lower + 1.5, 0.5)).r * 100.0;
                lightness = mix(lightness, mix(l0, l1, position - lower), toneStrength);
            }
            fy = (lightness + 16.0) / 116.0; fx = fy + ab.x / 500.0; fz = fy - ab.y / 200.0;
            vec3 xyz = vec3(labinv(fx) * 0.9504559271, labinv(fy), labinv(fz) * 1.0890577508);
            vec3 result = vec3(dot(xyz, vec3(2.4934969119, -0.9313836179, -0.4027107845)),
                               dot(xyz, vec3(-0.8294889696, 1.7626640603, 0.02362468584)),
                               dot(xyz, vec3(0.03584583024, -0.07617238927, 0.95688452401)));
            return vec4(result * pixel.a, pixel.a);
        }
        """)
}
