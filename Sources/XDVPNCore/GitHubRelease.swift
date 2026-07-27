import Foundation

public struct GitHubReleaseMetadata: Equatable, Sendable {
    public let version: String
    public let downloadURL: URL?
    public let notes: String?

    public init(version: String, downloadURL: URL?, notes: String?) {
        self.version = version
        self.downloadURL = downloadURL
        self.notes = notes
    }

    public static func parse(_ data: Data) -> GitHubReleaseMetadata? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              !tag.isEmpty,
              let assets = json["assets"] as? [[String: Any]] else {
            return nil
        }

        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let zip = assets.first {
            ($0["name"] as? String)?.hasSuffix(".zip") == true
        }
        let downloadURL = (zip?["browser_download_url"] as? String)
            .flatMap(URL.init(string:))
        let body = (json["body"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return GitHubReleaseMetadata(
            version: version,
            downloadURL: downloadURL,
            notes: updateSection(from: body)
        )
    }

    public static func updateSection(from body: String?) -> String? {
        guard let body, !body.isEmpty else { return nil }

        let acceptedHeadings = ["更新了什么", "更新内容", "更新"]
        var isCapturing = false
        var captured: [String] = []

        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                if isCapturing { break }
                let heading = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                isCapturing = acceptedHeadings.contains(heading)
                continue
            }
            if isCapturing {
                captured.append(line)
            }
        }

        let updateNotes = captured.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return updateNotes.isEmpty ? body : updateNotes
    }
}
