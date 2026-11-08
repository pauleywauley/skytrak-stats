import Foundation

struct Shot: Codable {
    var id: String
    var time: Double
    var ballSpeed: Double
    var launch: Double
    var hla: Double
    var backSpin: Double
    var sideSpin: Double
    var totalSpin: Double
    var spinAxis: Double
    var clubSpeed: Double?
    var smash: Double?
    var carry: Double?
    var roll: Double?
    var total: Double?
    var offline: Double?
    var curve: Double?
    var apex: Double?
    var descent: Double?
    var flightTime: Double?
    var attackAngle: Double?
    var dynamicLoft: Double?
    var clubPath: Double?
    var faceToPath: Double?
    var faceToTarget: Double?
    var pathEstimated: Bool?
    var onCourse: Bool?
    var club: String?
    var clubSource: String?   // "picked", "putting", "skytrak" or "edited"
    var official: Bool
}

struct ClubData {
    var attackAngle, clubSpeed, dynamicLoft: Double
}

/// Every shot the app knows about, oldest first, saved to Application Support.
/// Only touched from the engine queue.
final class ShotStore {
    private(set) var shots: [Shot] = []
    private let file: URL
    private var dirty = false

    init(directory: String) {
        file = URL(fileURLWithPath: directory).appendingPathComponent("shots.json")
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([Shot].self, from: data) {
            shots = saved
        }
    }

    func saveIfNeeded() {
        guard dirty, let data = try? JSONEncoder().encode(shots) else { return }
        try? data.write(to: file, options: .atomic)
        dirty = false
    }

    /// The same physical shot appears in several logs; its launch numbers identify it.
    private func indexOf(ball: Double, launch: Double, back: Double) -> Int? {
        shots.lastIndex {
            abs($0.ballSpeed - ball) < 0.05 && abs($0.launch - launch) < 0.02 && abs($0.backSpin - back) < 2
        }
    }

    private func insert(_ shot: Shot) -> Int {
        shots.append(shot)
        if shots.count > 1 && shots[shots.count - 2].time > shot.time {
            shots.sort { $0.time < $1.time }
            return shots.firstIndex { $0.id == shot.id } ?? shots.count - 1
        }
        return shots.count - 1
    }

    /// Returns the shot only if it wasn't already known.
    func addMeasured(_ shot: Shot) -> Shot? {
        guard indexOf(ball: shot.ballSpeed, launch: shot.launch, back: shot.backSpin) == nil else { return nil }
        dirty = true
        return shots[insert(shot)]
    }

    /// SkyTrak logs club data for the shot that just finished rolling.
    func applyClubData(_ d: ClubData, at time: Double) -> Shot? {
        guard let i = shots.lastIndex(where: { $0.time <= time + 2 && time - $0.time < 40 }) else { return nil }
        var s = shots[i]
        if let measured = s.clubSpeed, measured > 0, !(0.85...1.2).contains(d.clubSpeed / measured) { return nil }
        if s.attackAngle == d.attackAngle && s.clubSpeed == d.clubSpeed { return nil }
        s.attackAngle = d.attackAngle
        s.clubSpeed = d.clubSpeed
        s.dynamicLoft = d.dynamicLoft
        s.smash = d.clubSpeed > 0 ? s.ballSpeed / d.clubSpeed : s.smash
        shots[i] = s
        dirty = true
        return s
    }

    /// Merges a row from SkyTrak's upload. Returns the shot if anything changed.
    func applyOfficial(_ row: [String: String]) -> Shot? {
        func value(_ key: String) -> Double? { row[key].flatMap(Double.init) }
        guard let ball = value("ballSpeed"), ball > 0, let launch = value("verticalLaunchAngle"),
              let shotId = value("shotId") else { return nil }
        let back = value("backSpin") ?? 0, side = value("sideSpin") ?? 0, hla = value("horizontalLaunchAngle") ?? 0

        var s: Shot
        let existing = indexOf(ball: ball, launch: launch, back: back)
        if let i = existing {
            s = shots[i]
            if s.official && s.clubSource != nil { return nil }
            if s.official && (row["clubType"] ?? "").isEmpty { return nil }
        } else {
            let totalSpin = (back * back + side * side).squareRoot()
            s = Shot(id: "o\(Int(shotId))", time: shotId, ballSpeed: ball, launch: launch, hla: hla,
                     backSpin: back, sideSpin: side, totalSpin: totalSpin,
                     spinAxis: atan2(side, max(abs(back), 1)) * 180 / .pi, official: true)
            let model = Flight.simulate(ballMph: ball, launch: launch, hla: hla, back: back, side: side)
            s.curve = model.offline - model.carry * sin(hla * .pi / 180)
        }

        func positive(_ key: String) -> Double? { value(key).flatMap { $0 > 0 ? $0 : nil } }
        s.time = shotId
        s.official = true
        s.clubSpeed = positive("clubheadSpeed") ?? s.clubSpeed
        s.smash = positive("PTI_smashFactor") ?? s.smash
        s.carry = value("carryDistance")
        s.roll = value("rollDistance")
        s.total = value("totalDistance")
        s.offline = value("offline")
        s.apex = value("maxHeight")
        s.descent = value("angleOfDescent")
        s.flightTime = value("flightTime")
        s.attackAngle = value("angleOfAttack")
        s.dynamicLoft = value("dynamicLoft")
        // SkyTrak writes exact zeros when it has no club path reading.
        let path = value("clubPath") ?? 0, face = value("faceToPath") ?? 0
        if path != 0 || face != 0 {
            s.clubPath = path
            s.faceToPath = face
            s.faceToTarget = value("faceToTarget")
            s.pathEstimated = false
        }
        if let club = row["clubType"], !club.isEmpty, s.clubSource != "edited" {
            s.club = club
            s.clubSource = "skytrak"
        }

        dirty = true
        if let i = existing {
            shots[i] = s
            if i + 1 < shots.count && shots[i + 1].time < s.time || i > 0 && shots[i - 1].time > s.time {
                shots.sort { $0.time < $1.time }
            }
            return s
        }
        return shots[insert(s)]
    }

    func setClub(id: String, club: String) -> Shot? {
        guard let i = shots.firstIndex(where: { $0.id == id }) else { return nil }
        shots[i].club = club
        shots[i].clubSource = "edited"
        dirty = true
        return shots[i]
    }
}
