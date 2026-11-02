// Copies every screenshot macOS saves (⌘⇧3, ⌘⇧4, ⌘⇧5) to the clipboard, so a plain ⌘⇧4
// behaves like ⌘⌃⇧4 while the file is still kept.
//
// Usage: screenshot-to-clipboard [--dir PATH]
//   --dir PATH   watch PATH instead of the folder macOS saves screenshots to (for testing)

import AppKit
import CoreServices

enum Log {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func info(_ message: String) {
        print("[\(formatter.string(from: Date()))] \(message)")
    }
}

// FSEvents reports resolved paths (/private/var/...), so compare against resolved paths too.
func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

enum Settings {
    private static let domain = "com.apple.screencapture" as CFString

    private static func value(_ key: String) -> Any? {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(key as CFString, domain)
    }

    static var thumbnailEnabled: Bool { value("show-thumbnail") as? Bool ?? true }

    static var customNamePrefix: String? {
        guard let name = value("name") as? String, !name.isEmpty else { return nil }
        return name
    }

    static func screenshotDirectory() -> String {
        if let location = value("location") as? String {
            let path = (location as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                return realPath(path)
            }
        }
        return realPath(NSHomeDirectory() + "/Desktop")
    }
}

final class FolderWatcher {
    let directory: String
    private let onFileEvent: (String) -> Void
    private var stream: FSEventStreamRef?

    init(directory: String, onFileEvent: @escaping (String) -> Void) {
        self.directory = directory
        self.onFileEvent = onFileEvent
    }

    func start() -> Bool {
        // The stream retains this object, so a callback that is already queued can't outlive it.
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<FolderWatcher>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<FolderWatcher>.fromOpaque(info).release()
            },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self)
            for index in 0..<count {
                guard let path = paths[index] as? String else { continue }
                watcher.handle(path: path, flags: eventFlags[index])
            }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [directory] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags)
        else { return false }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        self.stream = stream
        return true
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func handle(path: String, flags: FSEventStreamEventFlags) {
        let isFile = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0
        guard isFile, (path as NSString).deletingLastPathComponent == directory else { return }
        onFileEvent(path)
    }
}

final class ScreenshotCopier {
    private enum Outcome {
        case done
        case retry(problem: String?)
    }

    private struct Signature: Equatable {
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "gif", "heic", "bmp"]
    private static let defaultNamePrefixes = ["Screenshot", "Screen Shot"]
    private static let screenshotMarker = "com.apple.metadata:kMDItemIsScreenCapture"
    private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    // Renaming or touching an old screenshot must not put it back on the clipboard.
    private static let maxFileAge: TimeInterval = 60
    private static let settleDelay: TimeInterval = 0.1
    private static let retryDelay: TimeInterval = 0.2
    private static let maxAttempts = 15
    private static let rememberedCopies = 64

    private var pending: [String: DispatchWorkItem] = [:]
    private var signatures: [String: Signature] = [:]
    private var copiedFiles: [String] = []

    func fileChanged(at path: String) {
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        guard !name.hasPrefix("."), Self.imageExtensions.contains(ext) else { return }
        schedule(path, attempt: 0, delay: Self.settleDelay)
    }

    private func schedule(_ path: String, attempt: Int, delay: TimeInterval) {
        pending[path]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.process(path, attempt: attempt) }
        pending[path] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func process(_ path: String, attempt: Int) {
        pending[path] = nil
        switch evaluate(path) {
        case .done:
            signatures[path] = nil
        case .retry(let problem):
            if attempt + 1 < Self.maxAttempts {
                schedule(path, attempt: attempt + 1, delay: Self.retryDelay)
            } else {
                signatures[path] = nil
                if let problem {
                    Log.info("Gave up on \((path as NSString).lastPathComponent): \(problem)")
                }
            }
        }
    }

    private func evaluate(_ path: String) -> Outcome {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return .done }

        // Some filesystems don't report a creation time; use the modification time for the age check there.
        let born = info.st_birthtimespec
        let created = born.tv_sec > 0 ? born : info.st_mtimespec
        guard Date().timeIntervalSince1970 - TimeInterval(created.tv_sec) < Self.maxFileAge else { return .done }
        let identity = "\(info.st_dev):\(info.st_ino):\(born.tv_sec).\(born.tv_nsec)"
        guard !copiedFiles.contains(identity) else { return .done }

        // macOS may add its screenshot xattr a moment after the file appears, so keep looking for a while.
        let name = (path as NSString).lastPathComponent
        guard isScreenshot(path, named: name) else { return .retry(problem: nil) }
        guard info.st_size > 0 else { return .retry(problem: "the file is empty") }

