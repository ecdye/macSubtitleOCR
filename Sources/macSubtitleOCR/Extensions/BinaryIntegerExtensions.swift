

extension BinaryInteger {
    /// Returns a formatted hexadecimal string with `0x` prefix.
    func hex() -> String {
        String(format: "0x%0\(MemoryLayout<Self>.size)X", self as! CVarArg)
    }
}
