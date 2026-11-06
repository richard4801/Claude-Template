import Foundation

// Edit sessions (workstream 3, plans/video-editor.md "Edit sessions and edit ops"): the Swift port of the reference JSON Patch
// (server/api/src/editor/jsonpatch.ts; RFC 6902 subset: add / remove / replace). `diff` must give byte-identical patches to the
// server's and the Android port's (shared fixture editor/jsonpatch.json):
//   - objects: keys sorted by UTF-16 code units (JavaScript's default sort); only in b → add, only in a → remove, both → recurse;
//   - arrays: same length → recurse per index; different length → replace the whole array;
//   - anything else that differs (type change, number, string, boolean, null) → replace.

/// One JSON Patch operation. `value` is absent for `remove`; a JSON `null` value is `.null` (kept, unlike a missing one).
public struct EditPatchOp: Codable, Hashable, Sendable {
    public var op: String
    public var path: String
    public var value: JSONValue?

    public init(op: String, path: String, value: JSONValue? = nil) { self.op = op; self.path = path; self.value = value }
    public static func add(_ path: String, _ v: JSONValue) -> EditPatchOp { EditPatchOp(op: "add", path: path, value: v) }
    public static func remove(_ path: String) -> EditPatchOp { EditPatchOp(op: "remove", path: path) }
    public static func replace(_ path: String, _ v: JSONValue) -> EditPatchOp { EditPatchOp(op: "replace", path: path, value: v) }

    enum CodingKeys: String, CodingKey { case op, path, value }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        op = try c.decode(String.self, forKey: .op)
        path = try c.decode(String.self, forKey: .path)
        // decodeIfPresent would turn `"value": null` into nil; a null value is a real value here.
        value = c.contains(.value) ? try c.decode(JSONValue.self, forKey: .value) : nil
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(op, forKey: .op)
        try c.encode(path, forKey: .path)
        if let value { try c.encode(value, forKey: .value) }
    }
}

public enum JSONPatch {
    public struct PatchError: Error, Equatable, CustomStringConvertible, Sendable {
        public var message: String
        public init(_ m: String) { message = m }
        public var description: String { message }
    }

    static func esc(_ k: String) -> String { k.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }
    static func unesc(_ k: String) -> String { k.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~") }

    /// JavaScript's default `sort()` order: UTF-16 code units.
    static func jsLess(_ a: String, _ b: String) -> Bool { a.utf16.lexicographicallyPrecedes(b.utf16) }

    /// Deep equality for JSON values (numbers by value: 1 and 1.0 are equal).
    public static func jsonEqual(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.number(x), .number(y)): return x == y
        case let (.string(x), .string(y)): return x == y
        case let (.array(x), .array(y)): return x.count == y.count && zip(x, y).allSatisfy { jsonEqual($0, $1) }
        case let (.object(x), .object(y)):
            return x.count == y.count && x.allSatisfy { k, v in y[k].map { jsonEqual(v, $0) } ?? false }
        default: return false
        }
    }

    /// The patch that turns `a` into `b`.
    public static func diff(_ a: JSONValue, _ b: JSONValue, path: String = "") -> [EditPatchOp] {
        if jsonEqual(a, b) { return [] }
        if case .object(let oa) = a, case .object(let ob) = b {
            var out: [EditPatchOp] = []
            let keys = Set(oa.keys).union(ob.keys).sorted(by: jsLess)
            for k in keys {
                let p = "\(path)/\(esc(k))"
                switch (oa[k], ob[k]) {
                case (nil, let v?): out.append(.add(p, v))
                case (_?, nil): out.append(.remove(p))
                case let (x?, y?): out.append(contentsOf: diff(x, y, path: p))
                case (nil, nil): break
                }
            }
            return out
        }
        if case .array(let xa) = a, case .array(let xb) = b, xa.count == xb.count {
            return xa.indices.flatMap { diff(xa[$0], xb[$0], path: "\(path)/\($0)") }
        }
        return [.replace(path, b)]
    }

    /// Applies a patch to a copy of `doc`. Throws PatchError when a path doesn't fit the document.
    public static func apply(_ doc: JSONValue, _ patch: [EditPatchOp]) throws -> JSONValue {
        var root = doc
        for op in patch {
            guard ["add", "remove", "replace"].contains(op.op) else { throw PatchError("bad patch operation") }
            if op.path.isEmpty {
                if op.op == "remove" { throw PatchError("cannot remove the document") }
                root = op.value ?? .null
                continue
            }
            guard op.path.hasPrefix("/") else { throw PatchError("bad path \(op.path)") }
            let parts = op.path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map { unesc(String($0)) }
            try apply(op, parts[...], to: &root)
        }
        return root
    }

    private static func apply(_ op: EditPatchOp, _ parts: ArraySlice<String>, to node: inout JSONValue) throws {
        let k = parts.first!
        let last = parts.count == 1
        switch node {
        case .array(var arr):
            if last {
                let n = k == "-" ? arr.count : Int(k) ?? -1
                guard n >= 0, n <= arr.count, op.op == "add" || n < arr.count else { throw PatchError("no \(op.path)") }
                switch op.op {
                case "add": arr.insert(op.value ?? .null, at: n)
                case "remove": arr.remove(at: n)
                default: arr[n] = op.value ?? .null
                }
            } else {
                guard let n = Int(k), n >= 0, n < arr.count else { throw PatchError("no \(op.path)") }
                try apply(op, parts.dropFirst(), to: &arr[n])
            }
            node = .array(arr)
        case .object(var obj):
            if last {
                if op.op != "add", obj[k] == nil { throw PatchError("no \(op.path)") }
                if op.op == "remove" { obj[k] = nil } else { obj[k] = op.value ?? .null }
            } else {
                guard var child = obj[k] else { throw PatchError("no \(op.path)") }
                obj[k] = nil // keep the child uniquely referenced while it changes
                try apply(op, parts.dropFirst(), to: &child)
                obj[k] = child
            }
            node = .object(obj)
        default:
            throw PatchError("no \(op.path)")
        }
    }

    /// Patches a Codable value (encode → apply → decode).
    public static func apply<T: Codable>(_ value: T, _ patch: [EditPatchOp]) throws -> T {
        try decode(T.self, try apply(try encode(value), patch))
    }

    /// Any Encodable as a JSON value.
    public static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(value))
    }

    public static func decode<T: Decodable>(_ type: T.Type, _ v: JSONValue) throws -> T {
        try JSONDecoder().decode(T.self, from: try JSONEncoder().encode(v))
    }
}
