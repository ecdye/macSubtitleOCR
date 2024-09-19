import Testing
import Foundation
@testable import macSubtitleOCR

@Suite struct macSubtitleOCRTests {
    @Test func testMKV() throws {
        // Setup files
        let manager = FileManager.default
        let srtPath = (manager.temporaryDirectory.path + "/test.srt")
        let jsonPath = (manager.temporaryDirectory.path + "/test.json")
        let mkvPath = Bundle.module.url(forResource: "test.mkv", withExtension: nil)!.absoluteString.replacing("file://", with: "")
        let goodSRTPath = Bundle.module.url(forResource: "test.srt", withExtension: nil)!.absoluteString.replacing("file://", with: "")
        let goodJSONPath = Bundle.module.url(forResource: "test.json", withExtension: nil)!.absoluteString.replacing("file://", with: "")
        
        // Run tests
        let options = [mkvPath, srtPath, "--language-correction", "--json", jsonPath]
        var runner = try macSubtitleOCR.parseAsRoot(options)
        try runner.run()
        
        // Compare output
        let expectedOCROutput = try String(contentsOfFile: goodSRTPath, encoding: .utf8)
        let actualOCROutput = try String(contentsOfFile: srtPath, encoding: .utf8)
        let expectedJSONOutput = try String(contentsOfFile: goodJSONPath, encoding: .utf8)
        let actualJSONOutput = try String(contentsOfFile: jsonPath, encoding: .utf8)
        #expect(expectedOCROutput == actualOCROutput)
        #expect(expectedJSONOutput == actualJSONOutput)
    }
}

