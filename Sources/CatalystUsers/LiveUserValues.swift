import Magritte
import CatalystConnectObjects

/// Installed request metadata; the User name retains its original Magritte metadata.
public final class CUUserChange: ConnectDescribedObject {
    public var userIdentifier = "", operationIdentifier = "", name = ""
    public var expectedRevision: Int64 = 0
    public init() {}
    public func magritteDescription() -> Description {
        let root = CUUserLookup().magritteDescription()
        root.children[0].nativeRead = { .string(($0 as! CUUserChange).name) }
        root.children[0].nativeWrite = { ($0 as! CUUserChange).name = try liveText($1) }
        root.children += [
            liveString("userIdentifier", "User identity", read: { ($0 as! CUUserChange).userIdentifier }, write: { ($0 as! CUUserChange).userIdentifier = $1 }),
            liveString("operationIdentifier", "Operation identity", read: { ($0 as! CUUserChange).operationIdentifier }, write: { ($0 as! CUUserChange).operationIdentifier = $1 }),
            liveRevision("expectedRevision", "Expected revision", read: { ($0 as! CUUserChange).expectedRevision }, write: { ($0 as! CUUserChange).expectedRevision = $1 })]
        return root
    }
}

/// A state transfer uses the User's actual field descriptions, plus Fabric metadata.
public final class CULiveUserState: CUUser {
    public var userIdentifier = "", outcome = ""
    public var revision: Int64 = 0
    public required init() { super.init() }
    public override func magritteDescription() -> Description {
        let root = super.magritteDescription()
        root.children.first { $0.accessor?.name == "isSuperUser" }?.properties["readOnly"] = .boolean(true)
        root.children += [
            liveString("userIdentifier", "User identity", readOnly: true, read: { ($0 as! CULiveUserState).userIdentifier }, write: { ($0 as! CULiveUserState).userIdentifier = $1 }),
            liveRevision("revision", "Revision", readOnly: true, read: { ($0 as! CULiveUserState).revision }, write: { ($0 as! CULiveUserState).revision = $1 }),
            liveString("outcome", "Outcome", readOnly: true, read: { ($0 as! CULiveUserState).outcome }, write: { ($0 as! CULiveUserState).outcome = $1 })]
        return root
    }
}
private func liveText(_ value: Value) throws -> String {
    guard case .string(let text) = value else { throw MagritteError("Text required") }; return text
}
private func liveString(_ name: String, _ label: String, readOnly: Bool = false,
    read: @escaping (AnyObject) -> String, write: @escaping (AnyObject, String) -> Void) -> Description {
    let d = Description(id: "Fabric." + name, className: "MAStringDescription")
    d.accessor = Accessor(className: "MASelectorAccessor", name: name, writeName: name + ":")
    d.properties = ["label": .string(label), "required": .boolean(true), "readOnly": .boolean(readOnly)]
    d.nativeRead = { .string(read($0)) }; d.nativeWrite = { write($0, try liveText($1)) }
    return d
}
private func liveRevision(_ name: String, _ label: String, readOnly: Bool = false,
    read: @escaping (AnyObject) -> Int64, write: @escaping (AnyObject, Int64) -> Void) -> Description {
    let d = Description(id: "Fabric." + name, className: "MANumberDescription")
    d.accessor = Accessor(className: "MASelectorAccessor", name: name, writeName: name + ":")
    d.properties = ["label": .string(label), "required": .boolean(true), "readOnly": .boolean(readOnly), "min": .integer(0), "kind": .classValue("Integer")]
    d.nativeRead = { .integer(read($0)) }; d.nativeWrite = { object, value in
        guard case .integer(let revision) = value else { throw MagritteError("Revision required") }; write(object, revision)
    }
    return d
}
