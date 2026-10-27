import Foundation

/// PLNS v1 wire protocol shared with the Android prototype
/// (`app/.../usb/StreamProtocol.kt`) and `receiver-core` (C++ parser).
/// All multi-byte fields are big-endian; payloads are raw H.264 Annex-B.
enum StreamProtocol {
    static let magic: UInt32 = 0x504C_4E53 // "PLNS"
    static let version: UInt16 = 1
    static let headerBytes = 24
    static let flagKeyFrame: UInt8 = 0x01
    static let maxPayloadBytes = 8 * 1024 * 1024

    enum Kind: UInt8 {
        case config = 1
        case accessUnit = 2
        case keepAlive = 3
    }

    struct Packet {
        let kind: Kind
        let keyFrame: Bool
        let sequence: Int32
        let presentationTimeUs: Int64
        let payload: Data

        init(kind: Kind, keyFrame: Bool = false, sequence: Int32 = 0,
             presentationTimeUs: Int64 = 0, payload: Data = Data()) {
            self.kind = kind
            self.keyFrame = keyFrame
            self.sequence = sequence
            self.presentationTimeUs = presentationTimeUs
            self.payload = payload
        }
    }

    static func encode(_ packet: Packet) -> Data {
        var data = Data(capacity: headerBytes + packet.payload.count)
        appendUInt32(&data, magic)
        appendUInt16(&data, version)
        data.append(packet.kind.rawValue)
        data.append(packet.keyFrame ? flagKeyFrame : 0)
        appendUInt32(&data, UInt32(bitPattern: packet.sequence))
        appendUInt64(&data, UInt64(bitPattern: packet.presentationTimeUs))
        appendUInt32(&data, UInt32(packet.payload.count))
        data.append(packet.payload)
        return data
    }

    static func annexBStartCode() -> [UInt8] { [0x00, 0x00, 0x00, 0x01] }

    /// Splits an Annex-B byte stream into raw NAL units (start codes removed).
    static func splitAnnexB(_ data: Data) -> [Data] {
        var units: [Data] = []
        var current = Data()
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            if i + 3 < bytes.count, bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                if !current.isEmpty { units.append(current); current = Data() }
                i += 3
            } else if i + 4 <= bytes.count, bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                if !current.isEmpty { units.append(current); current = Data() }
                i += 4
            } else {
                current.append(bytes[i])
                i += 1
            }
        }
        if !current.isEmpty { units.append(current) }
        return units.filter { !$0.isEmpty }
    }

    /// Joins raw NAL units back into an Annex-B stream.
    static func joinAnnexB(_ units: [Data]) -> Data {
        var data = Data()
        for unit in units {
            data.append(contentsOf: annexBStartCode())
            data.append(unit)
        }
        return data
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var v = value.bigEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        var v = value.bigEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func appendUInt64(_ data: inout Data, _ value: UInt64) {
        var v = value.bigEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
}
