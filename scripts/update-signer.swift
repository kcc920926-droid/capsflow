import Foundation
import CryptoKit
import Security

// Publisher-only tool. Private key remains in the login Keychain, never in the repo.
let service = "local.capsflow.release-signing.ed25519"
let account = "primary-v1"
func fail(_ text: String) -> Never { fputs(text + "\n", stderr); exit(1) }
func loadKey(create: Bool) -> Curve25519.Signing.PrivateKey {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service, kSecAttrAccount as String: account,
        kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
    var item: CFTypeRef?
    let result = SecItemCopyMatching(query as CFDictionary, &item)
    if result == errSecSuccess, let data = item as? Data {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else { fail("키체인의 서명 키 형식이 올바르지 않습니다. 기존 키는 바꾸지 않았습니다.") }
        return key
    }
    guard result == errSecItemNotFound && create else { fail("키체인에서 서명 키를 읽을 수 없습니다 (상태 \(result)). 키체인을 확인하세요.") }
    let key = Curve25519.Signing.PrivateKey()
    let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service, kSecAttrAccount as String: account,
        kSecAttrLabel as String: "CapsFlow 업데이트 서명 키 · 개인키 업로드 금지",
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        kSecValueData as String: key.rawRepresentation]
    let added = SecItemAdd(add as CFDictionary, nil)
    guard added == errSecSuccess else { fail("키체인에 서명 키를 보관하지 못했습니다 (상태 \(added)).") }
    return key
}
let args = CommandLine.arguments
if args.count == 2 && args[1] == "--init-key" {
    // Prints only PUBLIC information. Re-running reuses the original key.
    print(loadKey(create: true).publicKey.rawRepresentation.base64EncodedString())
} else if args.count == 2 && args[1] == "--public-key" {
    print(loadKey(create: false).publicKey.rawRepresentation.base64EncodedString())
} else if args.count == 4 && args[1] == "--sign" {
    let input = URL(fileURLWithPath: args[2]), output = URL(fileURLWithPath: args[3])
    guard let data = try? Data(contentsOf: input), data.count <= 24_576,
          (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { fail("서명할 JSON 페이로드가 올바르지 않습니다.") }
    let key = loadKey(create: false)
    guard let signature = try? key.signature(for: data) else { fail("서명에 실패했습니다.") }
    let envelope: [String: Any] = ["format": 1, "payload": data.base64EncodedString(),
        "signature": signature.base64EncodedString()]
    do {
        let encoded = try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try encoded.write(to: output, options: .atomic)
        print("Signed manifest: \(output.lastPathComponent)")
    } catch { fail("서명 매니페스트를 저장하지 못했습니다: \(error.localizedDescription)") }
} else { fail("Usage: UpdateSigner --init-key | --public-key | --sign payload.json manifest.json") }
