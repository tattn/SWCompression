// Copyright (c) 2017 Timofey Solomko
// Licensed under MIT License
//
// See LICENSE for license information

import Foundation

class SevenZipFileInfo {

    struct File {
        var isEmptyStream = false
        var isEmptyFile = false
        var isAntiFile = false
        var name: String?
        var cTime: UInt64?
        var mTime: UInt64?
        var aTime: UInt64?
        var winAttributes: UInt32?
    }

    let numFiles: Int
    var files = [File]()

    init(_ bitReader: BitReader) throws {
        numFiles = bitReader.szMbd()
        for _ in 0..<numFiles {
            files.append(File())
        }

        var isEmptyStream: [UInt8]?
        var isEmptyFile: [UInt8]?
        var isAntiFile: [UInt8]?

        while true {
            let propertyType = bitReader.byte()
            if propertyType == 0 {
                break
            }
            let propertySize = bitReader.szMbd()
            switch propertyType {
            case 0x0E: // EmptyStream
                isEmptyStream = bitReader.bits(count: numFiles)
                bitReader.skipUntilNextByte()
            case 0x0F: // EmptyFile
                guard let emptyStreamCount = isEmptyStream?.reduce(0, { $0 + $1})
                    else { throw SevenZipError.wrongFileProperty }
                isEmptyFile = bitReader.bits(count: emptyStreamCount.toInt())
                bitReader.skipUntilNextByte()
            case 0x10: // AntiFile (used in backups to indicate that file was removed)
                guard let emptyStreamCount = isEmptyStream?.reduce(0, { $0 + $1})
                    else { throw SevenZipError.wrongFileProperty }
                isAntiFile = bitReader.bits(count: emptyStreamCount.toInt())
                bitReader.skipUntilNextByte()
            case 0x11: // File name
                let external = bitReader.byte()
                guard external == 0
                    else { throw SevenZipError.externalNotSupported } // TODO: Do we support this?
                guard (propertySize - 1) & 1 == 0
                    else { throw SevenZipError.wrongFileNameLength }
                let names = bitReader.bytes(count: propertySize - 1)
                var nextFile = 0
                var nextName = 0
                for i in stride(from: 0, to: names.count, by: 2) { // TODO: Understand what is going on here.
                    if names[i] == 0 && names[i + 1] == 0 {
                        files[nextFile].name = String(data: Data(bytes: names[nextName..<i]),
                                                      encoding: .utf16LittleEndian)
                        nextName = i + 2
                        nextFile += 1
                    }
                }
                guard nextName == names.count && nextFile == numFiles
                    else { throw SevenZipError.wrongFileNames }
            case 0x12: // Creation time
                let timesDefined = bitReader.defBits(count: numFiles)
                bitReader.skipUntilNextByte()

                // TODO: Remove implicit call of skipUntilNextByte() in BitReader,
                // instead make it check if bytes are aligned.

                let external = bitReader.byte()
                guard external == 0
                    else { throw SevenZipError.externalNotSupported } // TODO: Do we support this?

                for i in 0..<numFiles {
                    if timesDefined[i] == 1 {
                        files[i].cTime = bitReader.uint64()
                    }
                }
            case 0x13: // Access time
                let timesDefined = bitReader.defBits(count: numFiles)
                bitReader.skipUntilNextByte()

                let external = bitReader.byte()
                guard external == 0
                    else { throw SevenZipError.externalNotSupported } // TODO: Do we support this?

                for i in 0..<numFiles {
                    if timesDefined[i] == 1 {
                        files[i].aTime = bitReader.uint64()
                    }
                }
            case 0x14: // Modification time
                let timesDefined = bitReader.defBits(count: numFiles)
                bitReader.skipUntilNextByte()

                let external = bitReader.byte()
                guard external == 0
                    else { throw SevenZipError.externalNotSupported } // TODO: Do we support this?

                for i in 0..<numFiles {
                    if timesDefined[i] == 1 {
                        files[i].mTime = bitReader.uint64()
                    }
                }
            case 0x15: // WinAttributes
                let attributesDefined = bitReader.defBits(count: numFiles)
                bitReader.skipUntilNextByte()

                let external = bitReader.byte()
                guard external == 0
                    else { throw SevenZipError.externalNotSupported } // TODO: Do we support this?

                for i in 0..<numFiles {
                    if attributesDefined[i] == 1 {
                        files[i].winAttributes = bitReader.uint32()
                    }
                }
            case 0x18: // StartPos // TODO: Do we support this?
                throw SevenZipError.startPosNotSupported
            case 0x19: // "Dummy". Used for alignment.
                guard bitReader.size - bitReader.index >= propertySize
                    else { throw SevenZipError.incompleteProperty }
                bitReader.index += propertySize
            default: // Unknown property // TODO: Maybe we should store it for testing.
                guard bitReader.size - bitReader.index >= propertySize
                    else { throw SevenZipError.incompleteProperty }
                bitReader.index += propertySize
            }
        }

        var emptyFileIndex = 0
        for i in 0..<numFiles {
            files[i].isEmptyStream = isEmptyStream?[i] == 1
            if files[i].isEmptyStream {
                files[i].isEmptyFile = isEmptyFile?[emptyFileIndex] == 1
                files[i].isAntiFile = isAntiFile?[emptyFileIndex] == 1
                emptyFileIndex += 1
            }
        }
    }

}