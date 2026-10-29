import Foundation
import Combine
import Magritte
import CatalystConnectObjects

/// Native Users value. Its descriptions are the sole field/validation/codec definition.
public class CUUser: ConnectDescribedObject, ObservableObject {
    public let objectWillChange = ObservableObjectPublisher()
    public var name = "" { didSet { if !applying && name != oldValue { replica.edited(); objectWillChange.send() } } }
    public var isSuperUser = false { didSet {
        if !applying && context != nil { isSuperUser = oldValue }
        else if !applying && isSuperUser != oldValue { objectWillChange.send() }
    } }
    public internal(set) var replica = ObjectReplicaState() { didSet { if !applying { objectWillChange.send() } } }
    public internal(set) var lastError: String? { didSet { if !applying { objectWillChange.send() } } }
    internal var context: CULiveUsersContext?
    internal var applying = false
    internal var acceptedName = ""
    internal var creationKey = ""
    internal var creationName = ""
    internal var creationSequence: UInt64 = 0
    public required init() {}
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
        if context != nil { superUser.properties["readOnly"] = .boolean(true) }
        container.children = [name, superUser]
        if context != nil {
            let state = CULiveUserState().magritteDescription()
            for field in state.children where !["name", "isSuperUser"].contains(field.accessor!.name) {
                let selector = field.accessor!.name
                field.nativeRead = { object in
                    let user = object as! CUUser
                    switch selector {
                    case "userIdentifier": return .string(user.replica.identifier)
                    case "revision": return .integer(user.replica.revision)
                    default: return .string(user.replica.phase.rawValue)
                    }
                }
                field.nativeWrite = { _, _ in throw MagritteError("Server-owned User metadata is read-only") }
                container.children.append(field)
            }
        }
        return container
    }
}
