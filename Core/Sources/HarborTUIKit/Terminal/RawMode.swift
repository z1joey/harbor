import Foundation
import Darwin

/// termios raw-mode handling. `enable` returns the previous settings to pass
/// back to `restore`; both are no-op safe (nil / not a tty).
enum TerminalRawMode {
    static func enable() -> termios? {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }
        var raw = original
        cfmakeraw(&raw)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { return nil }
        return original
    }

    static func restore(_ original: termios?) {
        guard var original else { return }
        tcsetattr(STDIN_FILENO, TCSANOW, &original)
    }
}
