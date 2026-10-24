import Foundation
import CryptoKit
import UpdateCore

var checks = 0
func expect(_ value: @autoclosure () throws -> Bool, _ message: String) {
    checks += 1
    do { if try !value() { fputs("FAIL: \(message)\n", stderr); exit(1) } }
    catch { fputs("FAIL: \(message): \(error)\n", stderr); exit(1) }
}
func rejects(_ body: () throws -> Void) { checks += 1; do { try body(); fputs("FAIL: accepted unsafe update\n", stderr); exit(1) } catch {} }
// Test-only key; the production publisher key is neither read nor exported.
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
let wrong = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 9, count: 32))
let blob = Data("synthetic installer archive fixture".utf8)
func payload(version: String = "0.3.4", build: Int = 22, arch: String = "arm64", os: String = "13.0.0",
             url: String? = nil, release: String? = nil, name: String? = nil, digest: String? = nil, count: Int? = nil) -> UpdatePayload {
    let filename = name ?? "CapsFlow-Installer-\(version)-\(arch).zip"
    return UpdatePayload(version: version, build: build, architecture: arch, minimumOS: os, assetName: filename,
        downloadURL: url ?? "https://github.com/kcc920926-droid/capsflow/releases/download/v\(version)/\(filename)",
        releaseURL: release ?? "https://github.com/kcc920926-droid/capsflow/releases/tag/v\(version)",
        sha256: digest ?? UpdatePolicy.sha256(blob), byteCount: count ?? blob.count)
}
func signed(_ p: UpdatePayload, signingKey: Curve25519.Signing.PrivateKey = key) throws -> Data {
    let data = try JSONEncoder().encode(p)
    return try JSONEncoder().encode(SignedUpdateEnvelope(payload: data.base64EncodedString(), signature: signingKey.signature(for: data).base64EncodedString()))
}
func verify(_ p: UpdatePayload) throws -> VerifiedUpdate? {
    try UpdatePolicy.verify(signed(p), publicKey: key.publicKey.rawRepresentation, currentVersion: "0.3.3", currentBuild: 21, architecture: "arm64", operatingSystem: "27.0.1")
}
let good = try verify(payload())!
expect(good.payload.version == "0.3.4", "signed new release")
try UpdatePolicy.verifyArchive(blob, update: good); checks += 1
expect(try verify(payload(version: "0.3.2", build: 999)) == nil, "no downgrade")
expect(try verify(payload(version: "0.3.3", build: 21)) == nil, "same build")
expect(try verify(payload(version: "0.3.3", build: 22)) != nil, "monotonic rebuild")
expect(try verify(payload(build: 20)) == nil, "build rollback")
expect(UpdateVersion("0.3.9")! < UpdateVersion("0.3.10")!, "numeric version ordering")
for invalid in ["", "0.3", "v0.3.4", "0.3.4-beta", "00.3.4", "1..3", "1.2.-3", "1.2.3/evil", "1.2.999999999999999999999", "1.2.3.4", "１.2.3"] {
    expect(UpdateVersion(invalid) == nil, "reject version \(invalid)")
}
for p in [payload(arch: "x86_64"), payload(arch: "../arm64"), payload(os: "99.0.0"), payload(build: 0),
          payload(count: 0), payload(count: UpdatePolicy.maximumArchiveBytes+1), payload(digest: "abc"),
          payload(digest: String(repeating: "G", count: 64)), payload(name: "../Install.command"),
          payload(url: "http://github.com/kcc920926-droid/capsflow/releases/download/v0.3.4/a.zip"),
          payload(url: "https://evil.example/a.zip"), payload(url: "https://github.com/other/capsflow/releases/download/v0.3.4/a.zip"),
          payload(url: "https://github.com/kcc920926-droid/capsflow/releases/download/v0.3.4/a.zip?token=x"),
          payload(release: "https://evil.example/")] { rejects { _ = try verify(p) } }
