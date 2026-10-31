import Foundation

enum Fmt {
    static var locale: Locale { Locale(identifier: L.isSwedish ? "sv_SE" : "en_GB") }

    static func num(_ v: Double, decimals: Int = 1) -> String {
        v.formatted(.number.precision(.fractionLength(decimals)).locale(locale))
    }

    static func watts(_ v: Double?) -> String {
        guard let v else { return "– W" }
        return num(v, decimals: v < 10 && v != v.rounded() ? 1 : 0) + " W"
    }

    static func hours(_ h: Double) -> String {
        h == h.rounded() ? "\(Int(h)) h" : num(h, decimals: 1) + " h"
    }

    static func duration(_ s: TimeInterval) -> String {
        let m = Int(s / 60)
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    static func time(_ d: Date) -> String {
        Calendar.current.isDateInToday(d)
            ? d.formatted(.dateTime.hour().minute().locale(locale))
            : d.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(locale))
    }

    static func ago(_ d: Date, now: Date = Date()) -> String {
        let m = Int(now.timeIntervalSince(d) / 60)
        if m < 1 { return L.t("nyss", "just now") }
        if m < 60 { return L.t("\(m) min sedan", "\(m) min ago") }
        return time(d)
    }
}
