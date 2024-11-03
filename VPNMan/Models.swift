struct VPNConfiguration: Identifiable {
    var id: String
    var name: String
    var isConnected: Bool
    var serviceType: String
}

enum Command {
    case list
    case start(String)
    case stop(String)

    var body: String {
        switch self {
        case .list:
            return "scutil --nc list"
        case .start(let name):
            return "scutil --nc start \(name)"
        case .stop(let name):
            return "scutil --nc stop \(name)"
        }
    }
}

enum CommandError: Error {
    case executionFailed(String)
}

enum FormatError: Error {
    case invalidFormat(String)
}
