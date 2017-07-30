// Copyright (c) 2017 Timofey Solomko
// Licensed under MIT License
//
// See LICENSE for license information

import Foundation

class SevenZipFolder {

    struct BindPair {

        let inIndex: Int
        let outIndex: Int

        init(_ bitReader: BitReader) throws {
            inIndex = bitReader.szMbd()
            outIndex = bitReader.szMbd()
        }

    }

    let numCoders: Int
    private(set) var coders = [SevenZipCoder]()

    let numBindPairs: Int
    private(set) var bindPairs = [BindPair]()

    let numPackedStreams: Int
    private(set) var packedStreams = [Int]()

    private(set) var totalOutputStreams = 0
    private(set) var totalInputStreams = 0

    // These properties are stored in CoderInfo.
    var crc: UInt32?
    var unpackSizes = [Int]()

    // This property is stored in SubstreamInfo.
    var numUnpackSubstreams = 1

    init(_ bitReader: BitReader) throws {
        numCoders = bitReader.szMbd()
        for _ in 0..<numCoders {
            let coder = try SevenZipCoder(bitReader)
            coders.append(coder)
            totalOutputStreams += coder.numOutStreams
            totalInputStreams += coder.numInStreams
        }

        guard totalOutputStreams != 0 else { throw SevenZipError.wrongStreamsNumber }

        numBindPairs = totalOutputStreams - 1
        if numBindPairs > 0 {
            for _ in 0..<numBindPairs {
                bindPairs.append(try BindPair(bitReader))
            }
        }

        guard totalInputStreams >= numBindPairs else { throw SevenZipError.wrongStreamsNumber }

        numPackedStreams = totalInputStreams - numBindPairs
        packedStreams = Array(repeating: 0, count: numPackedStreams)
        if numPackedStreams == 1 {
            var i = 0
            while i < totalInputStreams {
                if self.bindPairForInStream(i) < 0 {
                    break
                }
                i += 1
            }
            if i == totalInputStreams {
                throw SevenZipError.wrongStreamsNumber
            }
            packedStreams[0] = i
        } else {
            for i in 0..<numPackedStreams {
                packedStreams[i] = bitReader.szMbd()
            }
        }
    }

    func orderedCoders() -> [SevenZipCoder] {
        var result = [SevenZipCoder]()
        var current = 0
        while current != -1 {
            result.append(coders[current])
            let pair = bindPairForOutStream(current)
            current = pair != -1 ? bindPairs[pair].inIndex : -1
        }
        return result
    }

    func bindPairForInStream(_ index: Int) -> Int {
        for i in 0..<bindPairs.count {
            if bindPairs[i].inIndex == index {
                return i
            }
        }
        return -1
    }

    func bindPairForOutStream(_ index: Int) -> Int {
        for i in 0..<bindPairs.count {
            if bindPairs[i].outIndex == index {
                return i
            }
        }
        return -1
    }

    func unpackSize() -> Int {
         if totalOutputStreams == 0 {
             return 0
         }
        for i in stride(from: totalOutputStreams - 1, through: 0, by: -1) {
             if bindPairForOutStream(i) < 0 {
                 return unpackSizes[i]
             }
         }
         return 0
    }

    func unpackSize(for coder: SevenZipCoder) -> Int {
        for i in 0..<coders.count {
            if coders[i] == coder {
                return unpackSizes[i]
            }
        }
        return 0
    }

    func unpack(data: Data) throws -> Data {
        var decodedData = data
        for coder in self.orderedCoders() {
            guard coder.numInStreams == 1 || coder.numOutStreams == 1
                else { throw SevenZipError.multiStreamNotSupported }

            let unpackSize = self.unpackSize(for: coder)

            // TODO: Copy filter.
            if coder.id == SevenZipCoder.ID.lzma2 {
                // Dictionary size is stored in coder's properties.
                guard let properties = coder.properties
                    else { throw SevenZipError.wrongCoderProperties }
                guard properties.count == 1
                    else { throw SevenZipError.wrongCoderProperties }

                let pointerData = DataWithPointer(data: decodedData)
                decodedData = Data(bytes: try LZMA2.decompress(LZMA2.dictionarySize(properties[0]),
                                                               pointerData))
            } else if coder.id == SevenZipCoder.ID.lzma {
                // Both properties' byte (lp, lc, pb) and dictionary size are stored in coder's properties.
                guard let properties = coder.properties
                    else { throw SevenZipError.wrongCoderProperties }
                guard properties.count == 5
                    else { throw SevenZipError.wrongCoderProperties }

                let pointerData = DataWithPointer(data: decodedData)
                let lzmaDecoder = try LZMADecoder(pointerData)

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
        }
        return decodedData
    }

}