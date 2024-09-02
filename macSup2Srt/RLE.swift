import Foundation

func isColor(byte: UInt8) -> Bool {
    return byte >> 7 == 1
}

func isLong(byte: UInt8) -> Bool {
    return (byte >> 6) & 0b1 == 1
}

func decodeRLE<T: DataProtocol>(data: T) -> [UInt8] {
    let data = Array(data)
    let dataLen = UInt64(data.count)
    var cursor = 0
    var output: [UInt8] = []
    
    while cursor < dataLen {
        if cursor >= dataLen {
            break
        }
        
        // check first byte color
        switch data[cursor] {
        case 0x00:
            break
        default:
            output.append(1)
            cursor += 1
            continue
        }
        
        // check second byte for length
        let info = data[cursor + 1]
        switch info {
        case 0x00:
            cursor += 2
            continue
        default:
            break
        }
        
        let isColor = isColor(byte: info)
        let bigLen = isLong(byte: info)
        
        let lenU8 = info & 0b0011_1111
        assert(lenU8 >> 6 == 0)
        
        let len: UInt16
        if bigLen {
            let len2U8 = data[cursor + 2]
            let buf: [UInt8] = [lenU8, len2U8]
            len = UInt16(
                bigEndian: Data(buf).withUnsafeBytes {
                    $0.load(as: UInt16.self)
                })
            cursor += 3
        } else {
            len = UInt16(lenU8)
            cursor += 2
        }
        
        let color: UInt8
        if isColor {
            color = data[cursor]
            cursor += 1
        } else {
            // use preferred color
            color = 0
        }
        
        for _ in 0..<len {
            output.append(color)
        }
    }
    
    return output
}
