import Foundation

/// Works out how far the update loader has got, whatever order it reads the image in.
///
/// Real loaders differ: M-VAVE's V15 loader reads its image once, backwards, while Felucca's
/// reads forwards and then reads the same region again, probably checking what it wrote. So
/// progress is the share of the image read so far, not the furthest offset. Once most of the
/// image has been read, a run of full-size reads of ground already covered starts a checking
/// pass, with its own progress: the share of what was written that has been read again. Single
/// or short re-reads don't count: loaders re-read parts of the header as they start and finish.
///
/// A loader doesn't always read the whole image (V15's doesn't), so writing progress can end
/// below 1.
struct WriteProgress {
    /// How much of the image must be read before re-reads can count as checking.
    static let checkingThreshold = 0.5
    /// How many full-size re-reads in a row start a checking pass.
    static let rereadsBeforeChecking = 3

    /// The logical image's length in bytes.
    let imageLength: Int
    /// Every image byte read while writing.
    private var written = IndexSet()
    /// Every image byte read again while checking.
    private var checked = IndexSet()
    /// Full-size re-reads in a row that might be the start of a checking pass.
    private var rereads: [Range<Int>] = []
    /// Reads answered in the current step.
    private var requests = 0
    /// True once the loader has started reading the image again.
    private var isChecking = false

    /// Starts tracking a write of an image this long.
    ///
    /// - Parameter imageLength: The logical image's length in bytes.
    init(imageLength: Int) {
        self.imageLength = max(imageLength, 1)
    }

    /// Records one answered read and returns the progress event to report.
    ///
    /// - Parameter request: The read the loader made, already checked to lie within the image.
    /// - Returns: ``UpdateEvent/writing(fraction:requests:)``, or
    ///   ``UpdateEvent/checking(fraction:requests:)`` once a checking pass has started.
    mutating func record(_ request: FM1ReadRequest) -> UpdateEvent {
        let start = Int(request.address)
        let range = start..<(start + request.length)
        let isNew = !written.contains(integersIn: range)
        requests += 1

        if isChecking, isNew {
            // New ground after all: the loader is still writing.
            isChecking = false
            checked = IndexSet()
            requests = 1
        }
        if isChecking {
            checked.insert(integersIn: range)
            return checkingEvent
        }

        let mightBeChecking =
            !isNew && request.length == FM1Message.maximumReadLength
            && Double(written.count) / Double(imageLength) >= Self.checkingThreshold
        rereads = mightBeChecking ? rereads + [range] : []
        if rereads.count >= Self.rereadsBeforeChecking {
            isChecking = true
            requests = rereads.count
            for reread in rereads {
                checked.insert(integersIn: reread)
            }
            rereads = []
            return checkingEvent
        }
        written.insert(integersIn: range)
        return .writing(fraction: min(Double(written.count) / Double(imageLength), 1), requests: requests)
    }

    /// Progress through the checking pass.
    private var checkingEvent: UpdateEvent {
        .checking(fraction: min(Double(checked.count) / Double(written.count), 1), requests: requests)
    }
}
