import Foundation
import CoreImage
import CoreGraphics

enum LUTError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let msg): return msg
        }
    }
}

struct LUT3D: Identifiable, Equatable {
    let id: String
    let name: String
    let dimension: Int
    let cubeData: Data
    let source: String

    /// 原始 RGB 三元组，用于按强度重新生成插值后的 cube
    let baseValues: [Float]

    static func == (lhs: LUT3D, rhs: LUT3D) -> Bool { lhs.id == rhs.id }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// 生成 CIColorCube 滤镜。
    /// 统一用 CIColorCubeWithColorSpace 并指定 sRGB —— 这样 LUT 在 gamma 空间里生效，
    /// 和视频调色软件里的表现一致，也和预览管线一致。
    func makeFilter(intensity: Double = 1.0) -> CIFilter? {
        guard let filter = CIFilter(name: "CIColorCubeWithColorSpace") else { return nil }

        let clamped = max(0, min(1, intensity))
        let data: Data
        if clamped >= 0.999 {
            data = cubeData
        } else if clamped <= 0.001 {
            return nil
        } else {
            data = Self.blendedCube(baseValues: baseValues, dimension: dimension, intensity: Float(clamped))
        }

        filter.setValue(NSNumber(value: dimension), forKey: "inputCubeDimension")
        filter.setValue(data, forKey: "inputCubeData")
        filter.setValue(Self.sRGB, forKey: "inputColorSpace")
        return filter
    }

    /// 把 LUT 按比例往「原始色」方向插值。
    /// identity 在该网格点上就是 (r,g,b) 归一化坐标，所以直接线性插值即可。
    private static func blendedCube(baseValues: [Float], dimension: Int, intensity: Float) -> Data {
        let n = dimension
        let count = n * n * n
        let denom = Float(max(n - 1, 1))

        var floats = [Float](repeating: 0, count: count * 4)

        for i in 0..<count {
            let r = Float(i % n) / denom
            let g = Float((i / n) % n) / denom
            let b = Float(i / (n * n)) / denom

            let lr = baseValues[i * 3]
            let lg = baseValues[i * 3 + 1]
            let lb = baseValues[i * 3 + 2]

            floats[i * 4]     = r + (lr - r) * intensity
            floats[i * 4 + 1] = g + (lg - g) * intensity
            floats[i * 4 + 2] = b + (lb - b) * intensity
            floats[i * 4 + 3] = 1
        }

        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: - 解析 .cube

    static func parse(url: URL) throws -> LUT3D {
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "\u{FEFF}", with: "")

        let fileName = url.lastPathComponent
        var title = url.deletingPathExtension().lastPathComponent
        var size3D = 0
        var size1D = 0
        var domainMin: [Float] = [0, 0, 0]
        var domainMax: [Float] = [1, 1, 1]
        var values: [Float] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let upper = line.uppercased()

            if upper.hasPrefix("TITLE") {
                let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
                if parts.count >= 2 { title = String(parts[1]) }
                continue
            }
            if upper.hasPrefix("LUT_3D_SIZE") {
                let comps = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if comps.count >= 2, let n = Int(comps[1]) { size3D = n }
                continue
            }
            if upper.hasPrefix("LUT_1D_SIZE") {
                let comps = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if comps.count >= 2, let n = Int(comps[1]) { size1D = n }
                continue
            }
            if upper.hasPrefix("DOMAIN_MIN") {
                let comps = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Float($0) }
                if comps.count >= 3 { domainMin = Array(comps[0...2]) }
                continue
            }
            if upper.hasPrefix("DOMAIN_MAX") {
                let comps = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Float($0) }
                if comps.count >= 3 { domainMax = Array(comps[0...2]) }
                continue
            }

            let comps = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Float($0) }
            if comps.count >= 3 {
                values.append(comps[0])
                values.append(comps[1])
                values.append(comps[2])
            }
        }

        guard !values.isEmpty else {
            throw LUTError.invalid("文件里没有读到颜色数据")
        }

        values = normalize(values, min: domainMin, max: domainMax)

        if size3D > 1 {
            return try build3D(title: title, fileName: fileName, size: size3D, values: values)
        }
        if size1D > 1 {
            return try build1D(title: title, fileName: fileName, size: size1D, values: values)
        }
        throw LUTError.invalid("没有找到 LUT_3D_SIZE 或 LUT_1D_SIZE，文件可能不完整")
    }

    private static func normalize(_ values: [Float], min lo: [Float], max hi: [Float]) -> [Float] {
        guard lo != [0, 0, 0] || hi != [1, 1, 1] else { return values }

        var out = values
        for i in stride(from: 0, to: out.count, by: 3) {
            for c in 0..<3 {
                let range = hi[c] - lo[c]
                if range > 0 {
                    out[i + c] = (out[i + c] - lo[c]) / range
                }
            }
        }
        return out
    }

    private static func build3D(title: String, fileName: String, size: Int, values: [Float]) throws -> LUT3D {
        let count = size * size * size
        guard values.count >= count * 3 else {
            throw LUTError.invalid("3D LUT 数据不完整：需要 \(count) 组，实际 \(values.count / 3) 组")
        }

        let base = Array(values[0..<(count * 3)])

        var floats = [Float]()
        floats.reserveCapacity(count * 4)
        for i in 0..<count {
            floats.append(base[i * 3])
            floats.append(base[i * 3 + 1])
            floats.append(base[i * 3 + 2])
            floats.append(1.0)
        }

        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        return LUT3D(
            id: fileName,
            name: title,
            dimension: size,
            cubeData: data,
            source: "3D",
            baseValues: base
        )
    }

    /// 1D LUT 转 3D：输出 (r,g,b) = (表[r].r, 表[g].g, 表[b].b)
    private static func build1D(title: String, fileName: String, size: Int, values: [Float]) throws -> LUT3D {
        guard values.count >= size * 3 else {
            throw LUTError.invalid("1D LUT 数据不完整：需要 \(size) 组，实际 \(values.count / 3) 组")
        }

        let count = size * size * size
        var base = [Float]()
        base.reserveCapacity(count * 3)
        var floats = [Float]()
        floats.reserveCapacity(count * 4)

        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let rr = values[r * 3]
                    let gg = values[g * 3 + 1]
                    let bb = values[b * 3 + 2]
                    base.append(rr)
                    base.append(gg)
                    base.append(bb)
                    floats.append(rr)
                    floats.append(gg)
                    floats.append(bb)
                    floats.append(1.0)
                }
            }
        }

        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        return LUT3D(
            id: fileName,
            name: title,
            dimension: size,
            cubeData: data,
            source: "1D→3D",
            baseValues: base
        )
    }
}

