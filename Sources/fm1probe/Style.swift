/// Styles fm1probe's output in a terminal: bold section headings, coloured labels for what went
/// wrong or right, dim progress, and the steps to take afterwards as a numbered list at the end.
///
/// Output stays plain text when it isn't going to a terminal, when `NO_COLOR` is set, or when
/// `TERM` is `dumb`, so logs and scripts read it as before.
enum Style {
    /// True when output goes to a terminal that takes colour.
    static let isEnabled = outputTakesColour()

    /// How wide a section heading's rule is, in characters.
    static let ruleWidth = 64

    /// Prints a blank line, then `title` as a bold heading with a rule after it.
    static func heading(_ title: String) {
        let rule = String(repeating: "─", count: max(ruleWidth - title.count - 4, 3))
        print("\n" + bold("── \(title) \(rule)"))
    }

    /// What went wrong, after a red "Stopped:".
    static func stopped(_ text: String) -> String {
        styled("Stopped:", "1;31") + " " + text
    }

    /// A warning, after a yellow "Warning:".
    static func warning(_ text: String) -> String {
        styled("Warning:", "1;33") + " " + text
    }

    /// Something finished well, in green.
    static func done(_ text: String) -> String {
        colour(text, .green)
    }

    /// Colours for text that says how something went.
    enum Colour: String {
        case red = "31"
        case green = "32"
        case yellow = "33"
        case cyan = "36"
    }

    /// Text in a colour.
    static func colour(_ text: String, _ colour: Colour) -> String {
        styled(text, colour.rawValue)
    }

    /// A line as it happens: the time, dim, then `text`.
    static func logged(_ text: String) -> String {
        dim(timestamp()) + "  " + text
    }

    /// A progress line as it happens, all dim, with the time first.
    static func progress(_ text: String) -> String {
        dim("\(timestamp())  \(text)")
    }

    /// Prints the steps to take afterwards under a "Next" heading, numbered; nothing when there
    /// are none.
    static func nextSteps(_ steps: [String]) {
        guard !steps.isEmpty else { return }
        heading("Next")
        for (index, step) in steps.enumerated() {
            print("  \(bold("\(index + 1).")) \(step)")
        }
    }

    /// Bold text.
    static func bold(_ text: String) -> String {
        styled(text, "1")
    }

    /// Dim text, for progress.
    static func dim(_ text: String) -> String {
        styled(text, "2")
    }

    /// `text` wrapped in an ANSI style such as `1;31`, when styling is on.
    private static func styled(_ text: String, _ code: String) -> String {
        isEnabled ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }
}
