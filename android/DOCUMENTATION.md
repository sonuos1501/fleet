# Fleet Android Agent - Master Technical Guide

Dưới đây là bản hướng dẫn toàn diện nhất về dự án **Fleet Android Agent**, bao gồm kiến trúc, quy trình vận hành và phân tích mã nguồn chi tiết từng file.

---

## 1. Tổng Quan Dự Án (Project Identity)
**Fleet Android Agent** là một ứng dụng hệ thống (Management Agent) chạy trên nền tảng Android. Mục đích chính là giúp doanh nghiệp quản lý thiết bị thông qua FleetDM.
- **Công nghệ chính**: Kotlin, Jetpack Compose, WorkManager, Coroutines.
- **Bảo mật**: Sử dụng Android Hardware-backed Keystore và giao thức SCEP.
- **Triển khai**: Thông qua các hệ thống MDM (như Google Workspace, Kandji, Intune) dưới dạng "Companion App".

---

## 2. Kiến Trúc & Vòng Đời (Architecture & Lifecycle)

Ứng dụng được thiết kế để **không bao giờ chết** và tự duy trì trạng thái mà không cần người dùng chạm vào.

### 2.1 Cách ứng dụng khởi động (Bootstrap)
Có 3 kịch bản khiến Agent kích hoạt:
1. **Sau khi cài đặt (`COMPANION_APP` role)**: `RoleNotificationReceiverService` sẽ nhận tín hiệu từ MDM ngay khi app được cài đặt để đánh thức tiến trình.
2. **Khi khởi động lại thiết bị**: `BootReceiver` lắng nghe `ACTION_BOOT_COMPLETED` và ngay lập tức lên lịch một task enrollment khẩn cấp.
3. **Chạy định kỳ**: `WorkManager` đảm bảo app thức dậy mỗi 15 phút để kiểm tra cấu hình mới từ Fleet server.

### 2.2 Luồng Logic Chính
1. **Đọc MC (Managed Configuration)**: Lấy `server_url` và `enroll_secret`.
2. **Đăng ký (Enrollment)**: Gửi thông tin thiết bị lên Fleet để lấy `orbit_node_key`.
3. **Cấp phát Chứng chỉ (SCEP)**: Tải template chứng chỉ -> Tạo cặp khóa RSA -> Ký CSR -> Nhận chứng chỉ từ SCEP server -> Cài đặt vào Keystore.
4. **Báo cáo**: Gửi trạng thái `VERIFIED` về server.

---

## 3. Bảo Mật & Lưu Trữ (Security & Data)

### 3.1 Android Keystore (Phần cứng)
- **`KeystoreManager.kt`**: Chịu trách nhiệm bảo vệ `orbit_node_key`. Nó sinh ra một khóa AES 256-bit trong vùng quản lý phần cứng bảo mật của Android. Ngay cả khi thiết bị bị root, khóa này cũng cực kỳ khó bị trích xuất.
- **`DeviceKeystoreManager.kt`**: Sử dụng `DevicePolicyManager` để cài đặt các chứng chỉ danh tính (Identity Certificates). Các chứng chỉ này sau đó có thể được dùng cho Wifi doanh nghiệp hoặc VPN.

### 3.2 DataStore (Phần mềm)
Thay vì SharedPreferences lỗi thời, dự án dùng `Jetpack DataStore`.
- Dữ liệu được lưu dưới dạng Proto/JSON trong `ApiClient.prefDataStore`.
- Lưu trữ: `api_key` (đã mã hóa), `server_url`, `host_uuid`, và một Map khổng lồ lưu trạng thái từng chứng chỉ (`installed_certificates`).

---

## 4. Phân Tích Chi Tiết Từng File & Code (Deep Dive)

### 📂 `com.fleetdm.agent` (Root Package)

#### 📄 `AgentApplication.kt` (The Entry Point)
- **Log: `refreshEnrollmentCredentials()`**: 
    - Sử dụng `RestrictionsManager` để đọc cấu hình MDM.
    - Gọi `ApiClient.setEnrollmentCredentials` để lưu cấu hình.
    - Tự động gọi `getOrbitConfig()` để hoàn tất đăng ký nếu chưa có API Key.
- **Log: `schedulePeriodicCertificateEnrollment()`**:
    - Sử dụng `PeriodicWorkRequestBuilder` để đặt lịch chạy ngầm mỗi 15 phút. Luôn yêu cầu có mạng (`NetworkType.CONNECTED`).

