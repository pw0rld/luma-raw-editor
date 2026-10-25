import Foundation
import LumaCore

// A tiny XCTest-compatible runner so the same assertions can run with CLT alone.
class XCTestCase {}
var assertionCount = 0
func XCTFail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    fatalError(message, file: (file), line: line)
}
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    assertionCount += 1
    do { let lhs = try a(), rhs = try b(); if lhs != rhs { XCTFail("Expected \(lhs) == \(rhs)", file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertTrue(_ a: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(a, true, file: file, line: line) }
func XCTAssertFalse(_ a: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(a, false, file: file, line: line) }
func XCTAssertNil<T>(_ a: T?, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(a == nil, file: file, line: line) }
func XCTAssertNotNil<T>(_ a: T?, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(a != nil, file: file, line: line) }
func XCTAssertLessThan<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(a < b, file: file, line: line) }
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    assertionCount += 1
    do { _ = try expression(); XCTFail("Expected an error", file: file, line: line) } catch { }
}
@main struct CheckMain {
    static func main() async throws {
        let suite = LumaCoreTests()
        try suite.testRecipeRoundTripAndRejection()
        try suite.testLocalMaskRecipeValidationAndLegacyDefaults()
        suite.testHistoryBranchingAndBound()
        let stability = StabilityTests()
        try stability.testMaskAndCropRotationPreservesContent()
        stability.testLinearCoverageOpacityAndFeatherGeometry()
        try stability.testV3RecipeAndV2Migration()
        try stability.testGlobalClusterAssignmentAndLegacyPreservation()
        try await stability.testAtomicDraftRoundTripAndCorruptRejection()
        let match = ColorMatchTests()
        try match.testLabConversionDeterministicAnalysisAndIdentity()
        try match.testIndependentStrengthsToneMonotonicityAndFlatProtection()
        try match.testMatchValidationRecipeMigrationAndHistory()
        if CommandLine.arguments.contains("--non-render") {
            print("PASS: \(assertionCount) non-render assertions; pixel rendering explicitly excluded")
            return
        }
        try await suite.testPipelineOrientationMetadataAndOriginalProtection()
        try await suite.testLocalMaskChangesOnlyMaskedRenderAndCanBeDisabled()
        try await suite.testRAWFixtureIfProvided()
        let pixels = MaskPixelTests()
        try await pixels.testLocalCoverageAndLinearOpacity()
        try await pixels.testLinearRotationOverlayAndExport()
        try await pixels.testTightCropRetainsEnoughAnalysisSamples()
        try await pixels.testRAWMaskExportIfProvided()
        try await match.testMatchedBitmapPipelineAndEmbeddedRecipe()
        try await match.testMatchedRAWPipelineIfProvided()
        try await match.testCustomCropAndLegacyRecipeMigration()
        print("PASS: \(assertionCount) assertions; recipe/history/orientation/masks/color/metadata/export/source protection/reference matching")
    }
}
