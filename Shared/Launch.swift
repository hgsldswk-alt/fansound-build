import Foundation

enum Launch {
    static let freePeriod = false

    static var isUITesting: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-ui-testing")
        #else
        false
        #endif
    }

    static var testArguments: [String] {
        isUITesting ? ProcessInfo.processInfo.arguments : []
    }

    static func isFree(arguments: [String]) -> Bool {
        if arguments.contains("-free-mode") { return true }
        return freePeriod && !arguments.contains { ["-paid-mode", "-paywall", "-expired"].contains($0) }
    }

    static var isFree: Bool { isFree(arguments: testArguments) }

    static func value(_ flag: String, in arguments: [String] = testArguments) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static let supportURL = URL(string: "https://hgsldswk-alt.github.io/fansound-support/")!

    static var downloadURL: URL {
        guard let id = L.bundle.object(forInfoDictionaryKey: "APP_STORE_ID") as? String,
              !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }),
              let url = URL(string: "https://apps.apple.com/app/id" + id)
        else { return supportURL }
        return url
    }
}
