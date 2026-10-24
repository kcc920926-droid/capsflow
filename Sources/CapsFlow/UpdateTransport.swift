import Foundation
import UpdateCore

private func updateSessionConfiguration(archive: Bool = false) -> URLSessionConfiguration {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 20; c.timeoutIntervalForResource = 90
    c.httpCookieStorage = nil; c.httpShouldSetCookies = false; c.urlCredentialStorage = nil
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    c.httpAdditionalHeaders = ["User-Agent": "CapsFlow-Updater/1", "Accept": archive ? "application/octet-stream" : "application/json"]
    return c
}
final class UpdateDataRequest: NSObject, URLSessionDataDelegate {
    private var session: URLSession!
    private var data = Data()
    private var finished = false
    private var completion: ((Result<Data, Error>) -> Void)?
    func start(_ url: URL, completion: @escaping (Result<Data, Error>) -> Void) {
        self.completion = completion
        session = URLSession(configuration: updateSessionConfiguration(), delegate: self, delegateQueue: nil)
        session.dataTask(with: url).resume()
    }
    func cancel() { session?.invalidateAndCancel() }
    private func finish(_ result: Result<Data, Error>) {
        guard !finished else { return }; finished = true
        let callback = completion; completion = nil; session?.invalidateAndCancel(); callback?(result)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              UpdatePolicy.allowedResponseURL(response.url, archive: false),
              response.expectedContentLength <= UpdatePolicy.maximumManifestBytes else {
            completionHandler(.cancel); finish(.failure(UpdateFailure.rejected("GitHub 업데이트 정보를 받지 못했습니다."))); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard data.count + chunk.count <= UpdatePolicy.maximumManifestBytes else {
            finish(.failure(UpdateFailure.rejected("업데이트 정보가 너무 큽니다."))); return
        }
        data.append(chunk)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) } else { finish(.success(data)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard UpdatePolicy.allowedResponseURL(request.url, archive: false) else {
            completionHandler(nil); finish(.failure(UpdateFailure.rejected("업데이트 정보가 허용되지 않은 서버로 이동했습니다."))); return
        }
        completionHandler(request)
    }
}
final class UpdateArchiveRequest: NSObject, URLSessionDownloadDelegate {
    private var session: URLSession!
    private var finished = false
    private let update: VerifiedUpdate
    private let directory: URL
    private var completion: ((Result<URL, Error>) -> Void)?
    init(update: VerifiedUpdate, directory: URL) { self.update = update; self.directory = directory }
    func start(completion: @escaping (Result<URL, Error>) -> Void) {
        self.completion = completion
        session = URLSession(configuration: updateSessionConfiguration(archive: true), delegate: self, delegateQueue: nil)
        session.downloadTask(with: URL(string: update.payload.downloadURL)!).resume()
    }
    func cancel() { session?.invalidateAndCancel() }
    private func finish(_ result: Result<URL, Error>) {
        guard !finished else { return }; finished = true
        let callback = completion; completion = nil; session?.invalidateAndCancel(); callback?(result)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > update.payload.byteCount || totalBytesExpectedToWrite > update.payload.byteCount {
            finish(.failure(UpdateFailure.rejected("업데이트 파일 크기가 예상보다 큽니다.")))
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard !finished else { return }
        do {
            guard let http = downloadTask.response as? HTTPURLResponse, http.statusCode == 200,
                  UpdatePolicy.allowedResponseURL(http.url, archive: true) else { throw UpdateFailure.rejected("업데이트 파일 응답이 올바르지 않습니다.") }
            let attrs = try FileManager.default.attributesOfItem(atPath: location.path)
            guard (attrs[.size] as? NSNumber)?.intValue == update.payload.byteCount else { throw UpdateFailure.rejected("업데이트 ZIP 크기가 다릅니다.") }
            let bytes = try Data(contentsOf: location, options: .mappedIfSafe)
            try UpdatePolicy.verifyArchive(bytes, update: update)
            let destination = directory.appendingPathComponent(update.payload.assetName)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch { finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard UpdatePolicy.allowedResponseURL(request.url, archive: true) else {
            completionHandler(nil); finish(.failure(UpdateFailure.rejected("업데이트 파일이 허용되지 않은 서버로 이동했습니다."))); return
        }
        completionHandler(request)
    }
}
enum UpdateArchivePreparation {
    private static func command(_ tool: String, _ arguments: [String]) throws -> String {
        let task = Process(), output = Pipe()
        task.executableURL = URL(fileURLWithPath: tool); task.arguments = arguments
        var environment = ProcessInfo.processInfo.environment; environment["LC_ALL"] = "C"; task.environment = environment
        task.standardOutput = output; task.standardError = FileHandle.nullDevice
        try task.run()
        // Do not echo untrusted archive text to UI or let a second pipe deadlock.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0, data.count <= 4_194_304 else { throw UpdateFailure.rejected("설치 파일 검사 또는 압축 해제에 실패했습니다.") }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
    static func prepare(_ archive: URL, update: VerifiedUpdate) throws -> URL {
        let list = try command("/usr/bin/unzip", ["-Z1", archive.path])
        let permissions = try command("/usr/bin/zipinfo", ["-l", archive.path])
        try UpdatePolicy.validateExpansionSummary(command("/usr/bin/zipinfo", ["-t", archive.path]))
        let symlinks = permissions.split(separator: "\n").contains { $0.hasPrefix("l") }
        let names = list.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        try UpdatePolicy.validateEntries(names, hasSymlinks: symlinks)
        let expanded = archive.deletingLastPathComponent().appendingPathComponent("expanded", isDirectory: true)
        try FileManager.default.createDirectory(at: expanded, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        _ = try command("/usr/bin/ditto", ["-x", "-k", archive.path, expanded.path])
        let root = expanded.appendingPathComponent("CapsFlow-Installer", isDirectory: true)
        let script = root.appendingPathComponent("Install.command")
        guard FileManager.default.isExecutableFile(atPath: script.path),
              (try root.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw UpdateFailure.rejected("실행할 수 있는 간편 설치 파일이 없습니다.")
        }
        for (name, identifier) in [("CapsFlow.app", "local.capsflow.app"), ("CapsFlowInputMethod.app", "local.inputmethod.capsflow")] {
            let app = root.appendingPathComponent("apps/" + name)
            guard Bundle(url: app)?.bundleIdentifier == identifier else { throw UpdateFailure.rejected("설치 ZIP의 앱 식별자가 다릅니다.") }
            if name == "CapsFlow.app" {
                guard Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == update.payload.version,
                      Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String == String(update.payload.build) else {
                    throw UpdateFailure.rejected("설치 ZIP의 실제 앱 버전이 서명된 정보와 다릅니다.")
                }
            }
            _ = try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        }
        _ = try command("/usr/bin/codesign", ["--verify", "--strict", root.appendingPathComponent("bin/CapsFlowSetupHelper").path])
        return script
    }
}
