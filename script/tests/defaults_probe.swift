// Temporary CI probe: shows what cfprefsd leaves in ~/Library/Preferences for a
// UserDefaults suite under each cleanup strategy, both while the writing process is
// still alive and after it has exited.
//
//   swift defaults_probe.swift write <list-file> <scratch-dir>
//   swift defaults_probe.swift check <list-file>
import Foundation

let preferences = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Preferences", isDirectory: true)

func fileURL(_ suite: String) -> URL {
    suite.hasPrefix("/")
        ? URL(fileURLWithPath: suite + ".plist")
        : preferences.appendingPathComponent("\(suite).plist")
}

func fileState(_ suite: String) -> String {
    guard suite.hasPrefix("/") else { return state(of: fileURL(suite)) }
    let withExtension: String = state(of: fileURL(suite))
    let bare: String = state(of: URL(fileURLWithPath: suite))
    let inPreferences: String = state(of: preferences.appendingPathComponent(
        URL(fileURLWithPath: suite).lastPathComponent + ".plist"
    ))
    return "path.plist: \(withExtension), path: \(bare), in Preferences: \(inPreferences)"
}

func state(of url: URL) -> String {
    guard let data = try? Data(contentsOf: url) else { return "no file" }
    guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
          let dictionary = plist as? [String: Any] else {
        return "unreadable file (\(data.count) bytes)"
    }
    let keys: [String] = dictionary.keys.sorted()
    return keys.isEmpty ? "EMPTY file {}" : "file with keys \(keys)"
}

func writeKeys(_ defaults: UserDefaults) {
    defaults.set(true, forKey: "one")
    defaults.set(Data([1, 2]), forKey: "two")
    defaults.set(Date(), forKey: "three")
}

func removeKeys(_ suite: String) {
    autoreleasepool {
        let defaults = UserDefaults(suiteName: suite)!
        let keys: [String] = defaults.persistentDomain(forName: suite).map { Array($0.keys) } ?? []
        for key in keys {
            defaults.removeObject(forKey: key)
        }
        defaults.synchronize()
    }
}

func removeDomain(_ suite: String) {
    autoreleasepool {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.synchronize()
        defaults.removePersistentDomain(forName: suite)
        defaults.synchronize()
    }
}

func spin(_ seconds: Double) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
}

func deleteFile(_ suite: String) {
    try? FileManager.default.removeItem(at: fileURL(suite))
    if suite.hasPrefix("/") {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: suite))
    }
}

let arguments = CommandLine.arguments
let mode = arguments[1]
let listURL = URL(fileURLWithPath: arguments[2])

if mode == "check" {
    let lines = (try? String(contentsOf: listURL, encoding: .utf8)) ?? ""
    for line in lines.split(separator: "\n") {
        let parts = line.split(separator: "\t").map(String.init)
        print("\(parts[0]) | after exit: \(fileState(parts[1]))")
        deleteFile(parts[1])
    }
    exit(0)
}

let scratch = arguments[3]
var records: [String] = []
var retained: [UserDefaults] = []

func run(_ label: String, suite: String? = nil, retain: Bool, _ body: (String) -> Void) {
    let suite = suite ?? "CopyClipLiteProbe-\(UUID().uuidString)"
    autoreleasepool {
        let defaults = UserDefaults(suiteName: suite)!
        writeKeys(defaults)
        if retain { retained.append(defaults) }
    }
    body(suite)
    spin(2)
    print("\(label) | alive after 2 s: \(fileState(suite))")
    records.append("\(label)\t\(suite)")
}

run("R1 released; removeKeys, delete", retain: false) { suite in
    removeKeys(suite)
    deleteFile(suite)
}
run("R2 retained; removeKeys, delete", retain: true) { suite in
    removeKeys(suite)
    deleteFile(suite)
}
run("R3 released; spin 2 s, removeKeys, spin 2 s, delete", retain: false) { suite in
    spin(2)
    removeKeys(suite)
    spin(2)
    deleteFile(suite)
}
run("R4 retained; spin 2 s, removeKeys, spin 2 s, delete", retain: true) { suite in
    spin(2)
    removeKeys(suite)
    spin(2)
    deleteFile(suite)
}
run("R5 released; removeDomain, spin 2 s, delete", retain: false) { suite in
    removeDomain(suite)
    spin(2)
    deleteFile(suite)
}
run("R6 released; removeDomain, delete", retain: false) { suite in
    removeDomain(suite)
    deleteFile(suite)
}
run("R7 released; absolute-path suite, removeKeys, delete",
    suite: "\(scratch)/CopyClipLiteProbe-\(UUID().uuidString)", retain: false) { suite in
    print("R7 before cleanup: \(fileState(suite))")
    removeKeys(suite)
    deleteFile(suite)
}
run("R8 released; defaults delete <suite> after removeKeys", retain: false) { suite in
    removeKeys(suite)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    process.arguments = ["delete", suite]
    try? process.run()
    process.waitUntilExit()
    deleteFile(suite)
}
try! records.joined(separator: "\n").write(to: listURL, atomically: true, encoding: .utf8)
