#!/usr/bin/env swift
import Foundation

// Run from the project root: swift Tests/WindowPickerRegression.swift
// Compile the actual chooser in isolation so these checks never capture the
// desktop or modify a Sprite Vault collection. Two small test panels open/close.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = try String(contentsOf: root.appendingPathComponent("Sources/FortniteSpriteTracker/Services/ScreenCaptureService.swift"), encoding: .utf8)
let begin = source.range(of: "// MARK: - Responsive in-app window selection")!
let end = source.range(of: "private enum ScreenCaptureServiceError:", range: begin.upperBound..<source.endIndex)!
let controller = String(source[begin.lowerBound..<end.lowerBound])
let harness = #"""
import AppKit
import SwiftUI
import ScreenCaptureKit

CONTROLLER

@main
struct RegressionChecks {
    @MainActor
    static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Timed out waiting for test state")
    }

    @MainActor
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)

        let empty = CaptureWindowPickerController(loadWindows: { [] })
        empty.refresh()
        try await waitUntil { !empty.isLoading }
        precondition(empty.windows.isEmpty && empty.errorText == nil)
        print("PASS empty window list")

        let denied = CaptureWindowPickerController(loadWindows: {
            throw NSError(domain: "PermissionDenied", code: 1)
        })
        denied.refresh()
        try await waitUntil { !denied.isLoading }
        precondition(denied.errorText?.contains("Screen Recording") == true)
        print("PASS enumeration failure")

        var firstRequest: CheckedContinuation<[SCWindow], Error>?
        var attempts = 0
        let stalled = CaptureWindowPickerController(timeout: .milliseconds(50), loadWindows: {
            attempts += 1
            if attempts == 1 {
                return try await withCheckedThrowingContinuation { firstRequest = $0 }
            }
            return []
        })
        stalled.refresh()
        try await waitUntil { !stalled.isLoading }
        precondition(stalled.errorText?.contains("taking too long") == true)
        print("PASS stalled request timeout")
        stalled.refresh()
        try await waitUntil { !stalled.isLoading }
        precondition(attempts == 2 && stalled.errorText == nil)
        firstRequest!.resume(throwing: NSError(domain: "LateFailure", code: 2))
        try await Task.sleep(for: .milliseconds(30))
        precondition(stalled.errorText == nil)
        print("PASS retry ignores late response")

        var pending: CheckedContinuation<[SCWindow], Error>?
        var callbacks = 0
        let cancellable = CaptureWindowPickerController(loadWindows: {
            try await withCheckedThrowingContinuation { pending = $0 }
        })
        cancellable.show { selection in
            precondition(selection == nil)
            callbacks += 1
        }
        try await waitUntil { pending != nil }
        cancellable.finish(nil)
        cancellable.finish(nil)
        precondition(callbacks == 1 && !cancellable.isLoading)
        pending!.resume(throwing: NSError(domain: "AfterCancel", code: 3))
        try await Task.sleep(for: .milliseconds(30))
        precondition(callbacks == 1 && cancellable.errorText == nil)
        print("PASS cancel resolves once and ignores late response")

        let closable = CaptureWindowPickerController(loadWindows: { [] })
        closable.show { _ in callbacks += 1 }
        try await waitUntil { !closable.isLoading }
        let panel = NSApplication.shared.windows.first { $0.title == "Choose Fortnite Window" && $0.isVisible }!
        panel.performClose(nil)
        precondition(callbacks == 2)
        print("PASS title-bar close resolves selection")
        print("All six window-picker regression checks passed.")
    }
}
"""#
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("fortsprite-picker-tests-" + UUID().uuidString)
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let input = temporary.appendingPathComponent("PickerChecks.swift")
let binary = temporary.appendingPathComponent("PickerChecks")
try harness.replacingOccurrences(of: "CONTROLLER", with: controller).write(to: input, atomically: true, encoding: .utf8)
func run(_ executable: URL, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
}
try run(URL(fileURLWithPath: "/usr/bin/xcrun"), ["swiftc", "-parse-as-library", "-swift-version", "5", input.path, "-o", binary.path])
try run(binary, [])
