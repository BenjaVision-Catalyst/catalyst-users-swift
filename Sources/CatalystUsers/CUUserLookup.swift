import Magritte
import CatalystConnectObjects

/// Exact-name query reusing CUUser's name description with local lookup accessors.
public final class CUUserLookup: ConnectDescribedObject {
    public var name = ""
    public init() {}
    public convenience init(name: String) { self.init(); self.name = name }
    public func magritteDescription() -> Description {
        let container = CUUser().magritteDescription()
        container.children = container.children.filter { $0.accessor?.name == "name" }
        let name = container.children[0]
        name.nativeRead = { .string(($0 as! CUUserLookup).name) }
        name.nativeWrite = { object, value in
            guard case .string(let text) = value else { throw MagritteError("User name requires text") }
            (object as! CUUserLookup).name = text
        }
        return container
    }
}
