import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import NotchAI

/// Offline unit tests for the capture module.
///
/// These tests never call ScreenCaptureKit and never trigger a TCC prompt. They cover the shared
/// exclusion policy, screenshot filename/format mapping, in-memory encoding with synthesized
/// `CGImage`s, display-resolution fallbacks, and atomic file writing.
final class CaptureTests: XCTestCase {
    // MARK: - Fixtures

    /// 2026-11-06 14:35:04 UTC.
    private let referenceDate = Date(timeIntervalSince1970: 1_793_975_704)
    /// 2026-01-02 03:04:05 UTC; single-digit components exercise zero padding.
    private let singleDigitDate = Date(timeIntervalSince1970: 1_767_323_045)
    private let referenceUUIDString = "ABCDEF01-2345-6789-ABCD-EF0123456789"

    private let ourPID: pid_t = 4242
    private let islandWindowNumber: CGWindowID = 9001

    private var scratchDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchAI-CaptureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scratchDirectory = directory
    }

    override func tearDownWithError() throws {
        if let directory = scratchDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
        scratchDirectory = nil
        try super.tearDownWithError()
    }

    private func utcTimeZone() throws -> TimeZone {
        try XCTUnwrap(TimeZone(secondsFromGMT: 0))
    }

    private func uuid(_ string: String) throws -> UUID {
        try XCTUnwrap(UUID(uuidString: string))
    }

    private func makeTestImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func decodeImage(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    // MARK: - CaptureFilterLogic (shared exclusion policy)

    private func windowInfo(_ number: CGWindowID, pid: pid_t) -> CaptureFilterLogic.WindowInfo {
        CaptureFilterLogic.WindowInfo(windowNumber: number, ownerPID: pid)
    }

    private func exclusions(
        excludeAllOwnedWindows: Bool,
        windows: [CaptureFilterLogic.WindowInfo]
    ) -> [CGWindowID] {
        CaptureFilterLogic.exclusions(
            ourPID: ourPID,
            islandWindowNumber: islandWindowNumber,
            excludeAllOwnedWindows: excludeAllOwnedWindows,
            windows: windows
        )
    }

    func testIslandOnlyExcludedByDefault() {
        let windows = [
            windowInfo(islandWindowNumber, pid: ourPID),
            windowInfo(9002, pid: ourPID), // detached chat/browser window owned by this app
            windowInfo(7001, pid: 501), // another application
        ]
        XCTAssertEqual(
            exclusions(excludeAllOwnedWindows: false, windows: windows),
            [islandWindowNumber]
        )
    }

    func testAllOwnedWindowsExcludedWhenRequested() {
        let windows = [
            windowInfo(9003, pid: ourPID),
            windowInfo(islandWindowNumber, pid: ourPID),
            windowInfo(9002, pid: ourPID),
            windowInfo(7001, pid: 501),
            windowInfo(7002, pid: 502),
        ]
        XCTAssertEqual(
            exclusions(excludeAllOwnedWindows: true, windows: windows),
            [9001, 9002, 9003]
        )
    }

    func testOtherApplicationsWindowsAreNeverExcluded() {
        let windows = [windowInfo(7001, pid: 501), windowInfo(7002, pid: 502)]
        XCTAssertEqual(exclusions(excludeAllOwnedWindows: false, windows: windows), [])
        XCTAssertEqual(exclusions(excludeAllOwnedWindows: true, windows: windows), [])
    }

    func testWindowsWithoutAnOwningApplicationAreNotTreatedAsOurs() {
        // ScreenshotService maps `owningApplication == nil` to PID 0.
        let windows = [windowInfo(7003, pid: 0)]
        XCTAssertEqual(exclusions(excludeAllOwnedWindows: true, windows: windows), [])
    }

    func testExclusionsAreSortedAscending() {
        let windows = [
            windowInfo(9005, pid: ourPID),
            windowInfo(9002, pid: ourPID),
            windowInfo(islandWindowNumber, pid: ourPID),
            windowInfo(9004, pid: ourPID),
        ]
        XCTAssertEqual(
            exclusions(excludeAllOwnedWindows: true, windows: windows),
            [9001, 9002, 9004, 9005]
        )
    }

    func testDuplicateWindowNumbersArePassedThroughBySharedPolicy() {
        // Documented behavior of the shared policy: it filters and sorts, it does NOT de-duplicate.
        // ScreenCaptureKit reports unique window numbers, and ScreenshotService de-duplicates while
        // mapping numbers back to SCWindows, so a duplicate never reaches SCContentFilter.
        let windows = [
            windowInfo(islandWindowNumber, pid: ourPID),
            windowInfo(islandWindowNumber, pid: ourPID),
        ]
        XCTAssertEqual(
            exclusions(excludeAllOwnedWindows: false, windows: windows),
            [islandWindowNumber, islandWindowNumber]
        )
    }

    func testIslandWindowOnlyExcludedWhenPresentInEnumeratedWindows() {
        // Documented behavior: the shared policy can only exclude window numbers it is given, it does
        // not synthesize the island window. ScreenshotService builds the list from
        // `SCShareableContent.windows`, which contains the island panel while it is on screen, so the
        // live path always excludes it. When the panel is absent from enumeration (for example before
        // it exists) there is nothing to exclude.
        let windows = [windowInfo(9002, pid: ourPID)]
        XCTAssertEqual(exclusions(excludeAllOwnedWindows: false, windows: windows), [])
        XCTAssertEqual(exclusions(excludeAllOwnedWindows: true, windows: windows), [9002])
    }

    func testEmptyWindowListProducesNoExclusions() {
        XCTAssertEqual(exclusions(excludeAllOwnedWindows: true, windows: []), [])
    }

    // MARK: - ScreenshotFilename

    private func makeFilename(format: ScreenshotFormat = .png) throws -> ScreenshotFilename {
        ScreenshotFilename.make(
            date: referenceDate,
            id: try uuid(referenceUUIDString),
            format: format,
            timeZone: try utcTimeZone()
        )
    }

    func testFileExtensionMatchesFormat() {
        XCTAssertEqual(ScreenshotFilename.fileExtension(for: .png), "png")
        XCTAssertEqual(ScreenshotFilename.fileExtension(for: .jpeg), "jpeg")
    }

    func testTimestampIsDeterministicInUTC() throws {
        XCTAssertEqual(
            ScreenshotFilename.timestamp(for: referenceDate, timeZone: try utcTimeZone()),
            "20261106-143504"
        )
    }

    func testTimestampPadsSingleDigitComponents() throws {
        XCTAssertEqual(
            ScreenshotFilename.timestamp(for: singleDigitDate, timeZone: try utcTimeZone()),
            "20260102-030405"
        )
    }

    func testTimestampRespectsProvidedTimeZone() throws {
        let plusOneHour = try XCTUnwrap(TimeZone(secondsFromGMT: 3600))
        XCTAssertEqual(
            ScreenshotFilename.timestamp(for: referenceDate, timeZone: plusOneHour),
            "20261106-153504"
        )
    }

    func testShortIdentifierIsFirstEightLowercaseCharacters() throws {
        XCTAssertEqual(ScreenshotFilename.shortIdentifier(for: try uuid(referenceUUIDString)), "abcdef01")
    }

    func testFilenameShape() throws {
        let filename = try makeFilename()
        XCTAssertEqual(filename.fileName, "Screenshot-20261106-143504-abcdef01.png")
        XCTAssertEqual(filename.stem, "Screenshot-20261106-143504-abcdef01")
        XCTAssertEqual(filename.fileExtension, "png")
    }

    func testFormatChangeOnlyChangesExtension() throws {
        let png = try makeFilename(format: .png)
        let jpeg = try makeFilename(format: .jpeg)
        XCTAssertNotEqual(png.fileName, jpeg.fileName)
        XCTAssertEqual(png.stem, jpeg.stem)
        XCTAssertTrue(jpeg.fileName.hasSuffix(".jpeg"))
    }

    func testDifferentDateOrIdentifierProducesDifferentFilename() throws {
        let id = try uuid(referenceUUIDString)
        let otherID = try uuid("11111111-2222-3333-4444-555555555555")
        let timeZone = try utcTimeZone()
        let baseline = ScreenshotFilename.make(date: referenceDate, id: id, format: .png, timeZone: timeZone)
        let later = ScreenshotFilename.make(
            date: referenceDate.addingTimeInterval(1),
            id: id,
            format: .png,
            timeZone: timeZone
        )
        let differentID = ScreenshotFilename.make(date: referenceDate, id: otherID, format: .png, timeZone: timeZone)
        XCTAssertNotEqual(baseline.stem, later.stem)
        XCTAssertNotEqual(baseline.stem, differentID.stem)
    }

    func testFilenameHasNoPathSeparatorsOrSpaces() throws {
        for format in ScreenshotFormat.allCases {
            let filename = try makeFilename(format: format)
            XCTAssertFalse(filename.fileName.contains("/"))
            XCTAssertFalse(filename.fileName.contains(" "))
            XCTAssertFalse(filename.fileName.contains(":"))
        }
    }

    // MARK: - ScreenshotEncoding

    func testFormatMapsToExpectedUTType() {
        XCTAssertEqual(ScreenshotEncoding.utType(for: .png).identifier, UTType.png.identifier)
        XCTAssertEqual(ScreenshotEncoding.utType(for: .jpeg).identifier, UTType.jpeg.identifier)
        XCTAssertTrue(ScreenshotEncoding.utType(for: .png).conforms(to: .image))
        XCTAssertTrue(ScreenshotEncoding.utType(for: .jpeg).conforms(to: .image))
    }

    func testPNGEncodingProducesDecodablePNG() throws {
        let image = try makeTestImage(width: 8, height: 6)
        let data = try ScreenshotEncoding.data(for: image, format: .png)
        XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let decoded = try decodeImage(data)
        XCTAssertEqual(decoded.width, 8)
        XCTAssertEqual(decoded.height, 6)
    }

    func testJPEGEncodingProducesDecodableJPEG() throws {
        let image = try makeTestImage(width: 8, height: 6)
        let data = try ScreenshotEncoding.data(for: image, format: .jpeg)
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
        let decoded = try decodeImage(data)
        XCTAssertEqual(decoded.width, 8)
        XCTAssertEqual(decoded.height, 6)
    }

    func testEncodingPreservesPixelDimensionsForBothFormats() throws {
        for format in ScreenshotFormat.allCases {
            let image = try makeTestImage(width: 13, height: 7)
            let data = try ScreenshotEncoding.data(for: image, format: format)
            XCTAssertFalse(data.isEmpty, "\(format) encoding should not be empty")
            let decoded = try decodeImage(data)
            XCTAssertEqual(decoded.width, 13)
            XCTAssertEqual(decoded.height, 7)
        }
    }

    func testJPEGQualityIsNinetyPercent() {
        XCTAssertEqual(ScreenshotEncoding.jpegCompressionQuality, 0.9, accuracy: 0.0001)
    }

    // MARK: - CaptureOptions defaults

    func testCaptureOptionsDefaults() {
        let options = CaptureOptions()
        XCTAssertNil(options.displayID)
        XCTAssertEqual(options.format, .png)
        XCTAssertFalse(options.saveLocally)
        XCTAssertFalse(options.excludeAllAppWindows)
        XCTAssertFalse(options.includeCursor)
    }

    func testCaptureOptionsReflectOverrides() throws {
        var options = CaptureOptions()
        options.displayID = 42
        options.format = .jpeg
        options.saveLocally = true
        options.excludeAllAppWindows = true
        options.includeCursor = true
        XCTAssertEqual(try XCTUnwrap(options.displayID), 42)
        XCTAssertEqual(options.format, .jpeg)
        XCTAssertTrue(options.saveLocally)
        XCTAssertTrue(options.excludeAllAppWindows)
        XCTAssertTrue(options.includeCursor)
    }

    // MARK: - Display resolution and native pixel sizing

    func testRequestedDisplayIsUsedWhenAvailable() {
        XCTAssertEqual(
            CaptureDisplayResolver.resolve(requested: 7, available: [1, 7], mainDisplayID: 1),
            .exact(7)
        )
    }

    func testNilRequestFallsBackToMainDisplay() {
        XCTAssertEqual(
            CaptureDisplayResolver.resolve(requested: nil, available: [1, 7], mainDisplayID: 7),
            .fallbackToMain(7)
        )
    }

    func testUnknownRequestFallsBackToMainDisplay() {
        XCTAssertEqual(
            CaptureDisplayResolver.resolve(requested: 9, available: [1, 7], mainDisplayID: 7),
            .fallbackToMain(7)
        )
    }

    func testNoAvailableDisplaysIsUnavailable() {
        XCTAssertEqual(
            CaptureDisplayResolver.resolve(requested: nil, available: [], mainDisplayID: 1),
            .unavailable
        )
    }

    func testMissingMainDisplayIsUnavailable() {
        // Documents the product rule: never silently capture a display the user did not request;
        // report that no display matches instead.
        XCTAssertEqual(
            CaptureDisplayResolver.resolve(requested: 9, available: [7, 8], mainDisplayID: 1),
            .unavailable
        )
    }

    func testNativePixelSizePrefersFramebufferPixels() {
        XCTAssertEqual(
            CaptureDisplayResolver.nativePixelSize(
                displayPixelWidth: 3024,
                displayPixelHeight: 1964,
                pointWidth: 1512,
                pointHeight: 982,
                backingScaleFactor: 2
            ),
            CapturePixelSize(width: 3024, height: 1964)
        )
    }

    func testNativePixelSizeFallsBackToPointsTimesBackingScale() {
        XCTAssertEqual(
            CaptureDisplayResolver.nativePixelSize(
                displayPixelWidth: 0,
                displayPixelHeight: 0,
                pointWidth: 1512,
                pointHeight: 982,
                backingScaleFactor: 2
            ),
            CapturePixelSize(width: 3024, height: 1964)
        )
        // Fractional scales round to the nearest pixel.
        XCTAssertEqual(
            CaptureDisplayResolver.nativePixelSize(
                displayPixelWidth: 0,
                displayPixelHeight: 0,
                pointWidth: 101,
                pointHeight: 51,
                backingScaleFactor: 1.5
            ),
            CapturePixelSize(width: 152, height: 77)
        )
    }

    func testNativePixelSizeRejectsDegenerateInput() {
        XCTAssertNil(CaptureDisplayResolver.nativePixelSize(
            displayPixelWidth: 0,
            displayPixelHeight: 0,
            pointWidth: 0,
            pointHeight: 0,
            backingScaleFactor: 2
        ))
        XCTAssertNil(CaptureDisplayResolver.nativePixelSize(
            displayPixelWidth: 0,
            displayPixelHeight: 0,
            pointWidth: 100,
            pointHeight: 100,
            backingScaleFactor: 0
        ))
        XCTAssertNil(CaptureDisplayResolver.nativePixelSize(
            displayPixelWidth: 0,
            displayPixelHeight: 0,
            pointWidth: 100,
            pointHeight: 100,
            backingScaleFactor: .nan
        ))
        XCTAssertNil(CaptureDisplayResolver.nativePixelSize(
            displayPixelWidth: -1,
            displayPixelHeight: -1,
            pointWidth: -100,
            pointHeight: 100,
            backingScaleFactor: 2
        ))
    }

    // MARK: - Screenshot file writer

    func testWriterCreatesDirectoryAndWritesAtomically() throws {
        let filename = try makeFilename()
        let directory = scratchDirectory.appendingPathComponent("nested/Screenshots", isDirectory: true)
        let data = Data([0x01, 0x02, 0x03, 0x04])

        let fileURL = try ScreenshotFileWriter.write(data, filename: filename, in: directory)

        XCTAssertEqual(fileURL, directory.appendingPathComponent(filename.fileName))
        XCTAssertEqual(try Data(contentsOf: fileURL), data)
        // The atomic write must not leave a temporary sibling behind.
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            [filename.fileName]
        )
    }

    func testWriterReplacesExistingFile() throws {
        let filename = try makeFilename()
        let directory = scratchDirectory.appendingPathComponent("Screenshots", isDirectory: true)
        try ScreenshotFileWriter.write(Data([0x01]), filename: filename, in: directory)

        let replacement = Data([0x0A, 0x0B])
        let fileURL = try ScreenshotFileWriter.write(replacement, filename: filename, in: directory)

        XCTAssertEqual(try Data(contentsOf: fileURL), replacement)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            [filename.fileName]
        )
    }
}
