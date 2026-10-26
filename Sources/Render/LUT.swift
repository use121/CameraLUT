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
        let text = try String(contentsOf: url, encoding: .utf8)
        var size = 0
        var title = url.deletingPathExtension().lastPathComponent
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
                if comps.count >= 2, let n = Int(comps[1]) { size = n }
                continue
            }
            if upper.hasPrefix("LUT_1D_SIZE") || upper.hasPrefix("DOMAIN_MIN") || upper.hasPrefix("DOMAIN_MAX") {
                continue
            }

            let comps = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Float($0) }
            if comps.count >= 3 {
                values.append(comps[0])
                values.append(comps[1])
                values.append(comps[2])
            }
        }

        guard size > 1 else {
            throw LUTError.invalid("没有找到 LUT_3D_SIZE，可能不是 3D LUT 文件")
        }

        let count = size * size * size
        guard values.count >= count * 3 else {
            throw LUTError.invalid("LUT 数据不完整：需要 \(count) 组，实际 \(values.count / 3) 组")
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

        return LUT3D(
            id: url.lastPathComponent,
            name: title,
            dimension: size,
            cubeData: data
        )
    }
}

// MARK: - 本地 LUT 管理

final class LUTStore {
    static let shared = LUTStore()

    private let folder: URL
    private let selectedKey = "selectedLUTFileName"

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folder = docs.appendingPathComponent("LUTs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    var selectedFileName: String? {
        get { UserDefaults.standard.string(forKey: selectedKey) }
        set { UserDefaults.standard.set(newValue, forKey: selectedKey) }
    }

    /// 已导入的 LUT 文件名列表
    func listFiles() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
            .filter { $0.lowercased().hasSuffix(".cube") }
            .sorted() ?? []
    }

    /// 把外部选中的 .cube 复制进来
    @discardableResult
    func importFile(from url: URL) throws -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        var target = folder.appendingPathComponent(url.lastPathComponent)

        // 同名覆盖
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.removeItem(at: target)
        }
        try data.write(to: target)

        return target.lastPathComponent
    }

    func url(for fileName: String) -> URL {
        folder.appendingPathComponent(fileName)
    }

    func load(fileName: String) -> LUT3D? {
        guard let lut = try? LUT3D.parse(url: url(for: fileName)) else { return nil }
        return LUT3D(id: fileName, name: lut.name, dimension: lut.dimension, cubeData: lut.cubeData)
    }

    func delete(fileName: String) {
        try? FileManager.default.removeItem(at: url(for: fileName))
        if selectedFileName == fileName { selectedFileName = nil }
    }
}
