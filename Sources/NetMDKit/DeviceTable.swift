import Foundation

public struct DeviceDefinition {
    public let vendorId: UInt16
    public let productId: UInt16
    public let name: String
    public var nativeMonoUpload = false
}

/// Every NetMD-capable USB device known to netmd-js / Web MiniDisc Pro.
public let knownDevices: [DeviceDefinition] = [
    .init(vendorId: 0x04dd, productId: 0x7202, name: "Sharp IM-MT899H"),
    .init(vendorId: 0x04dd, productId: 0x9013, name: "Sharp IM-DR400"),
    .init(vendorId: 0x04dd, productId: 0x9014, name: "Sharp IM-DR80", nativeMonoUpload: true),
    .init(vendorId: 0x054c, productId: 0x0034, name: "Sony PCLK-XX"),
    .init(vendorId: 0x054c, productId: 0x0036, name: "Sony"),
    .init(vendorId: 0x054c, productId: 0x0075, name: "Sony MZ-N1"),
    .init(vendorId: 0x054c, productId: 0x007c, name: "Sony"),
    .init(vendorId: 0x054c, productId: 0x0080, name: "Sony LAM-1"),
    .init(vendorId: 0x054c, productId: 0x0081, name: "Sony MDS-JB980/MDS-NT1/MDS-JE780", nativeMonoUpload: true),
    .init(vendorId: 0x054c, productId: 0x0084, name: "Sony MZ-N505"),
    .init(vendorId: 0x054c, productId: 0x0085, name: "Sony MZ-S1"),
    .init(vendorId: 0x054c, productId: 0x0086, name: "Sony MZ-N707"),
    .init(vendorId: 0x054c, productId: 0x008e, name: "Sony CMT-C7NT"),
    .init(vendorId: 0x054c, productId: 0x0097, name: "Sony PCGA-MDN1"),
    .init(vendorId: 0x054c, productId: 0x00ad, name: "Sony CMT-L7HD"),
    .init(vendorId: 0x054c, productId: 0x00c6, name: "Sony MZ-N10"),
    .init(vendorId: 0x054c, productId: 0x00c7, name: "Sony MZ-N910"),
    .init(vendorId: 0x054c, productId: 0x00c8, name: "Sony MZ-N710/NF810"),
    .init(vendorId: 0x054c, productId: 0x00c9, name: "Sony MZ-N510/N610"),
    .init(vendorId: 0x054c, productId: 0x00ca, name: "Sony MZ-NE410/NF520D"),
    .init(vendorId: 0x054c, productId: 0x00e7, name: "Sony CMT-M333NT/M373NT"),
    .init(vendorId: 0x054c, productId: 0x00eb, name: "Sony MZ-NE810/NE910"),
    .init(vendorId: 0x054c, productId: 0x0101, name: "Sony LAM"),
    .init(vendorId: 0x054c, productId: 0x0113, name: "Aiwa AM-NX1"),
    .init(vendorId: 0x054c, productId: 0x013f, name: "Sony MDS-S500"),
    .init(vendorId: 0x054c, productId: 0x014c, name: "Aiwa AM-NX9"),
    .init(vendorId: 0x054c, productId: 0x017e, name: "Sony MZ-NH1"),
    .init(vendorId: 0x054c, productId: 0x0180, name: "Sony MZ-NH3D"),
    .init(vendorId: 0x054c, productId: 0x0182, name: "Sony MZ-NH900"),
    .init(vendorId: 0x054c, productId: 0x0184, name: "Sony MZ-NH700/NH800"),
    .init(vendorId: 0x054c, productId: 0x0186, name: "Sony MZ-NH600"),
    .init(vendorId: 0x054c, productId: 0x0187, name: "Sony MZ-NH600D"),
    .init(vendorId: 0x054c, productId: 0x0188, name: "Sony MZ-N920"),
    .init(vendorId: 0x054c, productId: 0x018a, name: "Sony LAM-3"),
    .init(vendorId: 0x054c, productId: 0x01e9, name: "Sony MZ-DH10P"),
    .init(vendorId: 0x054c, productId: 0x0219, name: "Sony MZ-RH10"),
    .init(vendorId: 0x054c, productId: 0x021b, name: "Sony MZ-RH710/MZ-RH910"),
    .init(vendorId: 0x054c, productId: 0x021d, name: "Sony CMT-AH10"),
    .init(vendorId: 0x054c, productId: 0x022c, name: "Sony CMT-AH10"),
    .init(vendorId: 0x054c, productId: 0x023c, name: "Sony DS-HMD1"),
    .init(vendorId: 0x054c, productId: 0x0286, name: "Sony MZ-RH1"),
    .init(vendorId: 0x054c, productId: 0x011a, name: "Sony CMT-SE7"),
    .init(vendorId: 0x054c, productId: 0x0148, name: "Sony MDS-A1"),
    .init(vendorId: 0x0b28, productId: 0x1004, name: "Kenwood MDX-J9"),
    .init(vendorId: 0x04da, productId: 0x23b3, name: "Panasonic SJ-MR250", nativeMonoUpload: true),
    .init(vendorId: 0x04da, productId: 0x23b6, name: "Panasonic SJ-MR270", nativeMonoUpload: true),
    .init(vendorId: 0x0411, productId: 0x0083, name: "Buffalo MD-HUSB"),
]
