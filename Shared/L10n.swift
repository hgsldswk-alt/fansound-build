import Foundation

final class FanResourceAnchor: NSObject {}

enum L {
    static let bundle = Bundle(for: FanResourceAnchor.self)

    static func t(_ key: String) -> String {
        NSLocalizedString(key, bundle: bundle, comment: "")
    }

    static func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), locale: Locale.current, arguments: args)
    }
}
