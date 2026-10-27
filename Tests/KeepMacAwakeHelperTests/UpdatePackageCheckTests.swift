import XCTest
@testable import KeepMacAwakeServiceSupport

final class UpdatePackageCheckTests: XCTestCase {
    static let signed = """
    Package "update.pkg":
       Status: signed by a developer certificate issued by Apple for distribution
       Certificate Chain:
        1. Developer ID Installer: Example Developer (3X35AKH8DH)
        2. Developer ID Certification Authority
        3. Apple Root CA
    """
    static let notarized = "update.pkg: accepted\nsource=Notarized Developer ID\norigin=Developer ID Installer: Example Developer (3X35AKH8DH)\n"

    static func distribution(id: String, version: String, minimum: String = "26.0") -> Data {
        Data("""
        <installer-gui-script minSpecVersion="2">
            <allowed-os-versions><os-version min="\(minimum)"/></allowed-os-versions>
            <pkg-ref id="\(id)" version="\(version)" onConclusion="none">#install-component.pkg</pkg-ref>
        </installer-gui-script>
        """.utf8)
    }

    private func verify(signature: UpdatePackageCheck.Output = .init(status: 0, text: signed),
                        assessment: UpdatePackageCheck.Output = .init(status: 0, text: notarized),
                        distribution: Data? = distribution(id: "com.keepmacawake", version: "1.0.4"),
                        installed: String = "1.0.3", system: String = "26.1.0") -> (Result<String, UpdatePackageCheck.Refusal>, [String]) {
        var tools: [String] = []
        let result = UpdatePackageCheck.verify(package: "/x/update.pkg", installedVersion: installed, systemVersion: system, run: { tool, arguments in
            tools.append(tool)
            // spctl names the signer only with -vv; with -v the origin line is missing, as on macOS 27.
            if tool == "/usr/sbin/spctl", !arguments.contains("-vv") { return .init(status: 0, text: "update.pkg: accepted\nsource=Notarized Developer ID\n") }
            return tool == "/usr/sbin/pkgutil" ? signature : assessment
        }, distribution: { _ in
            tools.append("distribution")
            return distribution
        })
        return (result, tools)
    }

    func testAGenuineNewerPackagePasses() {
        let (result, tools) = verify()
        XCTAssertEqual(result, .success("1.0.4"))
        XCTAssertEqual(tools, ["/usr/sbin/pkgutil", "/usr/sbin/spctl", "distribution"])
    }

    func testAnotherTeamAnUntrustedOrAFailedSignatureIsRefused() {
        let other = Self.signed.replacingOccurrences(of: "(3X35AKH8DH)", with: "(ABCDE12345)")
        let untrusted = Self.signed.replacingOccurrences(of: "Status: signed by a developer certificate issued by Apple for distribution",
                                                         with: "Status: signed by untrusted certificate")
        let application = Self.signed.replacingOccurrences(of: "Developer ID Installer", with: "Developer ID Application")
        for output in [other, untrusted, application] {
            XCTAssertEqual(verify(signature: .init(status: 0, text: output)).0, .failure(.notSigned))
        }
        let (failed, tools) = verify(signature: .init(status: 1, text: Self.signed))
        XCTAssertEqual(failed, .failure(.notSigned))
        XCTAssertEqual(tools, ["/usr/sbin/pkgutil"], "Nothing is read from an archive whose signature fails")
    }

    func testAPackageWithoutNotarizationIsRefused() {
        XCTAssertEqual(verify(assessment: .init(status: 0, text: "update.pkg: accepted\nsource=Developer ID\n")).0, .failure(.notNotarized))
        XCTAssertEqual(verify(assessment: .init(status: 3, text: Self.notarized)).0, .failure(.notNotarized))
        let otherOrigin = Self.notarized.replacingOccurrences(of: "(3X35AKH8DH)", with: "(ABCDE12345)")
        let (failed, tools) = verify(assessment: .init(status: 0, text: otherOrigin))
        XCTAssertEqual(failed, .failure(.notNotarized), "spctl must name the same team")
        XCTAssertFalse(tools.contains("distribution"))
    }

