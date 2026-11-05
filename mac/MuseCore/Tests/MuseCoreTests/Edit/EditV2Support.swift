import Foundation
import XCTest
@testable import MuseCore

/// Any JSON value, for comparing what the Swift port encodes with the reference's fixtures.
enum JV: Codable, Equatable, CustomStringConvertible {
    case null
    case bool(Bool)
    case num(Double)
    case str(String)
    case arr([JV])
    case obj([String: JV])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .num(n) }
        else if let s = try? c.decode(String.self) { self = .str(s) }
        else if let a = try? c.decode([JV].self) { self = .arr(a) }
        else { self = .obj(try c.decode([String: JV].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .num(let n): try c.encode(n)
        case .str(let s): try c.encode(s)
        case .arr(let a): try c.encode(a)
        case .obj(let o): try c.encode(o)
        }
    }

    subscript(_ k: String) -> JV { if case .obj(let o) = self { return o[k] ?? .null }; return .null }
    subscript(_ i: Int) -> JV { if case .arr(let a) = self, a.indices.contains(i) { return a[i] }; return .null }
    var array: [JV] { if case .arr(let a) = self { return a }; return [] }
    var object: [String: JV] { if case .obj(let o) = self { return o }; return [:] }
    var double: Double? { if case .num(let n) = self { return n }; return nil }
    var string: String? { if case .str(let s) = self { return s }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }

    var description: String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return (try? String(decoding: e.encode(self), as: UTF8.self)) ?? "?"
    }

    /// Decodes this value as a Swift type.
    func decode<T: Decodable>(_ t: T.Type) throws -> T { try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self)) }

    static func of<T: Encodable>(_ v: T) throws -> JV { try JSONDecoder().decode(JV.self, from: JSONEncoder().encode(v)) }
}

/// Differences between two JSON values: numbers within `tol`, a missing key the same as null. Empty when they match.
func jsonDiff(_ a: JV, _ b: JV, tol: Double = 1e-6, path: String = "$") -> [String] {
    switch (a, b) {
    case (.num(let x), .num(let y)):
        return abs(x - y) <= tol ? [] : ["\(path): \(x) != \(y)"]
    case (.arr(let x), .arr(let y)):
        if x.count != y.count { return ["\(path): \(x.count) items != \(y.count)"] }
        return zip(x, y).enumerated().flatMap { i, p in jsonDiff(p.0, p.1, tol: tol, path: "\(path)[\(i)]") }
    case (.obj(let x), .obj(let y)):
        return Set(x.keys).union(y.keys).sorted().flatMap { k in jsonDiff(x[k] ?? .null, y[k] ?? .null, tol: tol, path: "\(path).\(k)") }
    default:
        return a == b ? [] : ["\(path): \(a) != \(b)"]
    }
}

/// Strict structural equality (no null/missing leniency), numbers within `tol`.
func jsonStrictDiff(_ a: JV, _ b: JV, tol: Double = 1e-12, path: String = "$") -> [String] {
    switch (a, b) {
    case (.obj(let x), .obj(let y)):
        if Set(x.keys) != Set(y.keys) { return ["\(path): keys \(x.keys.sorted()) != \(y.keys.sorted())"] }
        return x.keys.sorted().flatMap { k in jsonStrictDiff(x[k]!, y[k]!, tol: tol, path: "\(path).\(k)") }
    case (.arr(let x), .arr(let y)):
        if x.count != y.count { return ["\(path): \(x.count) items != \(y.count)"] }
        return zip(x, y).enumerated().flatMap { i, p in jsonStrictDiff(p.0, p.1, tol: tol, path: "\(path)[\(i)]") }
    default:
        return jsonDiff(a, b, tol: tol, path: path)
    }
}

func editorFixture(_ name: String) throws -> JV {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/editor"), "missing fixture \(name)")
    return try JSONDecoder().decode(JV.self, from: Data(contentsOf: url))
}

func assertJSON<T: Encodable>(_ value: T, _ expected: JV, _ what: @autoclosure () -> String, file: StaticString = #filePath, line: UInt = #line) {
    do {
        let d = jsonDiff(try JV.of(value), expected)
        XCTAssert(d.isEmpty, "\(what()): " + d.prefix(5).joined(separator: "; "), file: file, line: line)
    } catch {
        XCTFail("\(what()): \(error)", file: file, line: line)
    }
}
