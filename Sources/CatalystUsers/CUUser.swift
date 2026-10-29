import Magritte
import CatalystConnectObjects

/// Native Users value. Its descriptions are the sole field/validation/codec definition.
public final class CUUser: ConnectDescribedObject {
    public var name = ""
    public var isSuperUser = false
    public init() {}
    public convenience init(name: String) { self.init(); self.name = name }
    public func magritteDescription() -> Description {
        let container = Description(id: "CUUser", className: "MAContainer")
        container.properties["label"] = .string("")
        let name = Description(id: "CUUser.name", className: "MAStringDescription")
        name.accessor = Accessor(className: "MASelectorAccessor", name: "name", writeName: "name:")
        name.properties = ["label": .string("Name"), "required": .boolean(true)]
        name.nativeRead = { .string(($0 as! CUUser).name) }
        name.nativeWrite = { object, value in
            guard case .string(let text) = value else { throw MagritteError("User name requires text") }
            (object as! CUUser).name = text
        }
        let superUser = Description(id: "CUUser.isSuperUser", className: "MABooleanDescription")
        superUser.accessor = Accessor(className: "MASelectorAccessor", name: "isSuperUser", writeName: "isSuperUser:")
        superUser.properties = ["label": .string("Super user"), "required": .boolean(true)]
        superUser.nativeRead = { .boolean(($0 as! CUUser).isSuperUser) }
        superUser.nativeWrite = { object, value in
            guard case .boolean(let flag) = value else { throw MagritteError("Super user requires Boolean") }
            (object as! CUUser).isSuperUser = flag
        }
        container.children = [name, superUser]
        return container
    }
}
