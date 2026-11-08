import Cocoa

enum Paths {
    static let home = NSHomeDirectory()
    static let logs = home + "/Library/Logs/SkyTrak/SKYTRAK"
    static let playerLog = logs + "/Player.log"
    static let playerPrevious = logs + "/Player-prev.log"
    static let skyTrakLog = home + "/Library/Application Support/com.golftec.skytrak/AppLogs/SkyTrak.log"
    static let dataDirectory = home + "/Library/Application Support/SkyTrakStats"
}

/// Follows a growing log file. Unity starts a new Player.log on every launch,
/// so a changed inode or a shorter file restarts reading from the top.
final class FileTail {
    let path: String
    private var inode: UInt64 = 0
    private var offset: UInt64 = 0
    private var pending = Data()
    private(set) var found = false
    private(set) var modified: Date?

    init(_ path: String) { self.path = path }

    /// Returns true when the file was replaced since the last read.
    @discardableResult
    func read(_ handleLine: (String) -> Void) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else {
            found = false
            return false
        }
        found = true
        modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        let size = UInt64(info.st_size)
        var replaced = false
        if UInt64(info.st_ino) != inode || size < offset {
            replaced = inode != 0
            inode = UInt64(info.st_ino)
            offset = 0
            pending.removeAll()
        }
        guard size > offset, let file = FileHandle(forReadingAtPath: path) else { return replaced }
        defer { try? file.close() }
        try? file.seek(toOffset: offset)
        let chunk = file.readData(ofLength: Int(size - offset))
        offset += UInt64(chunk.count)

        pending.append(chunk)
        var start = pending.startIndex
        while let newline = pending[start...].firstIndex(of: 0x0A) {
            handleLine(String(decoding: pending[start..<newline], as: UTF8.self))
            start = pending.index(after: newline)
        }
        pending = Data(pending[start...])
        return replaced
    }
}

struct Status: Encodable {
    var skyTrakRunning: Bool
    var logFound: Bool
    var logAge: Double?
    var monitorConnected: Bool
    var battery: Double?
}

/// Reads SkyTrak's logs and turns them into shots. All work happens on one queue.
final class Engine {
    var onSend: ((String) -> Void)?

    private let queue = DispatchQueue(label: "skytrakstats.engine")
    private let store = ShotStore(directory: Paths.dataDirectory)
    private let player = FileTail(Paths.playerLog)
    private let skyTrak = FileTail(Paths.skyTrakLog)
    private let encoder = JSONEncoder()
    private var timer: DispatchSourceTimer?
    private var ticks = 0

    private var catchingUp = true
    private var current: [String: Double]?
    private var currentTime = 0.0
    private var club: String?
    private var putting = false
    private var onCourse = false
    private var lastHeartbeat: Date?
    private var battery: Double?
    private var clubBlock: [String: Double]?
    private var clubBlockTime = 0.0

    private static let pairs = try! NSRegularExpression(pattern: "([A-Za-z]+)=(-?\\d+(?:\\.\\d+)?)")
    private static let clubLine = try! NSRegularExpression(pattern: ": ([A-Za-z ]+): (-?[\\d.]+)\\s*$")

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
    private let playerTime = Engine.formatter("yyyy-MM-dd HH:mm:ss.SSS")
    private let skyTrakTime = Engine.formatter("MM/dd/yyyy HH:mm:ss")

    init(selectedClub: String?) { club = selectedClub }

