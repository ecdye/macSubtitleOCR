//
// Subtitle.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/19/24.
// Copyright © 2024-2025 Ethan Dye. All rights reserved.
//

import CoreGraphics
import Foundation

class Subtitle: @unchecked Sendable {
    var index: Int
    var text: String?
    var startTimestamp: TimeInterval?
    var imageXOffset: Int?
    var imageYOffset: Int?
    var imageWidth: Int?
    var imageHeight: Int?
    var imageData: Data?
    var imagePalette: [UInt8]?
    var imageAlpha: [UInt8]?
    var image: CGImage?
    var numberOfColors: Int?
    var endTimestamp: TimeInterval?
    var evenOffset: Int?
    var oddOffset: Int?

    init(index: Int, text: String? = nil, startTimestamp: TimeInterval? = nil, endTimestamp: TimeInterval? = nil,
         imageXOffset: Int? = nil, imageYOffset: Int? = nil, imageWidth: Int? = nil, imageHeight: Int? = nil,
         imageData: Data? = nil, imagePalette: [UInt8]? = nil, imageAlpha: [UInt8]? = nil, image: CGImage? = nil,
         numberOfColors: Int? = nil,
         evenOffset: Int? = nil, oddOffset: Int? = nil) {
        self.index = index
        self.text = text
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp
        self.imageXOffset = imageXOffset
        self.imageYOffset = imageYOffset
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.imageData = imageData
        self.imagePalette = imagePalette
        self.imageAlpha = imageAlpha
        self.image = image
        self.numberOfColors = numberOfColors
        self.evenOffset = evenOffset
        self.oddOffset = oddOffset
    }

    // MARK: - Functions

    // Converts the RGBA data to a CGImage
    func createImage(_ invert: Bool) -> CGImage? {
        if image != nil {
            return image
        }
        var rgbaData = imageDataToRGBA()

        var minX = imageWidth!, maxX = 0, minY = imageHeight!, maxY = 0
        for y in 0 ..< imageHeight! {
            for x in 0 ..< imageWidth! {
                let pixelIndex = (y * imageWidth! + x) * 4
                let alpha = rgbaData[pixelIndex + 3]
                if alpha > 0 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                    if !invert {
                        rgbaData[pixelIndex] = 255 - rgbaData[pixelIndex]
                        rgbaData[pixelIndex + 1] = 255 - rgbaData[pixelIndex + 1]
                        rgbaData[pixelIndex + 2] = 255 - rgbaData[pixelIndex + 2]
                    }
                } else {
                    // Set transparent pixels to white
                    rgbaData[pixelIndex] = 255
                    rgbaData[pixelIndex + 1] = 255
                    rgbaData[pixelIndex + 2] = 255
                    rgbaData[pixelIndex + 3] = 255
                }
            }
        }

        guard let provider = CGDataProvider(data: rgbaData as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo.byteOrder32Big
            .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        let image = CGImage(
            width: imageWidth!,
            height: imageHeight!,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: imageWidth! * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent)

        if minX == imageWidth! || maxX == 0 || minY == imageHeight! || maxY == 0 {
            return nil
        }
        let croppedRect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return image?.cropping(to: croppedRect)
    }

    // MARK: - Methods

    // Converts the image data to RGBA format using the palette
    private func imageDataToRGBA() -> Data {
        let bytesPerPixel = 4
        imageHeight = imageData!.count / imageWidth!
        var rgbaData = Data(capacity: imageWidth! * imageHeight! * bytesPerPixel)

        for y in 0 ..< imageHeight! {
            for x in 0 ..< imageWidth! {
                let index = Int(y) * imageWidth! + Int(x)
                let colorIndex = Int(imageData![index])

                guard colorIndex < numberOfColors! else {
                    continue
                }

                let paletteOffset = colorIndex * bytesPerPixel
                rgbaData.append(contentsOf: [
                    imagePalette![paletteOffset],
                    imagePalette![paletteOffset + 1],
                    imagePalette![paletteOffset + 2],
                    imagePalette![paletteOffset + 3]
                ])
            }
        }

        return rgbaData
    }
}
