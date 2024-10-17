//
// Subtitle.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/19/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import CoreGraphics
import Foundation

class Subtitle {
    var index: Int?
    var text: String?
    var startTimestamp: TimeInterval?
    var imageXOffset: Int?
    var imageYOffset: Int?
    var imageWidth: Int?
    var imageHeight: Int?
    var imageData: Data?
    var imagePalette: [UInt8]?
    var imageAlpha: [UInt8]?
    var numberOfColors: Int?
    var endTimestamp: TimeInterval?
    var evenOffset: Int?
    var oddOffset: Int?

    init(index: Int? = nil, text: String? = nil, startTimestamp: TimeInterval? = nil, endTimestamp: TimeInterval? = nil,
         imageXOffset: Int? = nil, imageYOffset: Int? = nil, imageWidth: Int? = nil, imageHeight: Int? = nil,
         imageData: Data? = nil, imagePalette: [UInt8]? = nil, imageAlpha: [UInt8]? = nil, numberOfColors: Int? = nil,
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
        self.numberOfColors = numberOfColors
        self.evenOffset = evenOffset
        self.oddOffset = oddOffset
    }

    // MARK: - Functions

    // Converts the RGBA data to a CGImage
    func createImage(_ invert: Bool) -> CGImage? {
        // Convert the image data to RGBA format using the palette
        let rgbaData = imageDataToRGBA()

        let bitmapInfo = CGBitmapInfo.byteOrder32Big
            .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let provider = CGDataProvider(data: rgbaData as CFData) else {
            return nil
        }

        let image = CGImage(width: imageWidth!,
                            height: imageHeight!,
                            bitsPerComponent: 8,
                            bitsPerPixel: 32,
                            bytesPerRow: imageWidth! * 4, // 4 bytes per pixel (RGBA)
                            space: colorSpace,
                            bitmapInfo: bitmapInfo,
                            provider: provider,
                            decode: nil,
                            shouldInterpolate: false,
                            intent: .defaultIntent)

        if !invert {
            return cropImageToVisibleArea(image!)!
        }
        return invertColors(of: cropImageToVisibleArea(image!)!)
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

                let paletteOffset = colorIndex * 4
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

    /// Crops the image to the visible (non-transparent) area and adds a buffer around it.
    /// - Parameter image: The original CGImage to crop.
    /// - Returns: A cropped CGImage, or nil if the image is fully transparent.
    private func cropImageToVisibleArea(_ image: CGImage) -> CGImage? {
        let buffer = 10 // Buffer size around the non-transparent area
        let width = image.width
        let height = image.height
        let newWidth = width + buffer * 2
        let newHeight = height + buffer * 2

        // Create a new image context with extended dimensions
        guard let context = CGContext(data: nil,
                                      width: newWidth,
                                      height: newHeight,
                                      bitsPerComponent: image.bitsPerComponent,
                                      bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: image.bitmapInfo.rawValue) else {
            return nil
        }

        // Clear the context (set a transparent background)
        context.clear(CGRect(x: 0, y: 0, width: newWidth, height: newHeight))

        // Draw the original image onto the new context at the center
        context.draw(image, in: CGRect(x: buffer, y: buffer, width: width, height: height))

        guard let extendedImage = context.makeImage(),
              let dataProvider = extendedImage.dataProvider,
              let data = dataProvider.data,
              let pixelData = CFDataGetBytePtr(data) else {
            return nil
        }

        let bytesPerPixel = extendedImage.bitsPerPixel / 8
        let bytesPerRow = extendedImage.bytesPerRow

        // Initialize variables to track the non-transparent bounds
        var minX = newWidth, maxX = 0, minY = newHeight, maxY = 0

        // Scan the image to find the non-transparent pixels
        for y in 0 ..< newHeight {
            for x in 0 ..< newWidth {
                let pixelIndex = y * bytesPerRow + x * bytesPerPixel
                let alpha = pixelData[pixelIndex + 3] // Assuming RGBA format

                if alpha > 0 { // Non-transparent pixel found
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }

        // If the image is fully transparent, return nil
        if minX == newWidth || maxX == 0 || minY == newHeight || maxY == 0 {
            return nil
        }

        // Apply buffer to the bounding box, ensuring it's within image bounds
        minX = max(0, minX - buffer)
        maxX = min(newWidth - 1, maxX + buffer)
        minY = max(0, minY - buffer)
        maxY = min(newHeight - 1, maxY + buffer)

        // Crop the image to the visible (non-transparent) area with the buffer
        let croppedRect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return extendedImage.cropping(to: croppedRect)
    }

    func invertColors(of image: CGImage) -> CGImage? {
        // Get the width, height, and color space of the image
        let width = image.width
        let height = image.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // Create a context with the same dimensions as the image
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }

        // Draw the image into the context
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Get the pixel data from the context
        guard let pixelBuffer = context.data else {
            return nil
        }

        let pixelData = pixelBuffer.bindMemory(to: UInt8.self, capacity: width * height * 4)

        // Iterate through the pixel data and invert the colors
        for y in 0 ..< height {
            for x in 0 ..< width {
                let pixelIndex = (y * width + x) * 4
                pixelData[pixelIndex] = 255 - pixelData[pixelIndex] // Red
                pixelData[pixelIndex + 1] = 255 - pixelData[pixelIndex + 1] // Green
                pixelData[pixelIndex + 2] = 255 - pixelData[pixelIndex + 2] // Blue
            }
        }

        // Create a new CGImage from the modified pixel data
        return context.makeImage()
    }
}
