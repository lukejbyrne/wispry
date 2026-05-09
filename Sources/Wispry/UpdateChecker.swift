import Foundation

struct AppUpdateManifest: Decodable {
    let version: String
    let build: String
    let minimumMacOS: String
    let downloadURL: URL
    let releaseNotes: String

    enum CodingKeys: String, CodingKey {
        case version
        case build
        case minimumMacOS = "minimum_macos"
        case downloadURL = "download_url"
        case releaseNotes = "release_notes"
    }
}

enum AppUpdateResult {
    case available(AppUpdateManifest)
    case current(version: String)
    case failed(String)
}

final class UpdateChecker {
    private let manifestURLs = [
        URL(string: "https://idonttype.com/updates.json")!,
        URL(string: "https://typelocal.netlify.app/updates.json")!
    ]

    func check(completion: @escaping (AppUpdateResult) -> Void) {
        check(urlIndex: 0, lastError: nil, completion: completion)
    }

    private func check(urlIndex: Int, lastError: String?, completion: @escaping (AppUpdateResult) -> Void) {
        guard urlIndex < manifestURLs.count else {
            DispatchQueue.main.async {
                completion(.failed(lastError ?? "No update manifest is available."))
            }
            return
        }

        let request = URLRequest(url: manifestURLs[urlIndex], cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                self.check(urlIndex: urlIndex + 1, lastError: error.localizedDescription, completion: completion)
                return
            } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                self.check(urlIndex: urlIndex + 1, lastError: "Update server returned HTTP \(http.statusCode).", completion: completion)
                return
            } else if let data {
                do {
                    let manifest = try JSONDecoder().decode(AppUpdateManifest.self, from: data)
                    let result: AppUpdateResult = Self.isNewer(manifest: manifest)
                        ? .available(manifest)
                        : .current(version: Self.currentVersion)
                    DispatchQueue.main.async {
                        completion(result)
                    }
                } catch {
                    self.check(urlIndex: urlIndex + 1, lastError: "Could not read update manifest.", completion: completion)
                }
            } else {
                self.check(urlIndex: urlIndex + 1, lastError: "Update server returned no data.", completion: completion)
            }
        }.resume()
    }

    private static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
    }

    private static func isNewer(manifest: AppUpdateManifest) -> Bool {
        switch compareVersions(manifest.version, currentVersion) {
        case .orderedDescending:
            return true
        case .orderedAscending:
            return false
        case .orderedSame:
            return (Int(manifest.build) ?? 0) > currentBuild
        }
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(left.count, right.count)

        for index in 0..<count {
            let leftPart = index < left.count ? left[index] : 0
            let rightPart = index < right.count ? right[index] : 0
            if leftPart > rightPart {
                return .orderedDescending
            }
            if leftPart < rightPart {
                return .orderedAscending
            }
        }
        return .orderedSame
    }
}
