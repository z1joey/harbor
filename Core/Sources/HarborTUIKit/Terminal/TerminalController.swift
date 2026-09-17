import Foundation
import Darwin
import HarborCore

/// Owns the terminal session: raw mode, alternate screen, stdin key decoding,
/// SIGWINCH resize and SIGTERM cleanup, and presents Screen frames via a
/// minimal-diff encoder. All callbacks fire on the main queue; present() is
/// meant to be called from the main thread too.
public final class TerminalController {
    /// The frame being composed. Mutate it, then call `present()`.
    public var screen: Screen

    public var onKey: ((Key) -> Void)?
    public var onResize: (() -> Void)?
    public var onTerminate: (() -> Void)?

    private var savedTermios: termios?
    private var keySource: DispatchSourceRead?
    private var winchSource: DispatchSourceSignal?
    private var termSource: DispatchSourceSignal?
    private var parser = KeyParser()
    private let output = FileHandle.standardOutput
    private var previous: Screen?
    private var finished = false

    public init() throws {
        guard let saved = TerminalRawMode.enable() else {
            throw HarborError("harbor-tui needs a TTY (run it in a terminal).")
        }
        savedTermios = saved
        let size = Self.currentSize() ?? (80, 24)
        screen = Screen(width: size.width, height: size.height)
        writeRaw(Array("\u{1B}[?1049h\u{1B}[?25l".utf8)) // alternate screen, hide cursor
        installSources()
    }

    deinit {
        shutdown()
    }

    // MARK: - Frame output

    /// Encodes and writes the diff between the last presented frame and the
    /// current screen contents.
    public func present() {
        let bytes = screen.encodeChanges(previous: previous)
        previous = screen
        if !bytes.isEmpty {
            writeRaw(bytes)
        }
    }

    /// Restores the terminal (cursor, main screen buffer, termios settings)
    /// and stops all sources. Idempotent.
    public func shutdown() {
        guard !finished else { return }
        finished = true
        keySource?.cancel()
        winchSource?.cancel()
        termSource?.cancel()
        writeRaw(Array("\u{1B}[0m\u{1B}[?25h\u{1B}[?1049l".utf8)) // reset style, show cursor, leave alt screen
        TerminalRawMode.restore(savedTermios)
    }

    // MARK: - Sources

    private func installSources() {
        let keySource = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        keySource.setEventHandler { [weak self] in
            self?.drainStdin()
        }
        keySource.resume()
        self.keySource = keySource

        signal(SIGWINCH, SIG_IGN)
        let winchSource = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        winchSource.setEventHandler { [weak self] in
            self?.handleResize()
        }
        winchSource.resume()
        self.winchSource = winchSource

        signal(SIGTERM, SIG_IGN)
        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource.setEventHandler { [weak self] in
            guard let self else { return }
            if let onTerminate = self.onTerminate {
                onTerminate()
            } else {
                self.shutdown()
                exit(0)
            }
        }
        termSource.resume()
        self.termSource = termSource
    }

    private func drainStdin() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        guard count > 0 else {
            // EOF: treat like a quit signal so the app loop can clean up.
            if let onTerminate {
                onTerminate()
            } else {
                shutdown()
                exit(0)
            }
            return
        }
        for key in parser.feed(Array(buffer[0..<count])) {
            onKey?(key)
        }
    }

    private func handleResize() {
        guard let size = Self.currentSize(), size.width > 0, size.height > 0 else { return }
        screen.resize(width: size.width, height: size.height)
        onResize?()
    }

    // MARK: - Helpers

    public static func currentSize() -> (width: Int, height: Int)? {
        var ws = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 else { return nil }
        return (Int(ws.ws_col), Int(ws.ws_row))
    }

    private func writeRaw(_ bytes: [UInt8]) {
        output.write(Data(bytes))
    }
}