    func testAnUpdateForANewerMacOSIsRefused() {
        XCTAssertEqual(verify(distribution: Self.distribution(id: "com.keepmacawake", version: "1.0.4", minimum: "27.1")).0,
                       .failure(.needsNewerSystem))
        XCTAssertEqual(verify(distribution: Self.distribution(id: "com.keepmacawake", version: "1.0.4", minimum: "26.1")).0,
                       .success("1.0.4"))
    }

    func testTheHelperRefusesAnUpdateDuringASessionOrAnotherUpdate() {
        func refusal(ready: Bool = true, recovering: Bool = false, session: Bool = false, restoration: Bool = false,
                     journal: Bool = false, installing: Bool = false, preparing: Bool = false) -> String? {
            UpdatePackageCheck.requestRefusal(ready: ready, recovering: recovering, sessionActive: session,
                                              restorationNeeded: restoration, journalExists: journal,
                                              installing: installing, preparing: preparing)
        }
        XCTAssertNil(refusal())
        for blocked in [refusal(ready: false), refusal(recovering: true), refusal(session: true), refusal(restoration: true), refusal(journal: true)] {
            XCTAssertEqual(blocked, "A session is running. Installing would end it, so turn Keep Mac Awake off first.")
        }
        XCTAssertEqual(refusal(installing: true), "An update is already being installed.")
        XCTAssertEqual(refusal(preparing: true), "An update is already being installed.")
    }

    func testOnlyARegularFileOfASaneSizeIsCopied() {
        XCTAssertTrue(UpdatePackageCheck.acceptsUpload(isRegularFile: true, size: 2_800_000))
        XCTAssertFalse(UpdatePackageCheck.acceptsUpload(isRegularFile: false, size: 2_800_000), "A pipe or a socket could block the copy")
        XCTAssertFalse(UpdatePackageCheck.acceptsUpload(isRegularFile: true, size: 0))
        XCTAssertFalse(UpdatePackageCheck.acceptsUpload(isRegularFile: true, size: 64 * 1024 * 1024 + 1))
    }

    func testTheInstallModeTakesOnlyAPackageInItsOwnDirectory() {
        let base = "/Library/Application Support/KeepMacAwake/update"
        XCTAssertTrue(UpdatePackageCheck.isPackagePath(base + "/Ab3dE6gH/update.pkg"))
        for path in [base + "/../update.pkg", base + "/Ab3dE6gH/../../update.pkg", base + "/./Ab3dE6gH/update.pkg",
                     base + "/..../update.pkg", base + "/Ab3dE6g/update.pkg", base + "/Ab3dE6gH/other.pkg",
                     base + "/Ab3dE6gH/update.pkg/x", "/tmp/Ab3dE6gH/update.pkg", base + "Ab3dE6gH/update.pkg"] {
            XCTAssertFalse(UpdatePackageCheck.isPackagePath(path), path)
        }
    }

    func testTheUninstallerOrAnotherProductIsRefused() {
        for id in ["com.keepmacawake.Uninstall", "com.example", "com.keepmacawakeX"] {
            XCTAssertEqual(verify(distribution: Self.distribution(id: id, version: "1.0.4")).0, .failure(.notThisProduct), id)
        }
        XCTAssertEqual(verify(distribution: nil).0, .failure(.notThisProduct))
        XCTAssertEqual(verify(distribution: Self.distribution(id: "com.keepmacawake", version: "1.0.4-beta")).0, .failure(.notThisProduct))
    }

    func testTheSameOrAnOlderVersionIsRefused() {
        XCTAssertEqual(verify(installed: "1.0.4").0, .failure(.notNewer))
        XCTAssertEqual(verify(installed: "1.1").0, .failure(.notNewer))
        XCTAssertEqual(verify(installed: "not a version").0, .failure(.notNewer))
    }

    func testVersionsCompareByNumber() {
        XCTAssertTrue(UpdatePackageCheck.isNewer("1.0.10", than: "1.0.9"))
        XCTAssertTrue(UpdatePackageCheck.isNewer("1.1", than: "1.0.9"))
        XCTAssertTrue(UpdatePackageCheck.isNewer("2.0.0", than: "1.99.99"))
        XCTAssertFalse(UpdatePackageCheck.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(UpdatePackageCheck.isNewer("1.0.0.0.1", than: "1.0.0"))
        XCTAssertFalse(UpdatePackageCheck.isNewer("1.-1", than: "1.0"))
        XCTAssertFalse(UpdatePackageCheck.isNewer("", than: "1.0"))
    }
}
