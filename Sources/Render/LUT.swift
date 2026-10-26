import Foundation
import CoreImage

enum LUTError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let msg): return msg
        }
    }
}

struct LUT3D: Identifiable, Equatable {
    let id: String          // 文件名，用作唯一标识
    let name: String        // 显示名（TITLE 或文件名）
    let dimension: Int
    let cubeData: Data
    let source: String      // "3D" / "1D→3D"，用于界面提示

    static func == (lhs: LUT3D, rhs: LUT3D) -> Bool { lhs.id == rhs.id }

    /// 生成 CIColorCube 滤镜。每次调用返回新实例，可安全复用同一份 cubeData。
    func makeFilter() -> CIFilter? {
        guard let filter = CIFilter(name: "CIColorCube") else { return nil }
        filter.setValue(NSNumber(value: dimension), forKey: "inputCubeDimension")
        filter.setValue(cubeData, forKey: "inputCubeData")
        return filter
    }

    // MARK: - 解析 .cube

    static func parse(url: URL) throws -> LUT3D {
        var text = try String(contentsOf: url, encoding: .utf8)
        // 去掉 UTF-8 BOM，否则第一行匹配不上
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

    // MARK: - 归一化

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

    // MARK: - 3D

    private static func build3D(title: String, fileName: String, size: Int, values: [Float]) throws -> LUT3D {
        let count = size * size * size
        guard values.count >= count * 3 else {
            throw LUTError.invalid("3D LUT 数据不完整：需要 \(count) 组，实际 \(values.count / 3) 组")
        }

        var floats = [Float]()
        floats.reserveCapacity(count * 4)
        for i in 0..<count {
            floats.append(values[i * 3])
            floats.append(values[i * 3 + 1])
            floats.append(values[i * 3 + 2])
            floats.append(1.0)
        }

        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        return LUT3D(id: fileName, name: title, dimension: size, cubeData: data, source: "3D")
    }

    // MARK: - 1D → 3D

    /// 把 1D LUT 转成等尺寸的 3D LUT：输出 (r,g,b) = (表[r].r, 表[g].g, 表[b].b)。
    private static func build1D(title: String, fileName: String, size: Int, values: [Float]) throws -> LUT3D {
        guard values.count >= size * 3 else {
            throw LUTError.invalid("1D LUT 数据不完整：需要 \(size) 组，实际 \(values.count / 3) 组")
        }

        let count = size * size * size
        var floats = [Float]()
        floats.reserveCapacity(count * 4)

        // CIColorCube 要求 r 变化最快：外层 b，中层 g，内层 r
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    floats.append(values[r * 3])
                    floats.append(values[g * 3 + 1])
                    floats.append(values[b * 3 + 2])
                    floats.append(1.0)
                }
            }
        }

        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        return LUT3D(id: fileName, name: title, dimension: size, cubeData: data, source: "1D→3D")
    }
}

// MARK: - 本地 LUT 管理

final class LUTStore {
    static let shared = LUTStore()

    private let folder: URL
    private let selectedKey = "selectedLUTFileName"
    private var cache: [String: LUT3D] = [:]

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
        cache[target.lastPathComponent] = nil

        return target.lastPathComponent
    }

    func url(for fileName: String) -> URL {
        folder.appendingPathComponent(fileName)
    }

    /// 带缓存地加载；解析失败返回 nil。
    func load(fileName: String) -> LUT3D? {
        if let cached = cache[fileName] { return cached }
        guard let lut = try? LUT3D.parse(url: url(for: fileName)) else { return nil }
        cache[fileName] = lut
        return lut
    }

    func delete(fileName: String) {
        try? FileManager.default.removeItem(at: url(for: fileName))
        cache[fileName] = nil
        if selectedFileName == fileName { selectedFileName = nil }
    }
}
