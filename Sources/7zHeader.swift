// Copyright (c) 2017 Timofey Solomko
// Licensed under MIT License
//
// See LICENSE for license information

import Foundation

class SevenZipHeader {

    var archiveProperties: [SevenZipProperty]?
    var additionalStreams: SevenZipStreamInfo?
    var mainStreams: SevenZipStreamInfo?
    var fileInfo: SevenZipFileInfo?

    init(_ bitReader: BitReader) throws {
        var type = bitReader.byte()

        if type == 0x02 {
            archiveProperties = try SevenZipProperty.getProperties(bitReader)
            type = bitReader.byte()
        }

        if type == 0x03 {
            // TODO: Do we support this?
            // TODO: Or it can be more than one?
            throw SevenZipError.additionalStreamsNotSupported
//            additionalStreams = try SevenZipStreamInfo(bitReader)
//            type = bitReader.byte()
        }

        if type == 0x04 {
            mainStreams = try SevenZipStreamInfo(bitReader)
            type = bitReader.byte()
        }

        if type == 0x05 {
            fileInfo = try SevenZipFileInfo(bitReader)
            type = bitReader.byte()
        }

        if type != 0x00 {
            throw SevenZipError.wrongEnd
        }
    }

    convenience init(_ bitReader: BitReader, using streamInfo: SevenZipStreamInfo) throws {
        let folder = streamInfo.coderInfo.folders[0]
        guard let packInfo = streamInfo.packInfo
            else { throw SevenZipError.noPackInfo }

        let folderOffset = SevenZipContainer.signatureHeaderSize + packInfo.packPosition
        bitReader.index = folderOffset

        var packedHeaderEndIndex = -1

        var headerPointerData = BitReader(data: bitReader.data, bitOrder: .straight)
        headerPointerData.index = bitReader.index

        for coder in folder.orderedCoders() {
            guard coder.numInStreams == 1 || coder.numOutStreams == 1
                else { throw SevenZipError.multiStreamNotSupported }

            let unpackSize = folder.unpackSize(for: coder)

            let decodedData: Data
            // TODO: Copy filter.
            if coder.id == SevenZipCoder.ID.lzma2 {
                // Dictionary size is stored in coder's properties.
                guard let properties = coder.properties
                    else { throw SevenZipError.wrongCoderProperties }
                guard properties.count == 1
                    else { throw SevenZipError.wrongCoderProperties }

                decodedData = Data(bytes: try LZMA2.decompress(LZMA2.dictionarySize(properties[0]),
                                                               headerPointerData))
            } else if coder.id == SevenZipCoder.ID.lzma {
                // Both properties' byte (lp, lc, pb) and dictionary size are stored in coder's properties.
                guard let properties = coder.properties
                    else { throw SevenZipError.wrongCoderProperties }
                guard properties.count == 5
                    else { throw SevenZipError.wrongCoderProperties }

                let lzmaDecoder = try LZMADecoder(headerPointerData)

                var dictionarySize = 0
                for i in 1..<4 {
                    dictionarySize |= properties[i].toInt() << (8 * (i - 1))
                }

                try lzmaDecoder.decodeLZMA(unpackSize, properties[0], dictionarySize)
                decodedData = Data(bytes: lzmaDecoder.out)
            } else {
                throw SevenZipError.compressionNotSupported
            }

            guard decodedData.count == unpackSize
                else { throw SevenZipError.wrongDataSize }

            // Save header's data end index after first pass.
            // Necessary to calculate and check packed size later.
            if packedHeaderEndIndex == -1 {
                packedHeaderEndIndex = headerPointerData.index
            }

            headerPointerData = BitReader(data: decodedData, bitOrder: .straight)
        }

        guard packedHeaderEndIndex - bitReader.index == packInfo.packSizes[0]
            else { throw SevenZipError.wrongDataSize }
        guard headerPointerData.size == folder.unpackSize()
            else { throw SevenZipError.wrongDataSize }
        if let crc = folder.crc {
            guard CheckSums.crc32(headerPointerData.data) == crc
                else { throw SevenZipError.wrongCRC }
        }

        guard headerPointerData.byte() == 0x01
            else { throw SevenZipError.wrongPropertyID }
        try self.init(headerPointerData)
    }

}