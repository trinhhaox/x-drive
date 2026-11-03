import AppKit
import SwiftUI
import OrbitCore

// MARK: - StoragePlanSheet (Interactive Quota & Cloudflare R2 Pricing Calculator)

public struct StoragePlanSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTierID: String = "cf_10gb"
    @State private var customGB: Double = 100
    @State private var isCustomMode: Bool = false
    @State private var showAppliedAlert: Bool = false
    @State private var appliedMessage: String = ""

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "chart.bar.doc.horizontal.fill")
                            .font(.title2)
                            .foregroundStyle(.blue)
                        Text("Định Mức Dung Lượng & Bảng Giá Chi Phí")
                            .font(.title2.weight(.bold))
                    }
                    Text("Lưu trữ đám mây Cloudflare R2 • Không giới hạn băng thông tải về (Egress 0đ)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Current Status Banner
                    currentPlanBanner

                    // Predefined Tiers Selection
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Các Mức Dung Lượng Tiêu Chuẩn (Cloudflare R2)")
                            .font(.headline)

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            ForEach(StorageTier.cloudflarePresets) { tier in
                                tierCard(tier: tier)
                            }
                        }
                    }

                    Divider()

                    // Custom Slider Tier Section
                    customTierSection

                    Divider()

                    // Cloudflare Cost Breakdown & Comparison
                    costPolicyBox
                }
                .padding(20)
            }

            Divider()

            // Footer Action
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summaryPriceText)
                        .font(.headline.weight(.semibold))
                    Text(summaryDescText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Đóng") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    applySelection()
                } label: {
                    Label("Áp Dụng Định Mức Này", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(16)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 680, minHeight: 640)
        .onAppear {
            syncInitialSelection()
        }
        .alert("Đã cập nhật định mức", isPresented: $showAppliedAlert) {
            Button("OK") { dismiss() }
        } message: {
            Text(appliedMessage)
        }
    }

    // MARK: - Subviews

    private var currentPlanBanner: some View {
        GroupBox {
            HStack(spacing: 14) {
                Image(systemName: "externaldrive.fill.badge.icloud")
                    .font(.largeTitle)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Gói hiện tại: \(model.quota.plan)")
                        .font(.headline)
                    Text("Đã sử dụng: \(ByteCountFormatter.string(fromByteCount: model.quota.usedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: model.quota.limitBytes, countStyle: .file)) • \(model.quota.fileCount) tệp")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(4)
        }
    }

    private func tierCard(tier: StorageTier) -> some View {
        let isSelected = !isCustomMode && selectedTierID == tier.id

        return Button {
            isCustomMode = false
            selectedTierID = tier.id
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(tier.name)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(isSelected ? .blue : .primary)
                    Spacer()
                    if let badge = tier.badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(tier.isFree ? Color.green.opacity(0.15) : Color.blue.opacity(0.12))
                            .foregroundStyle(tier.isFree ? .green : .blue)
                            .clipShape(Capsule())
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if tier.isFree {
                        Text("0 đ")
                            .font(.title3.weight(.heavy))
                            .foregroundStyle(.green)
                        Text("/ tháng")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("~\(tier.priceVNDMonthly.formatted()) đ")
                            .font(.title3.weight(.heavy))
                            .foregroundStyle(.primary)
                        Text("($\(String(format: "%.2f", tier.priceUSDMonthly))/th)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(tier.description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.blue.opacity(0.08) : Color(NSColor.controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.blue : Color.gray.opacity(0.2), lineWidth: isSelected ? 2 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var customTierSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tùy Chỉnh Dung Lượng Theo Nhu Cầu")
                    .font(.headline)
                Spacer()
                Button {
                    isCustomMode = true
                } label: {
                    Text(isCustomMode ? "Đang chọn chế độ tùy chỉnh" : "Kích hoạt tùy chỉnh")
                        .font(.caption.weight(.medium))
                }
            }

            VStack(spacing: 12) {
                HStack {
                    Text("Dung lượng mong muốn:")
                        .font(.callout)
                    Spacer()
                    Text(customGB >= 1000 ? String(format: "%.1f TB (%d GB)", customGB / 1000.0, Int(customGB)) : "\(Int(customGB)) GB")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.blue)
                }

                Slider(value: $customGB, in: 10...3000, step: 10) { _ in
                    isCustomMode = true
                }
                .tint(.blue)

                HStack {
                    Text("10 GB (Miễn phí)")
                    Spacer()
                    Text("500 GB")
                    Spacer()
                    Text("1 TB")
                    Spacer()
                    Text("2 TB")
                    Spacer()
                    Text("3 TB")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                HStack {
                    let priceUSD = StorageTier.calculatePriceUSD(gigabytes: Int(customGB))
                    let priceVND = StorageTier.calculatePriceVND(gigabytes: Int(customGB))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Chi phí Cloudflare R2 ước tính:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if priceUSD == 0 {
                            Text("0 đ / tháng (Nằm trong hạn mức 10 GB Free)")
                                .font(.callout.weight(.bold))
                                .foregroundStyle(.green)
                        } else {
                            Text("~\(priceVND.formatted()) đ / tháng (~$\(String(format: "%.2f", priceUSD)) USD)")
                                .font(.callout.weight(.bold))
                                .foregroundStyle(.primary)
                        }
                    }
                    Spacer()
                    Button("Chọn mức này") {
                        isCustomMode = true
                    }
                    .buttonStyle(.bordered)
                }
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(14)
            .background(isCustomMode ? Color.blue.opacity(0.04) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isCustomMode ? Color.blue : Color.gray.opacity(0.2), lineWidth: isCustomMode ? 2 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var costPolicyBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Chính Sách Báo Giá & Minh Bạch Chi Phí Cloudflare R2", systemImage: "info.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 4) {
                    Text("• **10 GB lưu trữ đầu tiên hoàn toàn miễn phí** hàng tháng trên tài khoản Cloudflare của bạn.")
                    Text("• **0đ phí tải về (Zero Egress Fees)**: Bạn có thể tải bao nhiêu dữ liệu tùy thích mà không phát sinh phí băng thông.")
                    Text("• **Dung lượng vượt quá 10 GB**: Tính chính xác **$0.015 / GB / tháng** (~380 VNĐ / GB / tháng).")
                    Text("• **Không cam kết dài hạn**: Cloudflare tính cước linh hoạt theo số gigabyte thực tế bạn lưu trữ theo từng giờ.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(4)
        }
    }

    // MARK: - Computed Summary

    private var currentSelectedTier: StorageTier {
        if isCustomMode {
            return StorageTier.customTier(gigabytes: Int(customGB))
        } else {
            return StorageTier.cloudflarePresets.first(where: { $0.id == selectedTierID }) ?? StorageTier.cloudflarePresets[0]
        }
    }

    private var summaryPriceText: String {
        let t = currentSelectedTier
        if t.isFree {
            return "Định mức: \(t.name) • 0 đ / tháng"
        } else {
            return "Định mức: \(t.name) • ~\(t.priceVNDMonthly.formatted()) đ / tháng"
        }
    }

    private var summaryDescText: String {
        let t = currentSelectedTier
        if t.isFree {
            return "Miễn phí vĩnh viễn theo chính sách Cloudflare R2 Free Tier"
        } else {
            return "Ước tính ~$\(String(format: "%.2f", t.priceUSDMonthly)) USD/tháng cho \(t.gigabytes) GB lưu trữ"
        }
    }

    // MARK: - Actions

    private func syncInitialSelection() {
        let currentLimitGB = Int(Double(model.quota.limitBytes) / (1024 * 1024 * 1024))
        if let match = StorageTier.cloudflarePresets.first(where: { $0.gigabytes == currentLimitGB }) {
            selectedTierID = match.id
            isCustomMode = false
        } else {
            customGB = Double(max(10, currentLimitGB))
            isCustomMode = true
        }
    }

    private func applySelection() {
        let tier = currentSelectedTier
        model.applyStoragePlan(tier: tier)
        appliedMessage = "Đã cập nhật định mức đám mây thành \(tier.name) (\(tier.isFree ? "Miễn phí" : "~\(tier.priceVNDMonthly.formatted()) đ/tháng"))."
        showAppliedAlert = true
    }
}
