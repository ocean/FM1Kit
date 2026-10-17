import Foundation

/// Works out how far the update loader has got, whatever order it reads the image in.
///
/// Real loaders differ: M-VAVE's V15 loader reads its image once, backwards, while Felucca's
/// reads forwards and then reads the same region again, probably checking what it wrote. So
/// progress is the share of the region read so far, not the furthest offset. The region is the
/// firmware image's application area, which every loader seen writes; reads outside it (the
/// boot area some loaders rewrite first, and the header) leave progress unchanged. Once most of
/// the region has been read, a run of full-size reads of ground already covered starts a checking
/// pass, with its own progress: the share of what was written that has been read again. Single
/// or short re-reads don't count: loaders re-read parts of the header as they start and finish.
///
/// A loader could skip part of the region, so writing progress can end below 1.
struct WriteProgress {
    /// How much of the region must be read before re-reads can count as checking.
    static let checkingThreshold = 0.5
    /// How many full-size re-reads in a row start a checking pass.
    static let rereadsBeforeChecking = 3

    /// The part of the logical image that counts towards progress.
    let region: Range<Int>
    /// Every byte of the region read while writing.
    private var written = IndexSet()
    /// Every byte of the region read again while checking.
    private var checked = IndexSet()
    /// Full-size re-reads in a row that might be the start of a checking pass.
    private var rereads: [Range<Int>] = []
    /// Reads answered in the current step.
    private var requests = 0
    /// True once the loader has started reading the image again.
    private var isChecking = false

    /// The last event reported, repeated for reads outside the region.
    private var lastEvent: UpdateEvent?

    /// Starts tracking a write that counts reads within this part of the logical image.
    ///
    /// - Parameter region: The bytes that count, normally the application area.
    init(region: Range<Int>) {
        self.region = region
    }

    /// Records one answered read and returns the progress event to report.
    ///
    /// - Parameter request: The read the loader made, already checked to lie within the image.
    /// - Returns: ``UpdateEvent/writing(fraction:requests:)``, or
    ///   ``UpdateEvent/checking(fraction:requests:)`` once a checking pass has started.
    mutating func record(_ request: FM1ReadRequest) -> UpdateEvent {
        let start = Int(request.address)
        let range = (start..<(start + request.length)).clamped(to: region)
        requests += 1
        guard !range.isEmpty else {
            return repeatedEvent
        }
        let isNew = !written.contains(integersIn: range)

        if isChecking, isNew {
            // New ground after all: the loader is still writing.
            isChecking = false
            checked = IndexSet()
            requests = 1
        }
        if isChecking {
            checked.insert(integersIn: range)
            return report(checkingEvent)
        }

        let mightBeChecking =
            !isNew && request.length == FM1Message.maximumReadLength
            && writtenFraction >= Self.checkingThreshold
        rereads = mightBeChecking ? rereads + [range] : []
        if rereads.count >= Self.rereadsBeforeChecking {
            isChecking = true
            requests = rereads.count
            for reread in rereads {
                checked.insert(integersIn: reread)
            }
            rereads = []
            return report(checkingEvent)
        }
        written.insert(integersIn: range)
        return report(.writing(fraction: writtenFraction, requests: requests))
    }

    /// The share of the region written so far.
    private var writtenFraction: Double {
        region.isEmpty ? 1 : min(Double(written.count) / Double(region.count), 1)
    }

    /// Progress through the checking pass.
    private var checkingEvent: UpdateEvent {
        .checking(fraction: min(Double(checked.count) / Double(written.count), 1), requests: requests)
    }

    /// The last event again, with the new request count, for a read outside the region.
    private var repeatedEvent: UpdateEvent {
        switch lastEvent {
        case .checking(let fraction, _): .checking(fraction: fraction, requests: requests)
        case .writing(let fraction, _): .writing(fraction: fraction, requests: requests)
        default: .writing(fraction: 0, requests: requests)
        }
    }

    /// Remembers an event so reads outside the region can repeat it.
    private mutating func report(_ event: UpdateEvent) -> UpdateEvent {
        lastEvent = event
        return event
    }
}
