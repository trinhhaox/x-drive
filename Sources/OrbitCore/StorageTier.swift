import Foundation

public struct StorageTier: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let gigabytes: Int
    public let priceUSDMonthly: Double
    public let priceVNDMonthly: Int
    public let isFree: Bool
    public let badge: String?
    public let description: String

    public var limitBytes: Int64 {
        Int64(gigabytes) * 1024 * 1024 * 1024
    }

    public init(
        id: String,
        name: String,
        gigabytes: Int,
        priceUSDMonthly: Double,
        priceVNDMonthly: Int,
        isFree: Bool = false,
        badge: String? = nil,
        description: String
    ) {
        self.id = id
        self.name = name
        self.gigabytes = gigabytes
        self.priceUSDMonthly = priceUSDMonthly
        self.priceVNDMonthly = priceVNDMonthly
        self.isFree = isFree
        self.badge = badge
        self.description = description
    }

    // MARK: - Price Calculators (Cloudflare R2 standard: $0.015/GB/mo, first 10 GB free)

    public static func calculatePriceUSD(gigabytes: Int) -> Double {
        if gigabytes <= 10 { return 0.0 }
        let billable = Double(gigabytes - 10)
        return billable * 0.015
    }

    public static func calculatePriceVND(gigabytes: Int) -> Int {
        let usd = calculatePriceUSD(gigabytes: gigabytes)
        if usd <= 0.0 { return 0 }
        return Int((usd * 25_400.0).rounded())
    }

    public static func customTier(gigabytes: Int) -> StorageTier {
        let usd = calculatePriceUSD(gigabytes: gigabytes)
        let vnd = calculatePriceVND(gigabytes: gigabytes)
        let isFree = gigabytes <= 10
        let name = gigabytes >= 1000
            ? String(format: "Tùy chỉnh %.1f TB", Double(gigabytes) / 1000.0)
            : "Tùy chỉnh \(gigabytes) GB"

        return StorageTier(
            id: "custom_\(gigabytes)",
            name: name,
            gigabytes: gigabytes,
            priceUSDMonthly: usd,
            priceVNDMonthly: vnd,
            isFree: isFree,
            badge: isFree ? "Miễn phí" : "Tùy chỉnh",
            description: isFree
                ? "Dưới 10 GB hoàn toàn miễn phí trên Cloudflare R2"
                : "Tính theo thực tế: 10 GB đầu miễn phí + $0.015/GB phụ trội"
        )
    }

    // MARK: - Standard Presets for Cloudflare R2

    public static let cloudflarePresets: [StorageTier] = [
        StorageTier(
            id: "cf_10gb",
            name: "10 GB Miễn phí",
            gigabytes: 10,
            priceUSDMonthly: 0.0,
            priceVNDMonthly: 0,
            isFree: true,
            badge: "Free Tier",
            description: "10 GB lưu trữ miễn phí hàng tháng trên Cloudflare R2, 0đ băng thông tải về."
        ),
        StorageTier(
            id: "cf_50gb",
            name: "50 GB Cơ bản",
            gigabytes: 50,
            priceUSDMonthly: 0.60,
            priceVNDMonthly: 15_000,
            badge: "Tiết kiệm",
            description: "Lưu trữ tài liệu, ảnh gia đình, hồ sơ cá nhân và ghi chú quan trọng."
        ),
        StorageTier(
            id: "cf_100gb",
            name: "100 GB Phổ thông",
            gigabytes: 100,
            priceUSDMonthly: 1.35,
            priceVNDMonthly: 34_000,
            badge: "Phổ biến",
            description: "Phù hợp cho công việc văn phòng, sao lưu source code và dự án hàng ngày."
        ),
        StorageTier(
            id: "cf_200gb",
            name: "200 GB Nâng cao",
            gigabytes: 200,
            priceUSDMonthly: 2.85,
            priceVNDMonthly: 72_000,
            badge: "Gia đình / Team",
            description: "Thoải mái lưu ảnh RAW, video Full HD, dữ liệu công việc và tài liệu dài hạn."
        ),
        StorageTier(
            id: "cf_500gb",
            name: "500 GB Chuyên nghiệp",
            gigabytes: 500,
            priceUSDMonthly: 7.35,
            priceVNDMonthly: 185_000,
            badge: "Pro",
            description: "Dành cho designer, lập trình viên và người sáng tạo nội dung đa phương tiện."
        ),
        StorageTier(
            id: "cf_1tb",
            name: "1 TB (1.000 GB)",
            gigabytes: 1000,
            priceUSDMonthly: 14.85,
            priceVNDMonthly: 375_000,
            badge: "Dung lượng lớn",
            description: "Kho lưu trữ media, video 4K, bản backup toàn bộ ổ cứng máy Mac."
        ),
        StorageTier(
            id: "cf_2tb",
            name: "2 TB (2.000 GB)",
            gigabytes: 2000,
            priceUSDMonthly: 29.85,
            priceVNDMonthly: 750_000,
            badge: "Studio",
            description: "Dung lượng cực lớn cho công ty nhỏ, studio dựng phim hoặc lưu trữ không giới hạn."
        )
    ]

    // MARK: - Standard Presets for Google Drive (Tham khảo so sánh)

    public static let googleDrivePresets: [StorageTier] = [
        StorageTier(
            id: "gd_15gb",
            name: "15 GB Miễn phí",
            gigabytes: 15,
            priceUSDMonthly: 0.0,
            priceVNDMonthly: 0,
            isFree: true,
            badge: "Google Free",
            description: "Gói cơ bản đi kèm tài khoản Google cá nhân."
        ),
        StorageTier(
            id: "gd_100gb",
            name: "100 GB Google One",
            gigabytes: 100,
            priceUSDMonthly: 1.99,
            priceVNDMonthly: 45_000,
            badge: "Google One",
            description: "Gói mở rộng Google One tiêu chuẩn."
        ),
        StorageTier(
            id: "gd_200gb",
            name: "200 GB Google One",
            gigabytes: 200,
            priceUSDMonthly: 2.99,
            priceVNDMonthly: 69_000,
            badge: "Google One",
            description: "Gói gia đình chia sẻ qua Google Family."
        ),
        StorageTier(
            id: "gd_2tb",
            name: "2 TB Google One",
            gigabytes: 2000,
            priceUSDMonthly: 9.99,
            priceVNDMonthly: 225_000,
            badge: "Google Premium",
            description: "Gói cao cấp kèm tính năng Google Workspace nâng cao."
        )
    ]
}