rejects { _ = try UpdatePolicy.verify(signed(payload(), signingKey: wrong), publicKey: key.publicKey.rawRepresentation, currentVersion: "0.3.3", currentBuild: 21, architecture: "arm64", operatingSystem: "27.0.1") }
rejects { _ = try UpdatePolicy.verify(Data(repeating: 0, count: 32769), publicKey: key.publicKey.rawRepresentation, currentVersion: "0.3.3", currentBuild: 21, architecture: "arm64", operatingSystem: "27.0.1") }
rejects { _ = try UpdatePolicy.verify(Data("{}".utf8), publicKey: Data(), currentVersion: "0.3.3", currentBuild: 21, architecture: "arm64", operatingSystem: "27.0.1") }
var envelope = try JSONDecoder().decode(SignedUpdateEnvelope.self, from: signed(payload()))
envelope = SignedUpdateEnvelope(payload: try JSONEncoder().encode(payload(build: 999)).base64EncodedString(), signature: envelope.signature)
rejects { _ = try UpdatePolicy.verify(JSONEncoder().encode(envelope), publicKey: key.publicKey.rawRepresentation, currentVersion: "0.3.3", currentBuild: 21, architecture: "arm64", operatingSystem: "27.0.1") }
rejects { try UpdatePolicy.verifyArchive(blob + Data([1]), update: good) }
rejects { try UpdatePolicy.verifyArchive(Data(repeating: 1, count: blob.count), update: good) }
let entries = ["CapsFlow-Installer/", "CapsFlow-Installer/Install.command", "CapsFlow-Installer/scripts/setup.sh", "CapsFlow-Installer/bin/CapsFlowSetupHelper", "__MACOSX/", "__MACOSX/._x"]
try UpdatePolicy.validateEntries(entries, hasSymlinks: false); checks += 1
for bad in ["/tmp/x", "CapsFlow-Installer/../../x", "CapsFlow-Installer/./x", "CapsFlow-Installer//x", "CapsFlow-Installer/evil\\x", "other/file", "CapsFlow-Installer/x\nfile", "CapsFlow-Installer/Install.command"] {
    rejects { try UpdatePolicy.validateEntries(entries + [bad], hasSymlinks: false) }
}
rejects { try UpdatePolicy.validateEntries(entries, hasSymlinks: true) }
rejects { try UpdatePolicy.validateEntries([], hasSymlinks: false) }
for (address, archive, allowed) in [
    ("https://raw.githubusercontent.com/kcc920926-droid/capsflow/main/updates/latest-arm64.json", false, true),
    ("https://release-assets.githubusercontent.com/asset?signature=temporary", true, true),
    ("https://github.com/file", true, true), ("http://github.com/file", true, false),
    ("https://github.com.evil.example/file", true, false), ("https://user:pass@github.com/file", true, false),
    ("https://github.com:444/file", true, false), ("file:///tmp/update", true, false),
    ("https://release-assets.githubusercontent.com/file", false, false)] {
    expect(UpdatePolicy.allowedResponseURL(URL(string: address), archive: archive) == allowed, "redirect policy")
}
expect(UpdatePolicy.retryInterval(failures: 1) == 1800, "30m retry")
expect(UpdatePolicy.retryInterval(failures: 2) == 3600, "1h retry")
expect(UpdatePolicy.retryInterval(failures: 30) == 86400, "1d cap")
expect(UpdatePolicy.retryInterval(failures: -100) == 1800, "invalid failure count")
expect(UpdatePolicy.retryInterval(failures: Int.min) == 1800, "minimum integer failure count")
expect(UpdatePolicy.retryInterval(failures: Int.max) == 86400, "maximum integer failure count")
try UpdatePolicy.validateExpansionSummary("112 files, 4034758 bytes uncompressed, 1599869 bytes compressed: 60.4%\n"); checks += 1
for summary in ["10001 files, 10 bytes uncompressed,", "2 files, 999999999999 bytes uncompressed,", "2 files, 0 bytes uncompressed,", "unknown", "0 files, 10 bytes uncompressed,"] {
    rejects { try UpdatePolicy.validateExpansionSummary(summary) }
}
expect(UpdatePolicy.interval == 21600, "6h success interval")
print("Update policy checks: \(checks) passed (synthetic signatures and archives; no Keychain, network, input or installation changes)")
