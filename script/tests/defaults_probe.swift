// Temporary CI probe: shows what cfprefsd leaves in ~/Library/Preferences for a
// UserDefaults suite under each cleanup strategy, both while the writing process is
// still alive and after it has exited.
//
//   swift defaults_probe.swift write <list-file>   run the strategies, record suites
//   swift defaults_probe.swift check <list-file>   report the files after exit
import Foundation

let preferences = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Preferences", isDirectory: true)

func fileURL(_ suite: String) -> URL {
    preferences.appendingPathComponent("\(suite).plist")
}

func fileState(_ suite: String) -> String {
    guard let data = try? Data(contentsOf: fileURL(suite)) else { return "no file" }
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

func removeDomain(_ suite: String, _ defaults: UserDefaults) {
    defaults.synchronize()
    defaults.removePersistentDomain(forName: suite)
    defaults.synchronize()
}

func removeKeys(_ suite: String, _ defaults: UserDefaults) {
    let keys: [String] = defaults.persistentDomain(forName: suite).map { Array($0.keys) } ?? []
    for key in keys {
        defaults.removeObject(forKey: key)
    }
    defaults.synchronize()
}

func deleteFile(_ suite: String) {
    try? FileManager.default.removeItem(at: fileURL(suite))
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

var records: [String] = []
var liveDefaults: [UserDefaults] = []

func run(_ label: String, _ body: (String, UserDefaults) -> Void) {
    let suite = "CopyClipLiteProbe-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    liveDefaults.append(defaults)
    body(suite, defaults)
    Thread.sleep(forTimeInterval: 2)
    print("\(label) | alive after 2 s: \(fileState(suite))")
    records.append("\(label)\t\(suite)")
}

run("P1 write, sync, removePersistentDomain, sync, delete file") { suite, defaults in
    writeKeys(defaults)
    removeDomain(suite, defaults)
    deleteFile(suite)
}
run("P2 write, removeObject per key, sync, delete file") { suite, defaults in
    writeKeys(defaults)
    removeKeys(suite, defaults)
    deleteFile(suite)
}
run("P3 write, sync, delete file (no removal)") { suite, defaults in
    writeKeys(defaults)
    defaults.synchronize()
    deleteFile(suite)
}
run("P4 write, removePersistentDomain only (old tests)") { suite, defaults in
    writeKeys(defaults)
    defaults.removePersistentDomain(forName: suite)
}
run("P5 write, removeObject per key, sync (no delete)") { suite, defaults in
    writeKeys(defaults)
    removeKeys(suite, defaults)
}
run("P6 write only") { _, defaults in
    writeKeys(defaults)
}
try! records.joined(separator: "\n").write(to: listURL, atomically: true, encoding: .utf8)
