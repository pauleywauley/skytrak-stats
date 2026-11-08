import Cocoa

/// SkyTrak's own per-club targets. They ship inside its data files, so they are
/// read from the installed copy rather than duplicated here.
enum OptimalRanges {
    private static let bundleID = "com.golftec.skytrak"

    private static func skyTrakApp() -> URL? {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.bundleURL {
            return running
        }
        if let known = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return known }
        let home = NSHomeDirectory()
        return ["/Applications/SkyTrak.app", home + "/Applications/SkyTrak.app", home + "/Downloads/SkyTrak.app"]
            .first { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Unity stores a text file as its name, padding to four bytes, a 32-bit length, then the text.
    private static func textAsset(_ name: String, in data: Data) -> String? {
        guard let found = data.range(of: Data(name.utf8)) else { return nil }
        for pad in 0..<4 {
            let at = found.upperBound + pad
            guard at + 4 <= data.count else { return nil }
            let length = Int(data[at]) | Int(data[at + 1]) << 8 | Int(data[at + 2]) << 16 | Int(data[at + 3]) << 24
            guard length > 0, length < 5_000_000, at + 4 + length <= data.count else { continue }
            let text = String(decoding: data[(at + 4)..<(at + 4 + length)], as: UTF8.self)
            if text.prefix(12).contains(",") { return text }
        }
        return nil
    }

    /// Club code -> club speed -> launch, back spin and descent, each as
    /// close-low, close-high, good-low, good-high. Empty if SkyTrak can't be found.
    static func load() -> [String: [String: [Double]]] {
        guard let app = skyTrakApp(),
              let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Resources/Data/resources.assets"),
                                   options: .alwaysMapped),
              let text = textAsset("OptimalRangesFlightData", in: data) else { return [:] }
        var table: [String: [String: [Double]]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ",")
            guard fields.count == 14, let speed = Int(fields[1]) else { continue }
            let numbers = fields[2...].compactMap { Double($0) }
            if numbers.count == 12 { table[String(fields[0]), default: [:]][String(speed)] = numbers }
        }
        return table
    }
}
