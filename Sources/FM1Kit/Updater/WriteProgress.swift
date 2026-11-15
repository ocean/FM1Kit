import Foundation

/// Works out how far the update loader has got, whatever order it reads the image in.
///
/// Real loaders differ: M-VAVE's V15 loader reads its image once, backwards, while Felucca's
/// reads forwards to check the package and then reads the same region again, erasing and
/// writing as it goes (each 4 KB block's erase shows as a pause of about 60 ms). So
/// progress is the share of the region read so far, not the furthest offset. The region is the
/// firmware image's application area, which every loader seen writes; reads outside it (the
/// boot area some loaders rewrite first, and the header) leave progress unchanged. Once most of
/// the region has been read, a run of full-size reads of ground already covered starts a second
/// pass, with its own progress: the share of the first pass's ground read again. Single
/// or short re-reads don't count: loaders re-read parts of the header as they start and finish.
///
/// A loader could skip part of the region, so writing progress can end below 1.
///
/// Reads of a package's resources part, past its header, are the loader writing the resources,
/// with their own progress.
struct WriteProgress {
    /// How much of the region must be read before re-reads can count as checking.
    static let checkingThreshold = 0.5
    /// How many full-size re-reads in a row start a second pass.
    static let rereadsBeforeChecking = 3

    /// The part of the logical image that counts towards progress.
    let region: Range<Int>
    /// The resources part's payload in the logical image: the part after the 512 bytes its
    /// header is read in, which fm1-base's loader reads even when it leaves the resources.
    let resourcePayload: Range<Int>?
    /// Every byte of the resources' payload read.
    private var resourcesRead = IndexSet()
    /// Reads of the resources' payload answered.
    private var resourceRequests = 0
    /// Every byte of the region read while writing.
    private var written = IndexSet()
    /// Every byte of the region read again while checking.
    private var checked = IndexSet()
    /// Full-size re-reads in a row that might be the start of a second pass.
    private var rereads: [Range<Int>] = []
    /// Reads answered in the current step.
    private var requests = 0
    /// True once the loader has started reading the image again.
    private var isChecking = false

    /// The last event reported, repeated for reads outside the region.
    private var lastEvent: UpdateEvent?

    /// Starts tracking a write that counts reads within this part of the logical image.
    ///
    /// - Parameters:
    ///   - region: The bytes that count, normally the application area.
    ///   - resources: The package's resources part, if it carries one.
    init(region: Range<Int>, resources: Range<Int>? = nil) {
        self.region = region
        resourcePayload = resources.map { ($0.lowerBound + FM1Message.maximumReadLength)..<$0.upperBound }
    }

    /// Records one answered read and returns the progress event to report.
    ///
    /// - Parameter request: The read the loader made, already checked to lie within the image.
    /// - Returns: ``UpdateEvent/writing(fraction:requests:)``, or
    ///   ``UpdateEvent/checking(fraction:requests:)`` once a second pass has started.
    mutating func record(_ request: FM1ReadRequest) -> UpdateEvent {
        let start = Int(request.address)
        if let resourcePayload {
            let payloadRead = (start..<(start + request.length)).clamped(to: resourcePayload)
            if !payloadRead.isEmpty {
                resourcesRead.insert(integersIn: payloadRead)
                resourceRequests += 1
                let fraction = min(Double(resourcesRead.count) / Double(max(resourcePayload.count, 1)), 1)
                return report(.writingResources(fraction: fraction, requests: resourceRequests))
            }
        }
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

    /// True once nearly all of the region has been read in the pass under way, so the loader may
    /// restart without asking to finish.
    ///
    /// Once a second pass starts, only its progress counts, as Felucca's loader writes in it.
    var isNearlyWritten: Bool {
        (isChecking ? checkedFraction : writtenFraction) >= Self.nearlyWrittenThreshold
    }

    /// How much of the region must be read for ``isNearlyWritten``.
    static let nearlyWrittenThreshold = 0.95

    /// The share of the region written so far.
    private var writtenFraction: Double {
        region.isEmpty ? 1 : min(Double(written.count) / Double(region.count), 1)
    }

    /// The share of the first pass's ground read again in the second.
    private var checkedFraction: Double {
        written.isEmpty ? 0 : min(Double(checked.count) / Double(written.count), 1)
    }

    /// Progress through the second pass.
    private var checkingEvent: UpdateEvent {
        .checking(fraction: checkedFraction, requests: requests)
    }

    /// The last event again, with the new request count, for a read outside the region.
    private var repeatedEvent: UpdateEvent {
        switch lastEvent {
        case .checking(let fraction, _): .checking(fraction: fraction, requests: requests)
        case .writing(let fraction, _): .writing(fraction: fraction, requests: requests)
        case .writingResources(let fraction, _): .writingResources(fraction: fraction, requests: resourceRequests)
        default: .writing(fraction: 0, requests: requests)
        }
    }

    /// Remembers an event so reads outside the region can repeat it.
    private mutating func report(_ event: UpdateEvent) -> UpdateEvent {
        lastEvent = event
        return event
    }
}
