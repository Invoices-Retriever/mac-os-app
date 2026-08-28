import Foundation

/// A test harness in eighty lines.
///
/// The project ships no dependencies, and the Swift toolchain that comes with
/// Apple's Command Line Tools carries neither XCTest nor swift-testing — so a
/// contributor without the full Xcode installed could not run the tests at all.
/// `swift run irtest` works for everyone, and it is what CI runs.
@MainActor
enum Harness {
    static var currentSuite = ""
    static var failures: [String] = []
    static var passed = 0
    static var currentTest = ""
}

@MainActor
func suite(_ name: String, _ body: () async throws -> Void) async {
    Harness.currentSuite = name
    print("\n\u{001B}[1m\(name)\u{001B}[0m")
    do {
        try await body()
    } catch {
        Harness.failures.append("\(name): the suite itself threw — \(error)")
        print("  ✗ suite threw: \(error)")
    }
}

@MainActor
func test(_ name: String, _ body: () async throws -> Void) async {
    Harness.currentTest = name
    let before = Harness.failures.count
    do {
        try await body()
    } catch {
        Harness.failures.append("\(Harness.currentSuite) / \(name): threw \(error)")
    }
    if Harness.failures.count == before {
        Harness.passed += 1
        print("  ✓ \(name)")
    } else {
        print("  ✗ \(name)")
        for failure in Harness.failures[before...] {
            print("      \(failure.split(separator: ":").dropFirst(2).joined(separator: ":").trimmingCharacters(in: .whitespaces))")
        }
    }
}

@MainActor
func expect(_ condition: Bool, _ message: @autoclosure () -> String = "",
            file: String = #fileID, line: Int = #line) {
    guard !condition else { return }
    let detail = message().isEmpty ? "expectation failed" : message()
    Harness.failures.append("\(Harness.currentSuite) / \(Harness.currentTest): \(detail) (\(file):\(line))")
}

@MainActor
func expectEqual<T: Equatable>(_ actual: T?, _ expected: T?,
                               file: String = #fileID, line: Int = #line) {
    guard actual != expected else { return }
    Harness.failures.append(
        "\(Harness.currentSuite) / \(Harness.currentTest): expected \(expected.map { "\($0)" } ?? "nil"), got \(actual.map { "\($0)" } ?? "nil") (\(file):\(line))")
}

@MainActor
func expectThrows(_ body: () async throws -> Void,
                  file: String = #fileID, line: Int = #line) async {
    do {
        try await body()
        Harness.failures.append("\(Harness.currentSuite) / \(Harness.currentTest): expected an error, none was thrown (\(file):\(line))")
    } catch {
        // expected
    }
}

@MainActor
func report() -> Never {
    print("\n" + String(repeating: "─", count: 50))
    if Harness.failures.isEmpty {
        print("\u{001B}[32m\(Harness.passed) test(s) passed\u{001B}[0m")
        exit(0)
    }
    print("\u{001B}[31m\(Harness.failures.count) failure(s), \(Harness.passed) passed\u{001B}[0m")
    for failure in Harness.failures { print("  • \(failure)") }
    exit(1)
}
