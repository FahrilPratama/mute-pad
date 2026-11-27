import Foundation

/// Represents a pointing HID device discovered via `IOHIDManager`.
struct HIDDeviceModel: Identifiable, Codable, Equatable, Hashable {
    /// Stable identifier based on VendorID and ProductID (`"0xVVVV:0xPPPP"`).
    var id: String {
        String(format: "0x%04X:0x%04X", vendorID, productID)
    }

    let vendorID: Int
    let productID: Int
    var productName: String
    var transport: String
    var isWhitelisted: Bool
    var isConnected: Bool
    var lastSeen: Date

    /// Human-readable hex identifier for display and debugging.
    var vidPidDisplay: String {
        String(format: "VID 0x%04X | PID 0x%04X", vendorID, productID)
    }

    /// Friendly transport label.
    var transportDisplay: String {
        let normalized = transport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "usb":
            return "USB / 2.4GHz"
        case "bluetooth":
            return "Bluetooth"
        case "bluetoothlowenergy", "bluetooth low energy":
            return "Bluetooth LE"
        case "", "virtual":
            return "Bluetooth / Wireless"
        default:
            return transport
        }
    }

    enum CodingKeys: String, CodingKey {
        case vendorID
        case productID
        case productName
        case transport
        case isWhitelisted
        case lastSeen
    }

    init(
        vendorID: Int,
        productID: Int,
        productName: String,
        transport: String,
        isWhitelisted: Bool = true,
        isConnected: Bool = false,
        lastSeen: Date = Date()
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.productName = productName
        self.transport = transport
        self.isWhitelisted = isWhitelisted
        self.isConnected = isConnected
        self.lastSeen = lastSeen
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vendorID = try container.decode(Int.self, forKey: .vendorID)
        productID = try container.decode(Int.self, forKey: .productID)
        productName = try container.decode(String.self, forKey: .productName)
        transport = try container.decode(String.self, forKey: .transport)
        isWhitelisted = try container.decode(Bool.self, forKey: .isWhitelisted)
        lastSeen = try container.decodeIfPresent(Date.self, forKey: .lastSeen) ?? Date()
        isConnected = false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(vendorID, forKey: .vendorID)
        try container.encode(productID, forKey: .productID)
        try container.encode(productName, forKey: .productName)
        try container.encode(transport, forKey: .transport)
        try container.encode(isWhitelisted, forKey: .isWhitelisted)
        try container.encode(lastSeen, forKey: .lastSeen)
    }
}