#### 📄 `ApiClient.kt` (Communication Layer)
- **`makeRequest<R, T>`**: Hàm xương sống cho mọi API call.
    - Tự động thêm header `Authorization: Node key <key>`.
    - Sử dụng `HttpURLConnection` với cơ chế `withReenrollOnUnauthorized`. Nếu nhận lỗi 401 (Token hết hạn), nó sẽ tự xóa Key cũ và đăng ký lại ngay trong lần gọi đó.
- **`buildScepUrl()`**: Tạo URL đặc biệt chứa UUID thiết bị và ID chứng chỉ để SCEP proxy nhận diện.

#### 📄 `CertificateOrchestrator.kt` (The Brain)
Đây là file lớn nhất và quan trọng nhất.
- **`cleanupRemovedCertificates()`**: So sánh danh sách chứng chỉ trên thiết bị với danh sách server yêu cầu. Nếu server bảo xóa, nó sẽ gọi `removeKeyPair` và báo cáo về server.
- **`enrollCertificate()`**: 
    - Kiểm tra `UUID` cũ và mới. Nếu server thay đổi `UUID` của một template, Agent hiểu là cần "Renew" và sẽ chạy lại quy trình SCEP đè lên cái cũ.
- **`retryUnreportedStatuses()`**: Nếu việc cài đặt thành công nhưng app bị mất mạng lúc báo cáo, hàm này sẽ đảm bảo báo cáo lại trong lần chạy sau.

#### 📄 `CertificateEnrollmentWorker.kt` (The Background Engine)
- Triển khai `CoroutineWorker`. 
- Thực hiện theo thứ tự: 
    1. Gửi báo cáo còn nợ. 
    2. Dọn dẹp chứng chỉ cũ. 
    3. Cấp phát chứng chỉ mới (chạy song song bằng `async/awaitAll` để tăng tốc độ).

### 📂 `com.fleetdm.agent.scep` (Protocol Implementation)

#### 📄 `ScepClientImpl.kt` (Cryptography)
- **`generateKeyPair()`**: Sinh khóa RSA 2048/4096 bit.
- **`createSelfSignedCertificate()`**: Tạo chứng chỉ tạm thời (Self-signed) có hạn 100 ngày bằng BouncyCastle. Chứng chỉ này cực kỳ quan trọng vì nó dùng để bọc (envelope) gói tin SCEP gửi lên server.
- **`buildCsr()`**: Tạo Certificate Signing Request. Gắn thêm `Challenge Password` (mật khẩu dùng 1 lần) để SCEP server xác minh quyền hạn cấp phát.

---

## 5. Giao Diện & Debug (UI System)

Dự án sử dụng **Jetpack Compose** (Modern Android UI).

- **`MainActivity.kt`**: 
    - **`MainScreen`**: Hiển thị danh sách các chứng chỉ đã được cài đặt thành công (Verified).
    - **`DebugScreen`**: Được mở khi nhấp 8 lần vào version. Hiển thị:
        - `packageName`, `versionName`.
        - `delegatedScopes`: Các quyền mà MDM đã giao cho Agent.
        - `applicationRestrictions`: Dữ liệu thô từ MDM.
        - `installed_certificates`: Trạng thái chi tiết (Retry count, timestamps).

---

## 6. Xử Lý Lỗi & Resilience

1. **Transient Failures (Lỗi tạm thời)**: Nếu SCEP server lỗi mạng, Worker sẽ trả về `Result.retry()` để WorkManager tự động thử lại với thuật toán Exponential Backoff.
2. **Permanent Failures (Lỗi vĩnh viễn)**: Nếu server từ chối (Sai challenge password), Agent sẽ đánh dấu chứng chỉ đó là `FAILED` và không thử lại nữa để tránh lãng phí pin, trừ khi MDM đẩy xuống một `UUID` mới.
3. **Mã hóa API Key**: Key được mã hóa bằng AES-GCM. Mỗi lần mã hóa tạo ra một IV mới, lưu kèm vào chuỗi theo định dạng `iv]ciphertext`.

---
*Tài liệu này được soạn thảo để cung cấp sự hiểu biết sâu sắc nhất về mã nguồn Fleet Android Agent. Vui lòng tham khảo các file `.kt` tương ứng để xem chi tiết từng dòng code.*
