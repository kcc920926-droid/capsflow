import Foundation
import CryptoKit

func fail(_ message: String) -> Never { fputs(message + "\n", stderr); exit(1) }
let a = CommandLine.arguments
guard a.count == 6 else { fail("Usage: create-update-payload.swift archive.zip Menu.app architecture publicKey output.json") }
let archive = URL(fileURLWithPath: a[1]), app = URL(fileURLWithPath: a[2]), arch = a[3]
guard ["arm64", "x86_64"].contains(arch),
      let infoData = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
      let info = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
      let version = info["CFBundleShortVersionString"] as? String,
      let buildText = info["CFBundleVersion"] as? String, let build = Int(buildText), build > 0,
      info["CapsFlowUpdatePublicKey"] as? String == a[4],
      version.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil else {
    fail("앱 버전/CPU/공개키를 확인하세요. 키체인의 키와 앱 공개키가 다르면 서명하지 않습니다.")
}
let name = "CapsFlow-Installer-\(version)-\(arch).zip"
guard archive.lastPathComponent == name,
      let size = (try? FileManager.default.attributesOfItem(atPath: archive.path)[.size]) as? NSNumber,
      (1...64*1024*1024).contains(size.intValue),
      let bytes = try? Data(contentsOf: archive, options: .mappedIfSafe) else { fail("예상한 설치 ZIP이 없거나 크기가 올바르지 않습니다.") }
let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
let payload: [String: Any] = ["version": version, "build": build, "architecture": arch, "minimumOS": "13.0.0",
    "assetName": name, "downloadURL": "https://github.com/kcc920926-droid/capsflow/releases/download/v\(version)/\(name)",
    "releaseURL": "https://github.com/kcc920926-droid/capsflow/releases/tag/v\(version)", "sha256": hash, "byteCount": size.intValue]
do {
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try data.write(to: URL(fileURLWithPath: a[5]), options: .atomic)
    print("Payload: v\(version) build \(build) / \(arch) / \(size.intValue) bytes / SHA-256 \(hash)")
} catch { fail("페이로드 저장 실패: \(error.localizedDescription)") }
