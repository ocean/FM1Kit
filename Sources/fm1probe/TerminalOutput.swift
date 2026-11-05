import Darwin

/// Makes sure fm1probe's output reaches the terminal, and says so when some of it didn't.
///
/// A program that ends badly while it has the terminal, such as `screen` on a USB serial port that
/// disappears, can leave the terminal non-blocking. Every later program in that window then loses
/// output whenever the terminal is briefly busy, and Swift's `print` drops it without a word: an
/// install looks as if it stopped when it carried on to the end. So fm1probe makes its output
/// blocking again first, which also mends the window, and checks on the way out that nothing was
/// lost.
func keepOutputReachingTheTerminal() {
    for descriptor in [STDOUT_FILENO, STDERR_FILENO] {
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0, flags & O_NONBLOCK != 0 {
            _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK)
        }
    }
    atexit {
        fflush(stdout)
        guard ferror(stdout) != 0 else { return }
        let warning = """

            fm1probe: some of its output was lost: the terminal refused it. What it was doing may \
            still have finished. Check the FM-1 with `fm1probe identify`, and the --log file if \
            you gave one.

            """
        _ = warning.withCString { write(STDERR_FILENO, $0, strlen($0)) }
        _exit(1)
    }
}
