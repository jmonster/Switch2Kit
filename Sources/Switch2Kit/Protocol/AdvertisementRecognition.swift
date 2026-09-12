import Foundation

extension Switch2 {
    /// Validates the complete CoreBluetooth manufacturer blob before admission.
    /// The transport and fixture tests share this single company/vendor/model gate.
    package static func recognizeAdvertisement(_ data: Data) -> AdvertisementInfo? {
        guard data.count >= 18, u16(data, 0) == nintendoCompanyID else { return nil }
        return parseAdvertisement(manufacturerData: data.dropFirst(2))
    }
}
