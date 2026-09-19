// Sun & moon positions for time-of-day ("dynamic") wallpapers.
// Shared by wsrender and the Wallpaper Studio app — keep both copies identical.
import Foundation

struct SkyState {
    /// Unit vectors in the scene frame: x = east, y = up, z = south (-z = north).
    var sunDir: SIMD3<Float>
    var sunElevation: Float      // degrees above the horizon (negative = below)
    var moonDir: SIMD3<Float>
    var moonIllumination: Float  // 0 = new moon, 1 = full moon
    var dayTime: Float           // local clock time in hours [0, 24)
    var dayOfYear: Float
}

enum Solar {
    private static func rad(_ d: Double) -> Double { d * .pi / 180 }
    private static func deg(_ r: Double) -> Double { r * 180 / .pi }
    private static func norm360(_ x: Double) -> Double { let v = x.truncatingRemainder(dividingBy: 360); return v < 0 ? v + 360 : v }

    /// Approximate coordinates of the current time zone's reference city (from the
    /// system tz database). No location permission needed.
    static func timeZoneLocation(_ tz: TimeZone = .current) -> (lat: Double, lon: Double) {
        if let text = try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8) {
            for line in text.split(separator: "\n") where !line.hasPrefix("#") {
                let cols = line.split(separator: "\t")
                if cols.count >= 3, cols[2] == tz.identifier, let c = parseISO6709(String(cols[1])) {
                    return c
                }
            }
        }
        // Fallback: longitude from the UTC offset, a mid-northern latitude.
        return (35, Double(tz.secondsFromGMT()) / 3600 * 15)
    }

    /// Parses "+2452+06703" or "+404251-0740023" style coordinates.
    private static func parseISO6709(_ s: String) -> (lat: Double, lon: Double)? {
        let chars = Array(s)
        guard let split = chars.indices.dropFirst().first(where: { chars[$0] == "+" || chars[$0] == "-" }) else { return nil }
        func dms(_ part: [Character], degDigits: Int) -> Double? {
            guard let sign = part.first else { return nil }
            let digits = String(part.dropFirst())
            guard digits.count >= degDigits + 2, let d = Double(digits.prefix(degDigits)) else { return nil }
            let rest = digits.dropFirst(degDigits)
            let m = Double(rest.prefix(2)) ?? 0
            let sec = rest.count >= 4 ? (Double(rest.dropFirst(2).prefix(2)) ?? 0) : 0
            let v = d + m / 60 + sec / 3600
            return sign == "-" ? -v : v
        }
        guard let lat = dms(Array(chars[..<split]), degDigits: 2),
              let lon = dms(Array(chars[split...]), degDigits: 3) else { return nil }
        return (lat, lon)
    }

    /// Horizontal coordinates (degrees) for right ascension / declination.
    private static func horizontal(ra: Double, dec: Double, jd: Double, lat: Double, lon: Double) -> (el: Double, az: Double) {
        let d = jd - 2451545.0
        let gmst = norm360(280.46061837 + 360.98564736629 * d)
        let h = rad(norm360(gmst + lon - ra))
        let phi = rad(lat), delta = rad(dec)
        let sinEl = sin(phi) * sin(delta) + cos(phi) * cos(delta) * cos(h)
        let el = deg(asin(max(-1, min(1, sinEl))))
        let az = norm360(deg(atan2(-cos(delta) * sin(h), sin(delta) * cos(phi) - cos(delta) * sin(phi) * cos(h))))
        return (el, az)
    }

    private static func vector(el: Double, az: Double) -> SIMD3<Float> {
        let e = rad(el), a = rad(az)
        return SIMD3(Float(sin(a) * cos(e)), Float(sin(e)), Float(-cos(a) * cos(e)))
    }

    static func state(at date: Date, lat: Double, lon: Double, timeZone: TimeZone = .current) -> SkyState {
        let jd = date.timeIntervalSince1970 / 86400 + 2440587.5
        let jc = (jd - 2451545) / 36525
        // Sun (NOAA)
        let l0 = norm360(280.46646 + jc * (36000.76983 + jc * 0.0003032))
        let m = 357.52911 + jc * (35999.05029 - 0.0001537 * jc)
        let c = sin(rad(m)) * (1.914602 - jc * (0.004817 + 0.000014 * jc))
            + sin(rad(2 * m)) * (0.019993 - 0.000101 * jc) + sin(rad(3 * m)) * 0.000289
        let omega = 125.04 - 1934.136 * jc
        let lambda = l0 + c - 0.00569 - 0.00478 * sin(rad(omega))
        let eps0 = 23 + (26 + (21.448 - jc * (46.815 + jc * (0.00059 - jc * 0.001813))) / 60) / 60
        let eps = eps0 + 0.00256 * cos(rad(omega))
        let sunRA = norm360(deg(atan2(cos(rad(eps)) * sin(rad(lambda)), cos(rad(lambda)))))
        let sunDec = deg(asin(sin(rad(eps)) * sin(rad(lambda))))
        var sun = horizontal(ra: sunRA, dec: sunDec, jd: jd, lat: lat, lon: lon)
        // Atmospheric refraction near the horizon (Bennett)
        if sun.el > -2 { sun.el += 1.02 / tan(rad(sun.el + 10.3 / (sun.el + 5.11))) / 60 }

        // Moon (low precision: age-based longitude, ±5° latitude from the node)
        let age = ((jd - 2451550.26) / 29.530588853).truncatingRemainder(dividingBy: 1)
        let ageN = age < 0 ? age + 1 : age
        let illum = (1 - cos(2 * .pi * ageN)) / 2
        let moonLon = norm360(lambda + 360 * ageN)
        let node = norm360(125.04 - 1934.136 * jc)
        let moonLat = 5.145 * sin(rad(moonLon - node))
        let sl = sin(rad(moonLon)), cl = cos(rad(moonLon)), sb = sin(rad(moonLat)), cb = cos(rad(moonLat))
        let moonDec = deg(asin(sb * cos(rad(eps)) + cb * sin(rad(eps)) * sl))
        let moonRA = norm360(deg(atan2(sl * cos(rad(eps)) * cb - sb * sin(rad(eps)), cl * cb)))
        let moon = horizontal(ra: moonRA, dec: moonDec, jd: jd, lat: lat, lon: lon)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let comps = cal.dateComponents([.hour, .minute, .second], from: date)
        let hours = Double(comps.hour ?? 0) + Double(comps.minute ?? 0) / 60 + Double(comps.second ?? 0) / 3600
        let doy = Double(cal.ordinality(of: .day, in: .year, for: date) ?? 172)

        return SkyState(sunDir: vector(el: sun.el, az: sun.az), sunElevation: Float(sun.el),
                        moonDir: vector(el: moon.el, az: moon.az), moonIllumination: Float(illum),
                        dayTime: Float(hours), dayOfYear: Float(doy))
    }

    /// Key moments of a day (for previews): returns (label, date) pairs.
    static func keyMoments(on day: Date, lat: Double, lon: Double, timeZone: TimeZone = .current) -> [(String, Date)] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let start = cal.startOfDay(for: day)
        var samples: [(Date, Float)] = []
        for minute in stride(from: 0, through: 1440, by: 2) {
            let d = start.addingTimeInterval(Double(minute) * 60)
            samples.append((d, state(at: d, lat: lat, lon: lon, timeZone: timeZone).sunElevation))
        }
        func crossing(_ level: Float, rising: Bool) -> Date? {
            for i in 1..<samples.count {
                let a = samples[i - 1].1, b = samples[i].1
                if rising ? (a < level && b >= level) : (a > level && b <= level) { return samples[i].0 }
            }
            return nil
        }
        let noon = samples.max(by: { $0.1 < $1.1 })!.0
        let midnight = samples.min(by: { $0.1 < $1.1 })!.0
        var out: [(String, Date)] = [("night", midnight)]
        if let d = crossing(-5, rising: true) { out.append(("dawn twilight", d)) }
        if let d = crossing(1, rising: true) { out.append(("sunrise", d)) }
        if let d = crossing(20, rising: true) { out.append(("morning", d)) }
        out.append(("midday", noon))
        if let d = crossing(8, rising: false) { out.append(("golden hour", d)) }
        if let d = crossing(0.5, rising: false) { out.append(("sunset", d)) }
        if let d = crossing(-5, rising: false) { out.append(("dusk", d)) }
        if let d = crossing(-14, rising: false) { out.append(("evening night", d)) }
        return out
    }
}
