import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {
  func withFile(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("rover.ini")
    try Data("original".utf8).write(to: file)
    try body(file)
  }
  func testReplacementWritesExactBytes() throws {
    try withFile { file in
      let contents = Data("[caster]\nhost = caster.example\n".utf8)
      try PlatformDocuments.replace(url: file, expectedName: "rover.ini", bytes: contents)
      XCTAssertEqual(try Data(contentsOf: file), contents)
    }
  }
  func testChangedNameNeverOverwritesOriginal() throws {
    try withFile { file in
      XCTAssertThrowsError(try PlatformDocuments.replace(url: file, expectedName: "other.ini", bytes: Data()))
      XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
    }
  }
  func testOversizedConfigurationNeverOverwritesOriginal() throws {
    try withFile { file in
      XCTAssertThrowsError(try PlatformDocuments.replace(url: file, expectedName: "rover.ini", bytes: Data(count: 1_048_577)))
      XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
    }
  }
  func testMissingFileIsNotSilentlyRecreated() throws {
    try withFile { file in
      try FileManager.default.removeItem(at: file)
      XCTAssertThrowsError(try PlatformDocuments.replace(url: file, expectedName: "rover.ini", bytes: Data()))
      XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
  }
}
