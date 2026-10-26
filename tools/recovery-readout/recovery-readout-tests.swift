import Foundation
import CoreFoundation
import Darwin

@main
enum RecoveryReadoutTests {
    static func main() throws {
        var failures = 0
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            checks += 1
            if !condition() { failures += 1; print("FAIL: \(label)") }
        }
        check(RecoveryReadout.preferences(nil) == "containerAbsent", "absent container")
        check(RecoveryReadout.preferences([String: Any]()) == "keyAbsent", "absent key")
        check(RecoveryReadout.preferences(["SleepDisabled": false]) == "false", "false preference")
        check(RecoveryReadout.preferences(["SleepDisabled": true]) == "true", "true preference")
        for value: Any in [1, 0, "true", NSNull(), [true]] {
            check(RecoveryReadout.preferences(["SleepDisabled": value]) == "invalid", "strict preference boolean")
            check(RecoveryReadout.kernel(value) == "invalid", "strict kernel boolean")
        }
        check(RecoveryReadout.preferences("foreign value") == "invalid", "invalid container")
        check(RecoveryReadout.kernel(nil) == "missing", "missing kernel")
        check(RecoveryReadout.kernel(false) == "false", "false kernel")
        check(RecoveryReadout.kernel(true) == "true", "true kernel")
        let valid = Data(#"{"schemaVersion":1,"original":"keyAbsent","phase":"changing"}"#.utf8)
        let parsed = RecoveryReadout.parseJournal(valid)
        check(parsed.state == "present" && parsed.original == "keyAbsent" && parsed.phase == "changing", "valid journal")
        for original in ["containerAbsent", "keyAbsent", "falseValue"] {
            for phase in ["prepared", "changing", "kernelRestored"] {
                let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "original": original, "phase": phase])
                check(RecoveryReadout.parseJournal(data).state == "present", "all supported journal states")
            }
        }
        for text in [#"{"schemaVersion":true,"original":"keyAbsent","phase":"changing"}"#,
                     #"{"schemaVersion":2,"original":"keyAbsent","phase":"changing"}"#,
                     #"{"schemaVersion":1,"original":"trueValue","phase":"changing"}"#,
                     #"{"schemaVersion":1,"original":"keyAbsent","phase":"unknown"}"#,
                     #"{"schemaVersion":1,"original":"keyAbsent","phase":"changing","secret":"never print"}"#,
                     "{}", "null", "[]", "not json"] {
            let reading = RecoveryReadout.parseJournal(Data(text.utf8))
            check(reading.state == "invalid", "reject malformed or unexpected journal")
            let encoded = try JSONEncoder().encode(reading)
            check(!String(decoding: encoded, as: UTF8.self).contains("never print"), "no raw journal echo")
        }
        check(RecoveryReadout.parseJournal(Data(repeating: 32, count: 16_385)).state == "invalid", "journal size bound")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("f0-readout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { fatalError("fixture directory") }
        defer { close(fd) }
        let file = directory.appendingPathComponent("sleep-recovery.json")
        check(RecoveryReadout.journal(in: fd, owner: getuid()).state == "absent", "missing journal file")
        try valid.write(to: file)
        chmod(file.path, 0o600)
        check(RecoveryReadout.journal(in: fd, owner: getuid()).state == "present", "private regular journal")
        check(RecoveryReadout.journal(in: fd, owner: getuid() + 1).state == "invalid", "wrong journal owner")
        chmod(file.path, 0o644)
        check(RecoveryReadout.journal(in: fd, owner: getuid()).state == "invalid", "unsafe journal mode")
        chmod(file.path, 0o600)
        let alias = directory.appendingPathComponent("alias")
        guard link(file.path, alias.path) == 0 else { fatalError("hardlink fixture") }
        check(RecoveryReadout.journal(in: fd, owner: getuid()).state == "invalid", "multiply linked journal")
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: directory.appendingPathComponent("missing"))
        check(RecoveryReadout.journal(in: fd, owner: getuid()).state == "error", "dangling symlink is not absent")
        try FileManager.default.removeItem(at: file)
        guard mkfifo(file.path, 0o600) == 0 else { fatalError("fifo fixture") }
        check(RecoveryReadout.journal(in: fd, owner: getuid()).state == "invalid", "FIFO rejected without blocking")
        print("\(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
