import Foundation
import CryptoKit

public enum UpdateFailure: Error, LocalizedError {
    case rejected(String)
    public var errorDescription: String? { if case let .rejected(text) = self { return text }; return nil }
}
public struct UpdateVersion: Comparable, Equatable {
    public let numbers: [Int]
    public let text: String
    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, text.count <= 24 else { return nil }
        var values: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part.count == 1 || part.first != "0", let value = Int(part), value <= 1_000_000 else { return nil }
            values.append(value)
        }
        self.numbers = values; self.text = text
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
}
public struct UpdatePayload: Codable, Equatable {
    public let version: String
    public let build: Int
    public let architecture: String
    public let minimumOS: String
    public let assetName: String
    public let downloadURL: String
    public let releaseURL: String
    public let sha256: String
    public let byteCount: Int
    public init(version: String, build: Int, architecture: String, minimumOS: String,
                assetName: String, downloadURL: String, releaseURL: String, sha256: String, byteCount: Int) {
        self.version = version; self.build = build; self.architecture = architecture; self.minimumOS = minimumOS
        self.assetName = assetName; self.downloadURL = downloadURL; self.releaseURL = releaseURL
        self.sha256 = sha256; self.byteCount = byteCount
    }
}
public struct SignedUpdateEnvelope: Codable {
    public let format: Int
    public let payload: String
    public let signature: String
    public init(format: Int = 1, payload: String, signature: String) {
        self.format = format; self.payload = payload; self.signature = signature
    }
}
public struct VerifiedUpdate {
    public let payload: UpdatePayload
    fileprivate init(_ payload: UpdatePayload) { self.payload = payload }
}
public enum UpdatePolicy {
    public static let repository = "kcc920926-droid/capsflow"
    public static let maximumManifestBytes = 32_768
    public static let maximumArchiveBytes = 64 * 1024 * 1024
    public static let maximumExpandedBytes = 256 * 1024 * 1024
    public static let interval: TimeInterval = 6 * 60 * 60
    public static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unsupported"
        #endif
    }
    public static var feedURL: URL {
        URL(string: "https://raw.githubusercontent.com/\(repository)/main/updates/latest-\(architecture).json")!
    }
    public static let releasesURL = URL(string: "https://github.com/\(repository)/releases")!
    public static func verify(_ bytes: Data, publicKey: Data, currentVersion: String, currentBuild: Int,
                              architecture: String, operatingSystem: String) throws -> VerifiedUpdate? {
        guard !bytes.isEmpty, bytes.count <= maximumManifestBytes else { throw UpdateFailure.rejected("업데이트 정보 크기가 올바르지 않습니다.") }
        guard let envelope = try? JSONDecoder().decode(SignedUpdateEnvelope.self, from: bytes), envelope.format == 1,
              let message = Data(base64Encoded: envelope.payload), message.count <= 24_576,
              let signature = Data(base64Encoded: envelope.signature), signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signature, for: message) else { throw UpdateFailure.rejected("업데이트 정보의 발행자 서명을 확인하지 못했습니다.") }
        guard let payload = try? JSONDecoder().decode(UpdatePayload.self, from: message),
              let version = UpdateVersion(payload.version), let current = UpdateVersion(currentVersion),
              let minOS = UpdateVersion(payload.minimumOS), let os = UpdateVersion(operatingSystem),
              (1...1_000_000_000).contains(payload.build), payload.architecture == architecture,
              ["arm64", "x86_64"].contains(architecture), minOS <= os,
              (1...maximumArchiveBytes).contains(payload.byteCount),
              payload.sha256.count == 64, payload.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw UpdateFailure.rejected("이 Mac에서 사용할 수 없는 업데이트 정보입니다.")
        }
        let name = "CapsFlow-Installer-\(version.text)-\(architecture).zip"
        guard payload.assetName == name,
              payload.downloadURL == "https://github.com/\(repository)/releases/download/v\(version.text)/\(name)",
              payload.releaseURL == "https://github.com/\(repository)/releases/tag/v\(version.text)" else {
            throw UpdateFailure.rejected("허용된 CapsFlow 배포 위치가 아닙니다.")
        }
        // Never downgrade or install an older build even if an old signed feed is replayed.
        guard version >= current, payload.build > currentBuild else { return nil }
        return VerifiedUpdate(payload)
    }
    public static func verifyArchive(_ bytes: Data, update: VerifiedUpdate) throws {
        guard bytes.count == update.payload.byteCount, bytes.count <= maximumArchiveBytes,
              sha256(bytes) == update.payload.sha256 else { throw UpdateFailure.rejected("업데이트 ZIP의 크기 또는 SHA-256이 다릅니다.") }
    }
    public static func sha256(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    public static func retryInterval(failures: Int) -> TimeInterval {
        min(24 * 60 * 60, 30 * 60 * pow(2, Double(max(0, min(7, max(0, failures)) - 1))))
    }
    public static func allowedResponseURL(_ url: URL?, archive: Bool) -> Bool {
        guard let url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == "https", c.user == nil, c.password == nil, c.port == nil || c.port == 443,
              let host = c.host?.lowercased() else { return false }
        return archive ? ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(host)
                       : host == "raw.githubusercontent.com"
    }
    public static func validateEntries(_ names: [String], hasSymlinks: Bool) throws {
        guard !names.isEmpty, names.count <= 10_000, !hasSymlinks else { throw UpdateFailure.rejected("설치 ZIP에 허용되지 않은 항목이 있습니다.") }
        var seen = Set<String>()
        for name in names {
            guard name.utf8.count <= 1024, !name.hasPrefix("/"), !name.contains("\\"),
                  !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                  name == "CapsFlow-Installer/" || name.hasPrefix("CapsFlow-Installer/") || name == "__MACOSX/" || name.hasPrefix("__MACOSX/") else {
                throw UpdateFailure.rejected("설치 ZIP 경로가 올바르지 않습니다.")
            }
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.contains(".."), !parts.contains("."), !name.contains("//"), seen.insert(name).inserted else {
                throw UpdateFailure.rejected("설치 ZIP에 중복되거나 안전하지 않은 경로가 있습니다.")
            }
        }
        guard seen.contains("CapsFlow-Installer/Install.command"), seen.contains("CapsFlow-Installer/scripts/setup.sh"),
              seen.contains("CapsFlow-Installer/bin/CapsFlowSetupHelper") else { throw UpdateFailure.rejected("설치기에 필요한 파일이 없습니다.") }
    }
    public static func validateExpansionSummary(_ text: String) throws {
        let pattern = #"^([0-9]+) files?, ([0-9]+) bytes uncompressed,"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let a = Range(m.range(at: 1), in: text), let b = Range(m.range(at: 2), in: text),
              let count = Int(text[a]), (1...10_000).contains(count),
              let size = Int(text[b]), (1...maximumExpandedBytes).contains(size) else {
            throw UpdateFailure.rejected("설치 ZIP의 압축 해제 크기가 안전 한도를 넘거나 확인되지 않습니다.")
        }
    }
}
