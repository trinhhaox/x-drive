import AppKit
import AuthenticationServices
import SwiftUI
import OrbitCore

// MARK: - AppLocation (Checks if XDrive.app is installed in /Applications)

public enum AppLocation {
    /// Returns true if the current bundle resides inside `/Applications` or `~/Applications`.
    public static var isInApplicationsFolder: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    public static var currentBundlePath: String {
        Bundle.main.bundleURL.path
    }
}

// MARK: - WelcomeStep & WelcomeView

public enum WelcomeStep: Int, CaseIterable, Identifiable {
    case virtualDrive = 0
    case zeroKnowledge = 1
    case politeUploads = 2

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .virtualDrive:
            return "Ổ đĩa đám mây nguyên bản với Apple FSKit"
        case .zeroKnowledge:
            return "Mã hóa Đầu cuối Zero-Knowledge (E2EE)"
        case .politeUploads:
            return "Tải lên Lịch sự (Polite Uploads)"
        }
    }

    public var subtitle: String {
        switch self {
        case .virtualDrive:
            return "Truy cập hàng Terabyte dữ liệu tại /Volumes/Helumi mà không chiếm dụng ổ cứng Mac. Bộ đệm khối 1 MiB phát trực tuyến tức thì."
        case .zeroKnowledge:
            return "Mọi tệp tin và tên thư mục được khóa bằng AES-256-GCM trên máy Mac của bạn trước khi lên mây. Chỉ thiết bị được bạn phê duyệt qua P-256 ECDH mới đọc được."
        case .politeUploads:
            return "Bộ điều tiết UploadGovernor tự động đo độ trễ RTT để chống nghẽn mạng (bufferbloat), giữ cuộc gọi video và trình duyệt luôn mượt mà."
        }
    }

    public var icon: String {
        switch self {
        case .virtualDrive: return "externaldrive.fill.badge.icloud"
        case .zeroKnowledge: return "lock.shield.fill"
        case .politeUploads: return "gauge.with.dots.needle.33percent"
        }
    }
}

public struct WelcomeView: View {
    @ObservedObject var model: AppModel
    @State private var currentStep: WelcomeStep = .virtualDrive

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: currentStep.icon)
                .font(.system(size: 56))
                .foregroundStyle(.blue)
                .symbolEffect(.pulse)

            VStack(spacing: 10) {
                Text(currentStep.title)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)

                Text(currentStep.subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            HStack(spacing: 8) {
                ForEach(WelcomeStep.allCases) { step in
                    Capsule()
                        .fill(step == currentStep ? Color.blue : Color.secondary.opacity(0.3))
                        .frame(width: step == currentStep ? 24 : 8, height: 8)
                        .animation(.spring(duration: 0.25), value: currentStep)
                }
            }
            .padding(.top, 8)

            Spacer()

            HStack {
                if currentStep != .virtualDrive {
                    Button("Quay lại") {
                        if let prev = WelcomeStep(rawValue: currentStep.rawValue - 1) {
                            currentStep = prev
                        }
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                if let next = WelcomeStep(rawValue: currentStep.rawValue + 1) {
                    Button("Tiếp theo") {
                        currentStep = next
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Bắt đầu Sử dụng XDrive") {
                        model.completeWelcomeOnboarding()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .frame(minWidth: 560, minHeight: 420)
        .padding()
    }
}

// MARK: - SignInView

public struct SignInView: View {
    @ObservedObject var model: AppModel
    @State private var email: String = "mr.trinhhao@gmail.com"
    @State private var password: String = ""
    @State private var isAuthenticating: Bool = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive.fill.badge.icloud")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Đăng nhập vào XDrive")
                .font(.title.bold())

            Text("Kết nối tài khoản đám mây Orbit để gắn kết ổ đĩa /Volumes/Helumi")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                TextField("Email tài khoản", text: $email)
                    .textFieldStyle(.roundedBorder)
                SecureField("Mật khẩu", text: $password)
                    .textFieldStyle(.roundedBorder)

                Button {
                    model.signInWithCredentials(email: email)
                } label: {
                    Label("Đăng nhập bằng Email", systemImage: "person.badge.key.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    isAuthenticating = true
                    model.browserSignIn.startSignIn { _ in
                        Task { @MainActor in
                            isAuthenticating = false
                            model.signInWithCredentials(email: email)
                        }
                    }
                } label: {
                    Label(
                        isAuthenticating ? "Đang chờ trình duyệt OAuth2 PKCE..." : "Đăng nhập qua Trình duyệt (OAuth2 PKCE)",
                        systemImage: "safari.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isAuthenticating)
            }
            .frame( width: 340)

            if !AppLocation.isInApplicationsFolder {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.orange)
                    Text("Gợi ý: Di chuyển XDrive.app vào thư mục /Applications để đăng ký FSKit & FinderSync ổn định nhất.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
        }
        .padding(32)
        .frame(minWidth: 520, minHeight: 400)
    }
}