    func start() {
        queue.async { [self] in
            FileTail(Paths.playerPrevious).read(handlePlayerLine)
            player.read(handlePlayerLine)
            skyTrak.read(handleSkyTrakLine)
            catchingUp = false
            store.saveIfNeeded()
            send("shots", store.shots)
            send("ranges", OptimalRanges.load())

            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: 0.25)
            source.setEventHandler { [weak self] in self?.tick() }
            source.resume()
            timer = source
        }
    }

    func selectClub(_ value: String?) { queue.async { self.club = value } }

    func setClub(id: String, club: String) {
        queue.async { [self] in
            if let shot = store.setClub(id: id, club: club) { send("shotChanged", shot) }
            store.saveIfNeeded()
        }
    }

    private func tick() {
        if player.read(handlePlayerLine) { current = nil }
        skyTrak.read(handleSkyTrakLine)
        store.saveIfNeeded()
        ticks += 1
        if ticks % 4 == 0 { send("status", status()) }
    }

    private func status() -> Status {
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.golftec.skytrak").isEmpty
        let connected = lastHeartbeat.map { Date().timeIntervalSince($0) < 12 } ?? false
        return Status(skyTrakRunning: running, logFound: player.found,
                      logAge: player.modified.map { max(0, Date().timeIntervalSince($0)) },
                      monitorConnected: connected, battery: connected ? battery : nil)
    }

    private func send<T: Encodable>(_ type: String, _ value: T) {
        guard let body = try? encoder.encode(value), let text = String(data: body, encoding: .utf8) else { return }
        let message = "{\"type\":\"\(type)\",\"data\":\(text)}"
        DispatchQueue.main.async { self.onSend?(message) }
    }

    private func numbers(in text: String) -> [String: Double] {
        var out: [String: Double] = [:]
        let ns = text as NSString
        for m in Engine.pairs.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out[ns.substring(with: m.range(at: 1))] = Double(ns.substring(with: m.range(at: 2)))
        }
        return out
    }

    // MARK: Player.log

    private func handlePlayerLine(_ line: String) {
        guard line.hasPrefix("20") else { return }
        if line.contains("RIPE_EVT_DATA_STATUS_UPDATE") {
            guard !catchingUp else { return }
            lastHeartbeat = Date()
            battery = numbers(in: line)["batteryPercent"]
        } else if line.contains("RIPE_EVT_BOX_DISCONNECTED") {
            lastHeartbeat = nil
        } else if line.contains("RIPE_EVT_DATA_TRIGGERDETECTED") {
            current = [:]
            currentTime = playerTime.date(from: String(line.prefix(23)))?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
        } else if current != nil {
            if line.contains("RIPE_EVT_DATA_SPEEDREADY") || line.contains("RIPE_EVT_DATA_SPINREADY") {
                current?.merge(numbers(in: line)) { _, new in new }
            } else if line.contains("Shot was ended.") {
                finishShot()
            }
        }
    }

    private func finishShot() {
        guard let raw = current else { return }
        current = nil
        let metersPerSecond = raw["totalSpeed"] ?? 0
        // Same test SkyTrak applies: any zero confidence means it rejected the shot.
        guard metersPerSecond > 0, (raw["totalSpeedConfidence"] ?? 0) > 0,
              (raw["launchAngleConfidence"] ?? 0) > 0, (raw["horizontalAngleConfidence"] ?? 0) > 0 else {
            if !catchingUp { send("misread", ["time": currentTime]) }
            return
        }

        let toMph = 2.2369363
        let ball = metersPerSecond * toMph
        let launch = raw["launchAngle"] ?? 0, hla = raw["horizontalAngle"] ?? 0
        let back = -(raw["backSpin"] ?? 0), side = raw["sideSpin"] ?? 0, totalSpin = raw["totalSpin"] ?? 0

        var shot = Shot(id: "s\(Int(currentTime * 1000))", time: currentTime, ballSpeed: ball, launch: launch,
                        hla: hla, backSpin: back, sideSpin: side, totalSpin: totalSpin,
                        spinAxis: raw["spinAxis"] ?? 0, official: false)
        if let speed = raw["clubSpeed"], speed > 0, (raw["clubSpeedConfidence"] ?? 0) > 0 {
            shot.clubSpeed = speed * toMph
            shot.smash = ball / (speed * toMph)
        }
        if totalSpin > 0 && !(putting && !catchingUp) {
            let flight = Flight.simulate(ballMph: ball, launch: launch, hla: hla, back: back, side: side)
            shot.carry = flight.carry
            shot.roll = flight.roll
            shot.total = flight.total
            shot.offline = flight.offline
            shot.apex = flight.apex
            shot.descent = flight.descent
            shot.flightTime = flight.time
            let club = Flight.clubAndFace(ballMph: ball, launch: launch, hla: hla, spinAxis: shot.spinAxis)
            shot.clubPath = club.clubPath
            shot.faceToTarget = club.faceToTarget
            shot.faceToPath = club.faceToTarget - club.clubPath
            shot.pathEstimated = true
        }
        if !catchingUp {
            shot.onCourse = onCourse ? true : nil
            if putting {
                shot.club = "PT"
                shot.clubSource = "putting"
            } else if let club = club {
                shot.club = club
                shot.clubSource = "picked"
            }
        }
        if let added = store.addMeasured(shot), !catchingUp { send("newShot", added) }
    }

    // MARK: SkyTrak.log

    private func handleSkyTrakLine(_ line: String) {
        guard let data = Data(base64Encoded: line) else { return }
        let text = String(decoding: data, as: UTF8.self)

        if text.contains("SKYTRAK CLUB DATA") {
            clubBlock = [:]
            clubBlockTime = recordTime(text)
        } else if clubBlock != nil {
            if text.contains("+++++++ END") {
                finishClubBlock()
            } else {
                let ns = text as NSString
                if let m = Engine.clubLine.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                    clubBlock?[ns.substring(with: m.range(at: 1))] = Double(ns.substring(with: m.range(at: 2)))
                }
            }
        } else if text.contains("Start Activity type: ") {
            onCourse = text.contains("Start Activity type: 104")   // 104 is course play
        } else if text.contains("Box Set Shot Mode STSW_SHOT_MODE_PUTTING") {
            putting = true
        } else if text.contains("Box Set Shot Mode STSW_SHOT_MODE_NORMAL") {
            putting = false
        } else if text.contains("\"COLUMNS\":[\"shotId\"") {
            applyUpload(text)
        }
    }

    private func recordTime(_ text: String) -> Double {
        skyTrakTime.date(from: String(text.prefix(19)))?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
    }

    private func finishClubBlock() {
        defer { clubBlock = nil }
        guard let b = clubBlock, let speed = b["Clubhead Speed"], let attack = b["Angle of Attack"],
              let loft = b["Dynamic Loft"] else { return }
        let data = ClubData(attackAngle: attack, clubSpeed: speed, dynamicLoft: loft)
        if let shot = store.applyClubData(data, at: clubBlockTime), !catchingUp { send("shotChanged", shot) }
    }

    /// Only the shot table is taken from these records; they also carry account details.
    private func applyUpload(_ text: String) {
        let bytes = Array(text.utf8)
        guard let columnsAt = Engine.find("\"COLUMNS\":", in: bytes, from: 0),
              let columnsRange = Engine.arrayRange(in: bytes, from: columnsAt + 10),
              let dataAt = Engine.find("\"DATA\":", in: bytes, from: columnsRange.upperBound),
              let dataRange = Engine.arrayRange(in: bytes, from: dataAt + 7),
              let columns = try? JSONSerialization.jsonObject(with: Data(bytes[columnsRange])) as? [String],
              let rows = try? JSONSerialization.jsonObject(with: Data(bytes[dataRange])) as? [[Any]] else { return }
        for row in rows where row.count == columns.count {
            var fields: [String: String] = [:]
            for (name, value) in zip(columns, row) { fields[name] = (value as? String) ?? "\(value)" }
            if let shot = store.applyOfficial(fields), !catchingUp { send("shotChanged", shot) }
        }
    }

    private static func find(_ pattern: String, in bytes: [UInt8], from start: Int) -> Int? {
        let p = Array(pattern.utf8)
        guard bytes.count >= p.count, start <= bytes.count - p.count else { return nil }
        for i in start...(bytes.count - p.count) where bytes[i] == p[0] && Array(bytes[i..<(i + p.count)]) == p {
            return i
        }
        return nil
    }

    /// Finds the JSON array starting at `start`, respecting strings and escapes.
    private static func arrayRange(in bytes: [UInt8], from start: Int) -> Range<Int>? {
        guard start < bytes.count, bytes[start] == UInt8(ascii: "[") else { return nil }
        var depth = 0, inString = false, escaped = false
        for i in start..<bytes.count {
            let b = bytes[i]
            if escaped { escaped = false; continue }
            if inString {
                if b == UInt8(ascii: "\\") { escaped = true } else if b == UInt8(ascii: "\"") { inString = false }
                continue
            }
            if b == UInt8(ascii: "\"") { inString = true }
            else if b == UInt8(ascii: "[") { depth += 1 }
            else if b == UInt8(ascii: "]") {
                depth -= 1
                if depth == 0 { return start..<(i + 1) }
            }
        }
        return nil
    }
}
