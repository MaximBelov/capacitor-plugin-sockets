import Foundation

@objc public class Sockets: NSObject {
    @objc public func echo(_ value: String) -> String {
        print(value)
        return value
    }
}
