import Foundation
import KeepMacAwakeControlProtocol

/// What the helper checks in an update package before installing it, on its own copy
/// and independently of the coordinator: a trusted Developer ID Installer signature of
/// this product's team, Apple's notarization, the `com.keepmacawake` package (never the
/// uninstaller) and a version newer than the installed app.
public enum UpdatePackageCheck {
    public struct Output: Equatable, Sendable {
        public let status: Int32
        public let text: String
        public init(status: Int32, text: String) { self.status = status; self.text = text }
    }

    public enum Refusal: Error, Equatable, Sendable {
        case notSigned, notNotarized, notThisProduct, notNewer, needsNewerSystem

        public var message: String {
            switch self {
            case .notSigned: return "The update package is not signed by the Keep Mac Awake developer."
            case .notNotarized: return "macOS does not accept the update package as notarized."
            case .notThisProduct: return "The update package is not a Keep Mac Awake installer."
            case .notNewer: return "The update package is not newer than the installed version."
            case .needsNewerSystem: return "This update needs a newer version of macOS."
            }
        }
    }

    /// Runs the checks; `run` executes a fixed system tool, `distribution` returns the
    /// archive's Distribution file. Returns the package's version.
    public static func verify(package: String, installedVersion: String, systemVersion: String,
                              run: (String, [String]) -> Output,
                              distribution: (String) -> Data?) -> Result<String, Refusal> {
        // pkgutil first: it alone rejects an archive whose contents no longer match its signature.
        let signature = run("/usr/sbin/pkgutil", ["--check-signature", package])
        guard signature.status == 0, isSignedByTeam(signature.text, team: ControlConstants.releaseTeamID) else {
            return .failure(.notSigned)
        }
        // -vv: only then does spctl name the signer (origin=), which must be the same team.
        let assessment = run("/usr/sbin/spctl", ["--assess", "--type", "install", "-vv", package])
        guard assessment.status == 0, isNotarized(assessment.text, team: ControlConstants.releaseTeamID) else {
            return .failure(.notNotarized)
        }
        guard let data = distribution(package), let version = packageVersion(data) else { return .failure(.notThisProduct) }
        guard isNewer(version, than: installedVersion) else { return .failure(.notNewer) }
        if let minimum = minimumSystem(data), isNewer(minimum, than: systemVersion) { return .failure(.needsNewerSystem) }
        return .success(version)
    }

    /// Why the helper does not take an update now, or nil. Asked before the copy and again
    /// right before Installer starts, since a session may have started in between.
    public static func requestRefusal(ready: Bool, recovering: Bool, sessionActive: Bool, restorationNeeded: Bool,
                                      journalExists: Bool, installing: Bool, preparing: Bool) -> String? {
        if installing || preparing { return "An update is already being installed." }
        if !ready || recovering || sessionActive || restorationNeeded || journalExists {
            return "A session is running. Installing would end it, so turn Keep Mac Awake off first."
        }
        return nil
    }

    /// The client's file must be a regular file of a sane size: a pipe, a socket or a device could
    /// block the copy.
    public static func acceptsUpload(isRegularFile: Bool, size: Int64) -> Bool {
        isRegularFile && size > 0 && size <= Int64(ControlConstants.maximumUpdateBytes)
    }

    /// The install mode's only argument: `<update directory>/<8 letters or digits>/update.pkg`.
    public static func isPackagePath(_ path: String, base: String = ControlConstants.updateDirectory) -> Bool {
        guard path.hasPrefix(base + "/") else { return false }
        let rest = path.dropFirst(base.count + 1).split(separator: "/", omittingEmptySubsequences: false)
        guard rest.count == 2, rest[1] == "update.pkg", rest[0].count == 8 else { return false }
        return rest[0].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// `pkgutil --check-signature` must trust the signature, and its first certificate
    /// must be the team's Developer ID Installer.
    public static func isSignedByTeam(_ output: String, team: String) -> Bool {
        guard output.contains("Status: signed by a developer certificate issued by Apple for distribution") else { return false }
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("1. ") else { continue }
            let signer = text.dropFirst(3)
            return signer.hasPrefix("Developer ID Installer: ") && signer.hasSuffix("(\(team))")
        }
        return false
    }

    /// `spctl -v` names the source and the signer; with Gatekeeper turned off it accepts anything
    /// without them.
    public static func isNotarized(_ output: String, team: String) -> Bool {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.contains("source=Notarized Developer ID") &&
            lines.contains { $0.hasPrefix("origin=Developer ID Installer: ") && $0.hasSuffix("(\(team))") }
    }

    /// The lowest macOS the archive's Distribution allows, if it names one.
    public static func minimumSystem(_ distribution: Data) -> String? {
        guard distribution.count <= 65_536 else { return nil }
        let text = String(decoding: distribution, as: UTF8.self)
        guard let match = text.firstMatch(of: #/<os-version\s+min="([0-9]{1,4}(?:\.[0-9]{1,4}){0,3})"/#) else { return nil }
        return String(match.1)
    }

    /// The version of the `com.keepmacawake` package a product archive's Distribution
    /// installs; the uninstaller's `com.keepmacawake.Uninstall` does not match.
    public static func packageVersion(_ distribution: Data) -> String? {
        guard distribution.count <= 65_536 else { return nil }
        let text = String(decoding: distribution, as: UTF8.self)
        guard let match = text.firstMatch(of: #/<pkg-ref\s+id="com\.keepmacawake"\s+version="([0-9]{1,4}(?:\.[0-9]{1,4}){0,3})"/#) else { return nil }
        return String(match.1)
    }

    /// Dotted numeric versions, compared part by part; a missing part counts as 0.
    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard let new = numbers(candidate), let old = numbers(installed) else { return false }
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0, b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func numbers(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var result: [Int] = []
        for part in parts {
            guard (1...4).contains(part.count), part.allSatisfy(\.isASCII), let number = Int(part) else { return nil }
            result.append(number)
        }
        return result
    }
}
