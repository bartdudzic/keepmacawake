import Foundation
import Darwin
import KeepMacAwakeControlProtocol

// There is no default mode, shell command, or activation CLI. The only argument besides a
// mode is the update package path, which install mode accepts only inside its own directory.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--install-update", geteuid() == 0 {
    exit(UpdateInstall.installMode(CommandLine.arguments[2]))
}
guard CommandLine.arguments.count == 2, geteuid() == 0 else {
    fputs("KeepMacAwakeHelper: requires root and exactly one fixed service mode.\n", stderr)
    exit(64)
}
do {
    switch CommandLine.arguments[1] {
    case "--recover":
        // First installation has no installed executable or trust manifest yet.
        try PeerFencer.requireUnloaded(.controller)
        try PeerFencer.requireUnloaded(.watchdog)
        let directory = try SecureDirectory(ControlConstants.stateDirectory, privateMode: true)
        try LockedBackend(directory: directory).restore()
    case "--validate-installation":
        try validateInstallation()
    case "--controller":
        try ServiceRuntime(mode: .controller).run()
    case "--watchdog":
        try ServiceRuntime(mode: .watchdog).run()
    default:
        throw ServiceError.failed("Unsupported service mode.")
    }
} catch {
    fputs("KeepMacAwakeHelper: \(error.localizedDescription)\n", stderr)
    exit(1)
}