        // Only copy once the file has stopped changing, so a half-written file is never used.
        let signature = Signature(
            size: info.st_size,
            modifiedSeconds: info.st_mtimespec.tv_sec,
            modifiedNanoseconds: info.st_mtimespec.tv_nsec)
        guard signatures[path] == signature else {
            signatures[path] = signature
            return .retry(problem: nil)
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let image = NSBitmapImageRep(data: data)
        else { return .retry(problem: "it can't be read as an image (check folder permissions)") }
        guard copyToClipboard(data, image) else { return .retry(problem: "the clipboard rejected it") }

        copiedFiles.append(identity)
        if copiedFiles.count > Self.rememberedCopies { copiedFiles.removeFirst() }
        Log.info("Copied \(name) to the clipboard (\(image.pixelsWide)×\(image.pixelsHigh) px)")
        return .done
    }

    private func isScreenshot(_ path: String, named name: String) -> Bool {
        if getxattr(path, Self.screenshotMarker, nil, 0, 0, XATTR_NOFOLLOW) >= 0 { return true }
        let prefixes = (Settings.customNamePrefix.map { [$0] } ?? []) + Self.defaultNamePrefixes
        return prefixes.contains { name.hasPrefix($0) }
    }

    // Same representations as ⌘⌃⇧4: PNG (the original bytes when the file is a PNG) plus TIFF.
    private func copyToClipboard(_ data: Data, _ image: NSBitmapImageRep) -> Bool {
        let png = data.starts(with: Self.pngSignature) ? data : image.representation(using: .png, properties: [:])
        guard let png else { return false }

        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = image.tiffRepresentation { item.setData(tiff, forType: .tiff) }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}

final class Controller {
    private let directoryOverride: String?
    private let copier = ScreenshotCopier()
    private var watcher: FolderWatcher?
    private var lastProblem: String?
    private var timer: DispatchSourceTimer?

    init(directoryOverride: String?) {
        self.directoryOverride = directoryOverride.map(realPath)
    }

    func run() {
        reconcile()
        // Follow changes to the screenshot location, and retry if the folder wasn't readable yet.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.reconcile() }
        timer.resume()
        self.timer = timer
    }

    private func reconcile() {
        let directory = directoryOverride ?? Settings.screenshotDirectory()
        if watcher?.directory == directory { return }
        watcher?.stop()
        watcher = nil

        if let problem = accessProblem(to: directory) { return report(problem) }
        let copier = self.copier
        let newWatcher = FolderWatcher(directory: directory) { copier.fileChanged(at: $0) }
        guard newWatcher.start() else { return report("Could not start watching \(directory)") }

        watcher = newWatcher
        lastProblem = nil
        Log.info("Watching \(directory) for new screenshots")
        if directoryOverride == nil, Settings.thumbnailEnabled {
            Log.info("Note: the floating thumbnail is on, so macOS only saves (and this tool only copies) each "
                + "screenshot a few seconds after it is taken. To make it instant: "
                + "defaults write com.apple.screencapture show-thumbnail -bool false")
        }
    }

    private func accessProblem(to directory: String) -> String? {
        guard let handle = opendir(directory) else {
            return "Can't read \(directory): \(String(cString: strerror(errno))). Allow access in System Settings > "
                + "Privacy & Security > Files & Folders (or Full Disk Access) for \(CommandLine.arguments[0])"
        }
        closedir(handle)
        return nil
    }

    private func report(_ problem: String) {
        guard problem != lastProblem else { return }
        lastProblem = problem
        Log.info(problem)
    }
}

func printUsage() {
    print("""
        Usage: screenshot-to-clipboard [--dir PATH]

        Copies every new macOS screenshot to the clipboard.

          --dir PATH   watch PATH instead of the folder macOS saves screenshots to
          -h, --help   show this help
        """)
}

setvbuf(stdout, nil, _IOLBF, 0)

var directoryOverride: String?
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--dir":
        guard let value = arguments.popFirst() else {
            fputs("--dir needs a path\n", stderr)
            exit(2)
        }
        directoryOverride = value
    case "-h", "--help":
        printUsage()
        exit(0)
    default:
        fputs("Unknown option: \(argument)\n", stderr)
        exit(2)
    }
}

Log.info("screenshot-to-clipboard started")
let controller = Controller(directoryOverride: directoryOverride)
controller.run()

var signalSources: [DispatchSourceSignal] = []
for signalNumber in [SIGINT, SIGTERM] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        Log.info("Stopping")
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

dispatchMain()
