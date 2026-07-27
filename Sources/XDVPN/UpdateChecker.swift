import AppKit
import Foundation
import SwiftUI
import XDVPNCore

@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var latestVersion: String?
    @Published private(set) var downloadURL: URL?
    @Published private(set) var releaseNotes: String?
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var statusText: String?

    var hasUpdate: Bool {
        guard let latest = latestVersion else { return false }
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return compare(latest, isNewerThan: current)
    }

    private let repo = "kafeifei/XDVPN"
    private var downloadDelegate: DownloadDelegate?
    private var updateWindow: NSWindow?
    private var releaseNotesWindow: NSWindow?
    private var pollTimer: Timer?

    func startPolling(interval: TimeInterval = 600) {
        check()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.check() }
        }
    }

    func check() {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data,
                  let release = GitHubReleaseMetadata.parse(data) else { return }

            Task { @MainActor [weak self] in
                self?.latestVersion = release.version
                self?.downloadURL = release.downloadURL
                self?.releaseNotes = release.notes
            }
        }.resume()
    }

    #if DEBUG
    func fakeUpdate(
        version: String,
        notes: String = "- 展示本次更新说明。\n- 验证更新窗口滚动布局。"
    ) {
        latestVersion = version
        downloadURL = URL(string: "https://github.com/\(repo)/releases")
        releaseNotes = notes
    }

    func clearFakeUpdate() {
        latestVersion = nil
        downloadURL = nil
        releaseNotes = nil
    }
    #endif

    func showUpdateWindow() {
        if let w = updateWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = UpdateWindowView(updater: self)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "XDVPN 更新"
        window.styleMask = [.titled, .closable]
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateWindow = window
    }

    func showCurrentReleaseNotesWindow() {
        if let window = releaseNotesWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = CurrentReleaseNotesView(
            version: currentVersion,
            notes: bundledReleaseNotes ?? "暂无更新日志。"
        )
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "XDVPN 更新日志"
        window.styleMask = [.titled, .closable]
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        releaseNotesWindow = window
    }

    func showCurrentReleaseNotesIfNeeded() {
        guard bundledReleaseNotes != nil else { return }
        let key = "xdvpn.lastShownReleaseNotesVersion"
        guard UserDefaults.standard.string(forKey: key) != currentVersion else { return }
        UserDefaults.standard.set(currentVersion, forKey: key)
        showCurrentReleaseNotesWindow()
    }

    func performUpdate() {
        guard let downloadURL, hasUpdate, !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        statusText = "下载中…"

        let delegate = DownloadDelegate { [weak self] progress in
            Task { @MainActor in self?.downloadProgress = progress }
        } completion: { [weak self] result in
            Task { @MainActor in self?.handleDownloadResult(result) }
        }
        downloadDelegate = delegate

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        session.downloadTask(with: downloadURL).resume()
    }

    private func handleDownloadResult(_ result: Result<URL, Error>) {
        switch result {
        case .failure:
            isDownloading = false
            statusText = "下载失败"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.statusText = nil
            }

        case .success(let zipURL):
            statusText = "解压中…"
            let appPath = Bundle.main.bundlePath
            let pid = ProcessInfo.processInfo.processIdentifier
            let tempDir = zipURL.deletingLastPathComponent()

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    let unzipDir = tempDir.appendingPathComponent("extracted")
                    try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)

                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    proc.arguments = ["-xk", zipURL.path, unzipDir.path]
                    try proc.run()
                    proc.waitUntilExit()
                    guard proc.terminationStatus == 0 else { throw UpdateError.unzipFailed }

                    let contents = try FileManager.default.contentsOfDirectory(
                        at: unzipDir, includingPropertiesForKeys: nil)
                    guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
                        throw UpdateError.noAppFound
                    }

                    let script = """
                    #!/bin/bash
                    for i in $(seq 1 75); do
                        kill -0 \(pid) 2>/dev/null || break
                        sleep 0.2
                    done
                    rm -rf "\(appPath)"
                    mv "\(newApp.path)" "\(appPath)"
                    open "\(appPath)"
                    rm -rf "\(tempDir.path)"
                    """
                    let scriptPath = tempDir.appendingPathComponent("xdvpn-updater.sh")
                    try script.write(to: scriptPath, atomically: true, encoding: .utf8)
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

                    let s = self
                    Task { @MainActor in
                        s?.statusText = "更新就绪，正在重启…"
                        s?.downloadProgress = 1.0

                        try? await Task.sleep(nanoseconds: 1_200_000_000)

                        let runner = Process()
                        runner.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
                        runner.arguments = [scriptPath.path]
                        runner.standardOutput = FileHandle.nullDevice
                        runner.standardError = FileHandle.nullDevice
                        try? runner.run()

                        exit(0)
                    }
                } catch {
                    let s = self
                    Task { @MainActor in
                        s?.isDownloading = false
                        s?.statusText = "更新失败"
                        try? FileManager.default.removeItem(at: tempDir)
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        s?.statusText = nil
                    }
                }
            }
        }
    }

    private func compare(_ a: String, isNewerThan b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let va = i < pa.count ? pa[i] : 0
            let vb = i < pb.count ? pb[i] : 0
            if va != vb { return va > vb }
        }
        return false
    }

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var bundledReleaseNotes: String? {
        guard let url = Bundle.main.url(forResource: "RELEASE_NOTES", withExtension: "md"),
              let body = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return GitHubReleaseMetadata.updateSection(from: body)
    }
}

private enum UpdateError: Error {
    case unzipFailed, noAppFound
}

private struct UpdateWindowView: View {
    @ObservedObject var updater: UpdateChecker

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.blue)

            Text("发现新版本")
                .font(.headline)

            Text("当前版本 \(currentVersion)，最新版本 \(updater.latestVersion ?? "")")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let notes = updater.releaseNotes, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("更新了什么")
                        .font(.subheadline.weight(.semibold))

                    ScrollView {
                        Text(notes)
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 160)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.secondary.opacity(0.08))
                    )
                }
            }

            if updater.isDownloading {
                VStack(spacing: 8) {
                    ProgressView(value: updater.downloadProgress)
                    Text(updater.statusText ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("更新到 \(updater.latestVersion ?? "")") {
                    updater.performUpdate()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

private struct CurrentReleaseNotesView: View {
    let version: String
    let notes: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36))
                .foregroundStyle(.blue)

            Text("XDVPN v\(version)")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("更新了什么")
                    .font(.subheadline.weight(.semibold))

                ScrollView {
                    Text(notes)
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 180)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                )
            }

            Button("知道了") {
                NSApp.keyWindow?.close()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 440)
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Double) -> Void
    let onComplete: (Result<URL, Error>) -> Void

    init(onProgress: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        self.onProgress = onProgress
        self.onComplete = completion
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("xdvpn-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: location, to: dest)
            onComplete(.success(dest))
        } catch {
            onComplete(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { onComplete(.failure(error)) }
    }
}
