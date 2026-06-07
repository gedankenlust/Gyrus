import Foundation

enum Config {
    static let backendHost = "127.0.0.1"
    static let backendPort = 8080
    static let backendURL  = URL(string: "http://\(backendHost):\(backendPort)")!
}
