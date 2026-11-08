import Foundation

/// Estimates carry, apex and related numbers from launch data.
/// SkyTrak only writes its own values in batched uploads, so the live screen
/// uses this model until those arrive. Coefficients are fitted to real shots.
struct FlightParams {
    var cd0 = 0.2081, cd1 = 0.4384, cdLow = -0.0823, vc = 58.36
    var cl0 = 0.0832, cl1 = 0.7842, clMax = 0.2853, tau = 177.80
    var roll0 = 9.491, rollSpeed = 0.4077, rollDescent = -0.3027, rollSpin = -0.8275
    var spinCap = 1.0500, clHigh = 0.0993, highRpm = 5733.0
}

struct FlightResult {
    var carry = 0.0, offline = 0.0, apex = 0.0, time = 0.0, descent = 0.0
    var roll = 0.0, total = 0.0
    var landingSpeed = 0.0
}

enum Flight {
    static var params = FlightParams()

    /// Club path and face to target, fitted to SkyTrak's own shot records.
    /// Face to path is face to target minus club path.
    static func clubAndFace(ballMph: Double, launch: Double, hla: Double, spinAxis a: Double)
        -> (clubPath: Double, faceToTarget: Double) {
        let l = a * launch / 20, b = a * ballMph / 100
        return (0.0211 * a - 0.4720 * l + 0.0648 * b + 1.0079 * hla,
                -0.1490 * a + 0.1743 * l + 0.1231 * b + 1.0063 * hla)
    }

    private static let mass = 0.04593, radius = 0.02134, rho = 1.18
    private static let mph = 0.44704, yards = 1.0936133

    private typealias V = (x: Double, y: Double, z: Double)

    private static func accel(_ v: V, omega: Double, alpha: Double, p: FlightParams) -> V {
        let s = max((v.x * v.x + v.y * v.y + v.z * v.z).squareRoot(), 0.01)
        let u: V = (v.x / s, v.y / s, v.z / s)
        let ratio = radius * omega / s
        let cd = p.cd0 + p.cd1 * min(ratio, p.spinCap) + p.cdLow * max(0, 1 - s / p.vc)
        let rpm = omega * 60 / (2 * .pi)
        let cl = min(p.clMax, p.cl0 + p.cl1 * ratio) + p.clHigh * max(0, rpm - p.highRpm) / 1000
        let k = 0.5 * rho * Double.pi * radius * radius * s * s / mass

        // Unit vectors across the direction of travel: up-ish and to the right.
        var up: V = (-u.y * u.x, 1 - u.y * u.y, -u.y * u.z)
        let upLen = max((up.x * up.x + up.y * up.y + up.z * up.z).squareRoot(), 1e-6)
        up = (up.x / upLen, up.y / upLen, up.z / upLen)
        var right: V = (-u.z, 0, u.x)
        let rightLen = max((right.x * right.x + right.z * right.z).squareRoot(), 1e-6)
        right = (right.x / rightLen, 0, right.z / rightLen)

        let nx = cos(alpha) * up.x + sin(alpha) * right.x
        let ny = cos(alpha) * up.y + sin(alpha) * right.y
        let nz = cos(alpha) * up.z + sin(alpha) * right.z
        return (k * (cl * nx - cd * u.x), k * (cl * ny - cd * u.y) - 9.80665, k * (cl * nz - cd * u.z))
    }

    /// `ballMph` in mph, angles in degrees, spins in rpm. Positive side values go right.
    static func simulate(ballMph: Double, launch: Double, hla: Double, back: Double, side: Double,
                         params p: FlightParams = Flight.params) -> FlightResult {
        let v0 = ballMph * mph, la = launch * .pi / 180, ha = hla * .pi / 180
        var v: V = (v0 * cos(la) * cos(ha), v0 * sin(la), v0 * cos(la) * sin(ha))
        var pos: V = (0, 0.0, 0)
        let omega0 = (back * back + side * side).squareRoot() * 2 * .pi / 60
        let alpha = atan2(side, max(abs(back), 1))
        let dt = 0.01
        var t = 0.0, apex = 0.0
        var out = FlightResult()

        while t < 15 {
            let om = omega0 * exp(-t / p.tau)
            let a1 = accel(v, omega: om, alpha: alpha, p: p)
            let mid: V = (v.x + a1.x * dt / 2, v.y + a1.y * dt / 2, v.z + a1.z * dt / 2)
            let a2 = accel(mid, omega: om, alpha: alpha, p: p)
            pos = (pos.x + mid.x * dt, pos.y + mid.y * dt, pos.z + mid.z * dt)
            v = (v.x + a2.x * dt, v.y + a2.y * dt, v.z + a2.z * dt)
            t += dt
            apex = max(apex, pos.y)
            if pos.y <= 0 && v.y < 0 { break }
        }

        let horizontal = (v.x * v.x + v.z * v.z).squareRoot()
        out.carry = (pos.x * pos.x + pos.z * pos.z).squareRoot() * yards
        out.offline = pos.z * yards
        out.apex = apex * yards
        out.time = t
        out.descent = atan2(-v.y, max(horizontal, 0.01)) * 180 / .pi
        out.landingSpeed = horizontal / mph
        out.roll = max(0, p.roll0 + p.rollSpeed * out.landingSpeed + p.rollDescent * out.descent
                        + p.rollSpin * (back / 1000))
        out.total = out.carry + out.roll
        return out
    }
}
