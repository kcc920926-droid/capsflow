import Foundation
import UpdateCore

// Publisher diagnostics only: verify/download/unpack, NEVER run the installer,
// request input permissions, create key material, or start the menu/input engine.
func runUpdateVerification(arguments: [String]) -> Int32 {
    do {
        guard let encoded = Bundle.main.object(forInfoDictionaryKey: "CapsFlowUpdatePublicKey") as? String,
              let publicKey = Data(base64Encoded: encoded), publicKey.count == 32 else {
            throw UpdateFailure.rejected("서명 공개키가 포함된 dist 앱에서 실행하세요.")
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        func verified(_ data: Data) throws -> VerifiedUpdate {
            guard let update = try UpdatePolicy.verify(data, publicKey: publicKey, currentVersion: "0.0.0", currentBuild: 0,
                architecture: UpdatePolicy.architecture, operatingSystem: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)") else {
                throw UpdateFailure.rejected("검증할 배포 정보가 없습니다.")
            }
            return update
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CapsFlow-UpdateVerification-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        if let i = arguments.firstIndex(of: "--verify-update-bundle"), arguments.count == i+3 {
            let update = try verified(Data(contentsOf: URL(fileURLWithPath: arguments[i+1])))
            let original = URL(fileURLWithPath: arguments[i+2])
            let size = try FileManager.default.attributesOfItem(atPath: original.path)[.size] as? NSNumber
            guard size?.intValue == update.payload.byteCount else { throw UpdateFailure.rejected("검증할 ZIP 크기가 다릅니다.") }
            try UpdatePolicy.verifyArchive(Data(contentsOf: original, options: .mappedIfSafe), update: update)
            let copy = root.appendingPathComponent(update.payload.assetName)
            try FileManager.default.copyItem(at: original, to: copy)
            let script = try UpdateArchivePreparation.prepare(copy, update: update)
            print("Verified signed v\(update.payload.version) / SHA-256 / archive paths / app versions / code signatures / \(script.lastPathComponent). Installer NOT run.")
            return 0
        }
        guard arguments.contains("--verify-remote-update") else { throw UpdateFailure.rejected("Usage: --verify-update-bundle manifest.json archive.zip | --verify-remote-update") }
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error>?
        let request = UpdateDataRequest()
        request.start(UpdatePolicy.feedURL) { result = $0; semaphore.signal() }
        guard semaphore.wait(timeout: .now()+45) == .success, let manifest = result else { request.cancel(); throw URLError(.timedOut) }
        let update = try verified(manifest.get())
        let download = UpdateArchiveRequest(update: update, directory: root)
        let completed = DispatchSemaphore(value: 0)
        var archive: Result<URL, Error>?
        download.start { archive = $0; completed.signal() }
        guard completed.wait(timeout: .now()+100) == .success, let downloaded = archive else { download.cancel(); throw URLError(.timedOut) }
        let script = try UpdateArchivePreparation.prepare(downloaded.get(), update: update)
        print("Verified public GitHub feed → signed v\(update.payload.version) → downloaded ZIP hash → archive/app checks → \(script.lastPathComponent). Installer NOT run.")
        return 0
    } catch { fputs("Update verification failed: \(error.localizedDescription)\n", stderr); return 1 }
}
