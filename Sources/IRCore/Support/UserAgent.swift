import Foundation

/// What this browser calls itself.
public enum UserAgent {

    /// The WebKit build every current Safari reports. It has been this value
    /// for years and is what appears in `AppleWebKit/…` already, so the two
    /// halves of the user agent agree.
    static let webKitBuild = "605.1.15"

    /// A fallback for the version, used only when Safari cannot be read.
    /// Deliberately a real recent version rather than something invented: a
    /// version string no Safari ever had is exactly the kind of oddity
    /// fingerprinting looks for.
    public static let fallbackSafariVersion = "18.0"

    /// Appended to WKWebView's default user agent, producing
    /// `… (KHTML, like Gecko) Version/26.5.2 Safari/605.1.15`.
    ///
    /// The version is read from the Safari installed on this Mac, so it ages
    /// with the system instead of freezing at whatever was current when this
    /// was written — a stale version is its own kind of "unsupported browser"
    /// banner a year from now.
    public static func safariToken(version: String? = nil) -> String {
        "Version/\(version ?? installedSafariVersion()) Safari/\(webKitBuild)"
    }

    /// Safari lives in one of two places depending on the macOS version: the
    /// cryptex is where it moved, and /Applications is a symlink to it on
    /// recent systems but the real thing on older ones.
    public static func installedSafariVersion(
        searching paths: [String] = [
            "/Applications/Safari.app/Contents/Info.plist",
            "/System/Cryptexes/App/System/Applications/Safari.app/Contents/Info.plist",
            "/System/Applications/Safari.app/Contents/Info.plist",
        ]
    ) -> String {
        for path in paths {
            guard let data = FileManager.default.contents(atPath: path),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: data, format: nil) as? [String: Any],
                  let version = plist["CFBundleShortVersionString"] as? String,
                  isPlausibleVersion(version) else { continue }
            return version
        }
        return fallbackSafariVersion
    }

    /// Digits and dots only. Whatever is in that plist ends up in a header sent
    /// to other people's servers, so it is checked rather than trusted — a
    /// stray newline there would corrupt every request the browser makes.
    public static func isPlausibleVersion(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 12
            && value.allSatisfy { $0.isNumber || $0 == "." }
            && value.first!.isNumber
    }
}
