import Foundation

/// Schemes never opened nor handed to the app, whatever a link says (the
/// backend's placement / card link rule). The same list on every Joryio SDK,
/// pinned by the backend spec sdk-placements-parity.spec.ts.
let REFUSED_LINK_SCHEMES: [String] = ["javascript", "data", "file", "vbscript", "blob", "about", "content", "intent"]

/// An app deep link (`myapp://cart`) that may go to the app's own handler: a
/// `scheme://` link whose scheme is not http(s) and not a refused one. The SDK
/// never opens it itself; http(s) goes to the SDK's own safe open path, and
/// anything else is refused. The same rule on every Joryio SDK.
public func isAppDeepLink(_ url: String?) -> Bool {
    guard let raw = url?.trimmingCharacters(in: .whitespacesAndNewlines),
          let sep = raw.range(of: "://") else { return false }
    let scheme = raw[raw.startIndex..<sep.lowerBound]
    // RFC 3986: ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ), and something after "://".
    guard let first = scheme.unicodeScalars.first, first.isASCII, CharacterSet.letters.contains(first),
          scheme.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "+-.".unicodeScalars.contains($0)) }),
          sep.upperBound < raw.endIndex else { return false }
    let lower = scheme.lowercased()
    return lower != "http" && lower != "https" && !REFUSED_LINK_SCHEMES.contains(lower)
}
