import Foundation

/// The used share of each provider's weekly window across its current cycle,
/// sampled from the store's own polls while "Show usage history" is on.
struct UsageHistory {
    struct Sample: Codable, Equatable {
        let at: Date
        let used: Double
    }

    struct Segment {
        let from: Sample
        let to: Sample
        /// False across a silence long enough that the app may have been
        /// closed or asleep: the chart must not present it as measured.
        let observed: Bool
    }

    struct Series: Codable, Equatable {
        let windowID: String
        let cycleStart: Date
        var samples: [Sample]

        var segments: [Segment] {
            zip(samples, samples.dropFirst()).map {
                Segment(from: $0, to: $1,
                        observed: $1.at.timeIntervalSince($0.at) < UsageHistory.gapThreshold)
            }
        }
    }

    /// With no change, one sample per half hour still shows the app was
    /// watching. Past the gap threshold, a flat stretch is unobserved.
    static let heartbeat: TimeInterval = 30 * 60
    static let gapThreshold: TimeInterval = 45 * 60
    /// `resetsAt` moves by seconds between polls; a new cycle moves it by hours.
    static let cycleTolerance: TimeInterval = 5 * 60

    private let defaults: UserDefaults
    private let key = "usageHistory"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Every stored series, decoded once for the caller to keep.
    func all() -> [String: Series] {
        guard let data = defaults.data(forKey: key),
              let all = try? JSONDecoder().decode([String: Series].self, from: data)
        else { return [:] }
        return all
    }

    /// Records the snapshot's weekly window, or its headline without one, and
    /// returns that provider's series: nil when there is nothing to chart.
    @discardableResult
    func record(_ snapshot: ProviderSnapshot, at now: Date) -> Series? {
        guard let window = snapshot.weeklyLimitWindow ?? snapshot.headline,
              let reported = window.usedFraction, reported.isFinite,
              let duration = window.duration, duration.isFinite, duration > 0,
              let resetsAt = window.resetsAt else { return nil }
        // A tenth of a percent is under a pixel on the chart. Finer values from
        // money- or token-metered windows would add a sample on nearly every poll.
        let used = (reported * 1000).rounded() / 1000
        let cycleStart = resetsAt.addingTimeInterval(-duration)
        var all = all()
        var series = all[snapshot.id]
        if let current = series, current.windowID != window.id
            || abs(current.cycleStart.timeIntervalSince(cycleStart)) > Self.cycleTolerance {
            series = nil
        }
        var updated = series ?? Series(windowID: window.id, cycleStart: cycleStart, samples: [])
        if let last = updated.samples.last,
           now <= last.at || (last.used == used && now.timeIntervalSince(last.at) < Self.heartbeat) {
            return updated
        }
        let kept = updated.cycleStart
        updated.samples.removeAll { $0.at < kept }
        updated.samples.append(Sample(at: now, used: used))
        all[snapshot.id] = updated
        save(all)
        return updated
    }

    func forget(_ providerID: String) {
        var all = all()
        guard all.removeValue(forKey: providerID) != nil else { return }
        save(all)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }

    private func save(_ all: [String: Series]) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        defaults.set(data, forKey: key)
    }
}

extension ProviderSnapshot {
    /// The series and the window it charts, when the card has a chart to draw.
    /// Two samples at least: one point is not a line.
    var chartedHistory: (series: UsageHistory.Series, window: LimitWindow)? {
        guard let usageHistory, usageHistory.samples.count >= 2,
              localModel == nil, statusMessage == nil,
              // By the series' own id: the ring overlays rename `headlineID` and
              // `weeklyID` on the way to the card, but never the window ids.
              let window = windows.first(where: { $0.id == usageHistory.windowID }),
              window.resetsAt != nil, (window.duration ?? 0) > 0
        else { return nil }
        return (usageHistory, window)
    }
}

extension UsageHistory.Series {
    /// The sample under `date` while the app was watching; nil across a gap,
    /// or further than half a gap from either end of the recorded span.
    func reading(at date: Date) -> UsageHistory.Sample? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let reach = UsageHistory.gapThreshold / 2
        if date < first.at { return first.at.timeIntervalSince(date) <= reach ? first : nil }
        if date > last.at { return date.timeIntervalSince(last.at) <= reach ? last : nil }
        guard let segment = segments.first(where: { $0.from.at <= date && date <= $0.to.at }),
              segment.observed else { return nil }
        return date.timeIntervalSince(segment.from.at) <= segment.to.at.timeIntervalSince(date)
            ? segment.from : segment.to
    }
}

extension UsageHistory {
    /// The line under the chart: the latest reading and the pace without a
    /// pointer, the reading under it with one. Readings print like the rest of
    /// the card, `~` included; pace is time arithmetic and never carries one.
    static func detail(series: Series, window: LimitWindow, hovering date: Date?, now: Date,
                       fidelity: Fidelity = .official, staleSince: Date? = nil,
                       calendar: Calendar = .current, locale: Locale = L10n.locale) -> String {
        let duration = max(1, window.duration ?? 1)
        let start = (window.resetsAt ?? now).addingTimeInterval(-duration)
        func pace(at moment: Date) -> Int {
            Int((min(max(moment.timeIntervalSince(start) / duration, 0), 1) * 100).rounded())
        }
        func reading(_ fraction: Double) -> String { "\(fidelity.qualifier)\(Percent.text(for: fraction))" }
        func time(_ moment: Date) -> String {
            let formatter = ResetCopy.formatter(for: calendar)
            formatter.locale = locale
            // Past or future, a weekday alone only names a day within a week.
            let days = abs(ResetCopy.daysApart(from: moment, to: now, calendar: calendar))
            formatter.setLocalizedDateFormatFromTemplate(days == 0 ? "j:mm" : days < 7 ? "E j:mm" : "MMM d j:mm")
            return formatter.string(from: moment)
        }

        guard let date else {
            guard let latest = window.usedFraction ?? series.samples.last?.used else { return "" }
            // A remembered reading is dated, as the card's header dates it.
            if let staleSince {
                return L10n.t("\(time(staleSince)) · \(reading(latest))% · pace \(pace(at: staleSince))%",
                              locale: locale)
            }
            return L10n.t("Now \(reading(latest))% · pace \(pace(at: now))%", locale: locale)
        }
        if date > now {
            return L10n.t("\(time(date)) · pace \(pace(at: date))%", locale: locale)
        }
        guard let sample = series.reading(at: date) else {
            return L10n.t("\(time(date)) · not observed", locale: locale)
        }
        return L10n.t("\(time(sample.at)) · \(reading(sample.used))% · pace \(pace(at: sample.at))%",
                      locale: locale)
    }
}
