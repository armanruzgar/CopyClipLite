// Temporary CI probe: shows what cfprefsd leaves in ~/Library/Preferences for a
// UserDefaults suite under each cleanup strategy.
import Foundation

let preferences = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Preferences", isDirectory: true)

func fileState(_ suite: String) -> String {
    let url = preferences.appendingPathComponent("\(suite).plist")
    guard let data = try? Data(contentsOf: url) else { return "no file" }
    guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
          let dictionary = plist as? [String: Any] else {
        return "unreadable file (\(data.count) bytes)"
    }
    let keys: [String] = dictionary.keys.sorted()
    return keys.isEmpty ? "EMPTY file {}" : "file with keys \(keys)"
}

func settle() {
    Thread.sleep(forTimeInterval: 2)
}

func run(_ label: String, _ body: (String, UserDefaults) -> Void) {
    let suite = "CopyClipLiteProbe-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        print("\(label): could not create suite")
        return
    }
    body(suite, defaults)
    settle()
    print("\(label): \(fileState(suite))")
    try? FileManager.default.removeItem(at: preferences.appendingPathComponent("\(suite).plist"))
}

run("A never written, removePersistentDomain") { suite, defaults in
    defaults.removePersistentDomain(forName: suite)
}
run("B set, no cleanup") { _, defaults in
    defaults.set(true, forKey: "one")
}
run("C set, removePersistentDomain immediately") { suite, defaults in
    defaults.set(true, forKey: "one")
    defaults.removePersistentDomain(forName: suite)
}
run("D set 3 keys, standard.removePersistentDomain immediately") { suite, defaults in
    defaults.set(true, forKey: "one")
    defaults.set(Data([1, 2]), forKey: "two")
    defaults.set(Date(), forKey: "three")
    UserDefaults.standard.removePersistentDomain(forName: suite)
}
run("E set, synchronize, removePersistentDomain, synchronize") { suite, defaults in
    defaults.set(true, forKey: "one")
    defaults.synchronize()
    defaults.removePersistentDomain(forName: suite)
    defaults.synchronize()
}
run("F set, removeObject for every key") { _, defaults in
    defaults.set(true, forKey: "one")
    defaults.removeObject(forKey: "one")
}
run("G set, sync, remove domain, sync, delete file") { suite, defaults in
    defaults.set(true, forKey: "one")
    defaults.synchronize()
    defaults.removePersistentDomain(forName: suite)
    defaults.synchronize()
    try? FileManager.default.removeItem(at: preferences.appendingPathComponent("\(suite).plist"))
}
run("H set, remove domain, delete file at once (no sync)") { suite, defaults in
    defaults.set(true, forKey: "one")
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: preferences.appendingPathComponent("\(suite).plist"))
}
run("I like G, then a second instance reads the suite") { suite, defaults in
    defaults.set(true, forKey: "one")
    defaults.synchronize()
    defaults.removePersistentDomain(forName: suite)
    defaults.synchronize()
    try? FileManager.default.removeItem(at: preferences.appendingPathComponent("\(suite).plist"))
    Thread.sleep(forTimeInterval: 1)
    _ = UserDefaults(suiteName: suite)?.bool(forKey: "one")
}
run("J like G, then the live instance writes again") { suite, defaults in
    defaults.set(true, forKey: "one")
    defaults.synchronize()
    defaults.removePersistentDomain(forName: suite)
    defaults.synchronize()
    try? FileManager.default.removeItem(at: preferences.appendingPathComponent("\(suite).plist"))
    defaults.set(true, forKey: "late")
}