// MARK: - 本地 LUT 管理

final class LUTStore {
    static let shared = LUTStore()

    private let folder: URL
    private let selectedKey = "selectedLUTFileName"
    private var cache: [String: LUT3D] = [:]
    private let cacheLock = NSLock()

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folder = docs.appendingPathComponent("LUTs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    var selectedFileName: String? {
        get { UserDefaults.standard.string(forKey: selectedKey) }
        set { UserDefaults.standard.set(newValue, forKey: selectedKey) }
    }

    func listFiles() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
            .filter { $0.lowercased().hasSuffix(".cube") }
            .sorted() ?? []
    }

    @discardableResult
    func importFile(from url: URL) throws -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        let target = folder.appendingPathComponent(url.lastPathComponent)

        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.removeItem(at: target)
        }
        try data.write(to: target)

        cacheLock.lock()
        cache[target.lastPathComponent] = nil
        cacheLock.unlock()

        return target.lastPathComponent
    }

    func url(for fileName: String) -> URL {
        folder.appendingPathComponent(fileName)
    }

    func load(fileName: String) -> LUT3D? {
        cacheLock.lock()
        let cached = cache[fileName]
        cacheLock.unlock()
        if let cached { return cached }

        guard let lut = try? LUT3D.parse(url: url(for: fileName)) else { return nil }

        cacheLock.lock()
        cache[fileName] = lut
        cacheLock.unlock()
        return lut
    }

    /// 读取基本信息但不做完整解析，用于列表展示（避免界面卡顿）
    func quickInfo(fileName: String) -> (title: String, kind: String)? {
        let fileURL = url(for: fileName)
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        let head = handle.readData(ofLength: 4096)
        guard let text = String(data: head, encoding: .utf8) else { return nil }

        var kind = "未知"
        if text.uppercased().contains("LUT_3D_SIZE") {
            kind = "3D"
        } else if text.uppercased().contains("LUT_1D_SIZE") {
            kind = "1D"
        }

        var title = (fileName as NSString).deletingPathExtension
        if let range = text.range(of: "TITLE") {
            let rest = text[range.upperBound...]
            if let first = rest.firstIndex(of: "\""),
               let second = rest[rest.index(after: first)...].firstIndex(of: "\"") {
                title = String(rest[rest.index(after: first)..<second])
            }
        }

        return (title, kind)
    }

    func delete(fileName: String) {
        try? FileManager.default.removeItem(at: url(for: fileName))
        cacheLock.lock()
        cache[fileName] = nil
        cacheLock.unlock()
        if selectedFileName == fileName { selectedFileName = nil }
    }
}
