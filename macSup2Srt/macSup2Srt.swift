import ArgumentParser
import Cocoa
import Vision

var MODE = VNRequestTextRecognitionLevel.accurate

@main
struct macSup2Srt: ParsableCommand {
    @Argument(help: "Input .sup subtitle file.")
    var sup: String
    @Argument(help: "File to output the OCR direct output in json to.")
    var json: String
    @Argument(help: "File to output the completed .srt file to")
    var srt: String
    @Option(help: "Output image files of subtitles to directory (optional)")
    var imageDirectory: String
    @Option(wrappedValue: "en", help: "The input image language(s)")
    var language: String
    @Option(wrappedValue: false, help: "Enable fast mode (less accurate).")
    var fastmode: Bool
    @Option(wrappedValue: false, help: "Enable language correction.")
    var languageCorrection: Bool
    
    mutating func run() throws {
        var REVISION: Int
        if #available(macOS 13, *) {
            REVISION = VNRecognizeTextRequestRevision3
        } else {
            REVISION = VNRecognizeTextRequestRevision2
        }
        
        let substrings = language.split(separator: ",")
        var languages: [String] = []
        for substring in substrings {
            languages.append(String(substring))
        }
        if fastmode == true {
            MODE = VNRequestTextRecognitionLevel.fast
        }
        
        // Initialize the decoder
        let supDecoder = SupDecoder()
        let subtitles = try supDecoder.parseSup(
            fromFileAt: URL(fileURLWithPath: sup))
        
        // Iterate through the subtitles and extract bitmap data
        var num = 1
        var data: [Any] = []
        let decoder = SRT()
        var srtFile: [SrtSubtitle] = []
        
        for subtitle in subtitles {
            let outputDirectory = URL(fileURLWithPath: imageDirectory)
            //            let pgmPath = outputDirectory.appendingPathComponent("subtitle_\(num).pgm")
            let pngPath = outputDirectory.appendingPathComponent(
                "subtitle_\(num).png")
            
            try supDecoder.saveSubtitleAsPNG(
                imageData: subtitle.imageData, palette: subtitle.imagePalette,
                width: subtitle.imageSize.width,
                height: subtitle.imageSize.height, outputPath: pngPath)
            //            try supDecoder.saveAsPGM(imageData: subtitle.imageData, width: subtitle.imageSize.width, height: subtitle.imageSize.height, outputPath: pgmPath)
            
            let request = VNRecognizeTextRequest { (request, error) in
                let observations =
                request.results as? [VNRecognizedTextObservation] ?? []
                var dict: [String: Any] = [:]
                var lines: [Any] = []
                var allText = ""
                var index = 0
                for observation in observations {
                    // Find the top observation.
                    var line: [String: Any] = [:]
                    let candidate = observation.topCandidates(1).first
                    let string = candidate?.string
                    let confidence = candidate?.confidence
                    // Find the bounding-box observation for the string range.
                    let stringRange = string!.startIndex..<string!.endIndex
                    let boxObservation = try? candidate?.boundingBox(
                        for: stringRange)
                    
                    // Get the normalized CGRect value.
                    let boundingBox = boxObservation?.boundingBox ?? .zero
                    // Convert the rectangle from normalized coordinates to image coordinates.
                    let rect = VNImageRectForNormalizedRect(
                        boundingBox,
                        subtitle.imageSize.width,
                        subtitle.imageSize.height)
                    
                    line["text"] = string ?? ""
                    line["confidence"] = confidence ?? ""
                    line["x"] = Int(rect.minX)
                    line["width"] = Int(rect.size.width)
                    line["y"] = Int(
                        CGFloat(subtitle.imageSize.height) - rect.minY
                        - rect.size.height)
                    line["height"] = Int(rect.size.height)
                    lines.append(line)
                    allText = allText + (string ?? "")
                    index = index + 1
                    if index != observations.count {
                        allText = allText + "\n"
                    }
                }
                dict["image"] = num
                dict["lines"] = lines
                dict["text"] = allText
                data.append(dict)
                let newSubtitle = SrtSubtitle(
                    index: num,
                    startTime: subtitle.timestamp,
                    endTime: subtitle.endTimestamp,
                    text: allText)
                srtFile.append(newSubtitle)
            }
            request.recognitionLevel = MODE
            request.usesLanguageCorrection = languageCorrection
            request.revision = REVISION
            request.recognitionLanguages = languages
            //request.minimumTextHeight = 0
            //request.customWords = [String]
            try? VNImageRequestHandler(
                cgImage: supDecoder.createImage(
                    from: subtitle.imageData, palette: subtitle.imagePalette,
                    width: subtitle.imageSize.width,
                    height: subtitle.imageSize.height)!, options: [:]
            ).perform([
                request
            ])
            num += 1
        }
        let out = try? JSONSerialization.data(
            withJSONObject: data,
            options: [
                JSONSerialization.WritingOptions.prettyPrinted,
                JSONSerialization.WritingOptions.sortedKeys,
            ])
        let jsonString =
        String(
            data: out!,
            encoding: .utf8) ?? "[]"
        try? jsonString.write(
            to: URL(fileURLWithPath: json), atomically: true,
            encoding: String.Encoding.utf8)
        try decoder.encode(
            subtitles: srtFile, toFileAt: URL(fileURLWithPath: srt))
    }
}
