# Fleet Android Agent - Tài Liệu Kỹ Thuật Chi Tiết

Tài liệu phân tích toàn diện mã nguồn **Fleet Android Agent** — ứng dụng quản lý thiết bị Android doanh nghiệp thông qua hệ thống FleetDM.

---

## Mục Lục

1. [Tổng Quan Dự Án](#1-tổng-quan-dự-án)
2. [Kiến Trúc & Cấu Trúc File](#2-kiến-trúc--cấu-trúc-file)
3. [Vòng Đời Ứng Dụng](#3-vòng-đời-ứng-dụng)
4. [Phân Tích Chi Tiết Từng File](#4-phân-tích-chi-tiết-từng-file)
5. [Giao Thức SCEP](#5-giao-thức-scep)
6. [Bảo Mật & Lưu Trữ](#6-bảo-mật--lưu-trữ)
7. [Giao Diện Người Dùng](#7-giao-diện-người-dùng)
8. [Cấu Hình & Resources](#8-cấu-hình--resources)
9. [Xử Lý Lỗi & Khả Năng Phục Hồi](#9-xử-lý-lỗi--khả-năng-phục-hồi)
10. [Data Models & Serialization](#10-data-models--serialization)

---

## 1. Tổng Quan Dự Án

**Fleet Android Agent** là một Management Agent chạy trên Android, giúp doanh nghiệp quản lý thiết bị di động thông qua FleetDM server.

### Công nghệ sử dụng
| Thành phần | Công nghệ |
|---|---|
| Ngôn ngữ | Kotlin |
| UI Framework | Jetpack Compose + Material 3 |
| Background Work | WorkManager + Coroutines |
| Lưu trữ | Jetpack DataStore (Preferences) |
| Mã hóa | Android Hardware Keystore (AES-GCM) |
| Chứng chỉ | SCEP via jScep + BouncyCastle |
| Serialization | kotlinx.serialization (JSON) |
| MDM Integration | AMAPI SDK (Android Management API) |
| Min SDK | 24 (Android 7.0) |
| Target SDK | 35 (Android 15) |

### Chức năng chính
1. **Tự động enroll** với Fleet server khi được cài đặt qua MDM
2. **Cấp phát chứng chỉ** (SCEP) cho Wifi/VPN doanh nghiệp
3. **Quản lý vòng đời chứng chỉ** (install, renew, remove)
4. **Báo cáo trạng thái** về Fleet server
5. **Hoạt động hoàn toàn tự động**, không cần người dùng tương tác

---

## 2. Kiến Trúc & Cấu Trúc File

```
com.fleetdm.agent/
├── AgentApplication.kt          # Entry point - Application class
├── ApiClient.kt                 # HTTP client giao tiếp Fleet server
├── BootReceiver.kt              # BroadcastReceiver cho ACTION_BOOT_COMPLETED
├── CertificateEnrollmentHandler.kt  # Business logic xử lý enrollment
├── CertificateEnrollmentWorker.kt   # WorkManager background worker
├── CertificateOrchestrator.kt       # Bộ não điều phối certificate lifecycle
├── DeviceKeystoreManager.kt         # Quản lý keypair qua DevicePolicyManager
├── KeystoreManager.kt               # Quản lý mã hóa API key (AES-GCM)
├── MainActivity.kt                  # UI chính (Jetpack Compose)
├── RoleNotificationReceiverService.kt # Nhận COMPANION_APP role từ MDM
├── scep/
│   ├── ScepClient.kt            # Interface cho SCEP client
│   ├── ScepClientImpl.kt        # Implementation SCEP enrollment
│   ├── ScepException.kt         # Hệ thống exception cho SCEP
│   └── ScepResult.kt            # Data class kết quả SCEP
└── ui/theme/
    ├── Color.kt                 # Bảng màu ứng dụng
    ├── Theme.kt                 # Material 3 theme
    └── Type.kt                  # Typography
```

### Sơ đồ kiến trúc

```
┌──────────────────────────────────────────────────────────┐
│                    MDM Server (Fleet)                     │
│              ┌──────────┐ ┌──────────┐                   │
│              │ REST API │ │SCEP Proxy│                    │
│              └────┬─────┘ └────┬─────┘                   │
└───────────────────┼────────────┼─────────────────────────┘
                    │            │
            ┌───────┴────────────┴───────┐
            │        ApiClient           │
            │  (HTTP + Auto Re-enroll)   │
            └───────┬────────────────────┘
                    │
       ┌────────────┴────────────────┐
       │   CertificateOrchestrator   │
       │   (Điều phối toàn bộ flow)  │
       └──┬──────────┬──────────┬────┘
          │          │          │
   ┌──────┴──┐  ┌───┴────┐  ┌─┴──────────────┐
   │ DataStore│  │  SCEP  │  │DeviceKeystore  │
   │(trạng   │  │ Client │  │  Manager       │
   │  thái)  │  │(jScep) │  │(DPM keypairs) │
   └─────────┘  └────────┘  └────────────────┘
```

---

## 3. Vòng Đời Ứng Dụng

### 3 kịch bản khởi động

| Kịch bản | Trigger | Component | Hành vi |
|---|---|---|---|
| Cài đặt qua MDM | COMPANION_APP role | `RoleNotificationReceiverService` | Buộc process chạy → `AgentApplication.onCreate()` |
| Khởi động thiết bị | ACTION_BOOT_COMPLETED | `BootReceiver` | Lên lịch OneTimeWork enrollment khẩn cấp |
| Định kỳ 15 phút | WorkManager schedule | `CertificateEnrollmentWorker` | Check config mới, enroll/remove certificates |

### Luồng logic chính (Main Flow)

```
1. AgentApplication.onCreate()
   ├── ApiClient.initialize(context)
   ├── refreshEnrollmentCredentials()
   │   ├── Đọc RestrictionsManager (server_url, enroll_secret, host_uuid)
   │   ├── ApiClient.setEnrollmentCredentials()
   │   └── Nếu chưa có API Key → ApiClient.getOrbitConfig() → auto-enroll
   └── schedulePeriodicCertificateEnrollment()
       └── PeriodicWorkRequest mỗi 15 phút

2. CertificateEnrollmentWorker.doWork() [mỗi 15 phút]
   ├── STEP 0: retryUnreportedStatuses()
   ├── STEP 1: cleanupRemovedCertificates()
   ├── STEP 2: Lọc certificates cần install
   └── STEP 3: enrollCertificates() [song song với async/awaitAll]
```

---

## 4. Phân Tích Chi Tiết Từng File

---

### 📄 `AgentApplication.kt` (118 dòng)

**Vai trò**: Custom `Application` class — điểm khởi đầu khi process bắt đầu.

#### Class: `AgentApplication : Application()`

| Hàm | Dòng | Mô tả chi tiết |
|---|---|---|
| `onCreate()` | 44-54 | Được gọi khi app process khởi động. Khởi tạo `ApiClient`, tạo `CertificateOrchestrator`, gọi `refreshEnrollmentCredentials()` và `schedulePeriodicCertificateEnrollment()`. |
| `refreshEnrollmentCredentials()` | 56-92 | Đọc Managed Configuration từ `RestrictionsManager` để lấy `enroll_secret`, `host_uuid`, `server_url`. Nếu có đủ credentials → gọi `ApiClient.setEnrollmentCredentials()`. Nếu chưa có API key → tự động gọi `getOrbitConfig()` để enroll. |
| `schedulePeriodicCertificateEnrollment()` | 94-116 | Tạo `PeriodicWorkRequest` chạy `CertificateEnrollmentWorker` mỗi 15 phút. Cấu hình: Exponential Backoff, yêu cầu mạng (NetworkType.CONNECTED), policy KEEP (không tạo trùng). |
| `getCertificateOrchestrator(context)` | 38-39 | Companion function — lấy singleton `CertificateOrchestrator` từ Application. |

**Thuộc tính quan trọng**:
- `certificateOrchestrator`: Instance duy nhất của `CertificateOrchestrator`, được chia sẻ qua toàn app
- `applicationScope`: `CoroutineScope(SupervisorJob() + Dispatchers.Main)` — scope sống suốt vòng đời app

---

### 📄 `ApiClient.kt` (582 dòng)

**Vai trò**: Singleton object xử lý mọi HTTP request tới Fleet server. Implement `CertificateApiClient` interface.

#### Object: `ApiClient : CertificateApiClient`

| Hàm | Dòng | Mô tả chi tiết |
|---|---|---|
| `initialize(context)` | 75-80 | Khởi tạo DataStore instance. Chỉ gọi 1 lần. Dùng `prefDataStore` từ extension property. |
| `setApiKey(key)` | 82-86 | Lưu API key (orbit_node_key) đã **mã hóa** bằng `KeystoreManager.encrypt()` vào DataStore. |
| `clearApiKey()` | 88-92 | Xóa API key khỏi DataStore. Dùng khi nhận HTTP 401 (Unauthorized). |
| `getApiKey()` | 99-107 | Đọc và **giải mã** API key từ DataStore bằng `KeystoreManager.decrypt()`. Trả về null nếu không có hoặc giải mã thất bại. |
| `getBaseUrl()` | 109 | Đọc base URL của Fleet server từ DataStore. |
| `makeRequest<R,T>()` | 111-189 | **Hàm xương sống** cho mọi API call. Xử lý: validate URL → mở HttpURLConnection → set headers (Content-Type, Authorization: Node key) → gửi JSON body → đọc response → parse JSON. Timeout: 15s connect, 15s read. Trả `Result.failure(UnauthorizedException)` nếu HTTP 401. |
| `withReenrollOnUnauthorized(block)` | 202-210 | Decorator pattern: nếu block trả 401 → xóa API key → retry block 1 lần (lần retry sẽ tự auto-enroll). |
| `enroll()` | 212-236 | Gửi POST `/api/fleet/orbit/enroll` với `enrollSecret`, `hardwareUUID`, `computerName`, `platform="android"`. Khi thành công → lưu `orbit_node_key` làm API key. |
| `getOrbitConfig()` | 238-253 | Gửi POST `/api/fleet/orbit/config` để lấy cấu hình orbit. Có auto re-enroll on 401. |
| `setEnrollmentCredentials()` | 255-262 | Lưu enrollment credentials (enrollSecret, hardwareUUID, computerName, serverUrl) vào DataStore. |
| `getCertificateTemplate(id)` | 264-294 | GET `/api/fleetd/certificates/{id}` → lấy template chi tiết → build SCEP URL. Có auto re-enroll on 401. |
| `updateCertificateStatus()` | 296-333 | PUT `/api/fleetd/certificates/{id}/status` → cập nhật trạng thái certificate (VERIFIED/FAILED, INSTALL/REMOVE). Gửi kèm metadata: notAfter, notBefore, serialNumber. |
| `getEnrollmentCredentials()` | 335-352 | Private — đọc credentials từ DataStore, trả null nếu thiếu bất kỳ field nào. |
| `getNodeKeyOrEnroll()` | 354-379 | Private — lấy API key hoặc tự động enroll nếu chưa có. Dùng `Mutex` để tránh race condition (nhiều coroutine cùng enroll). |

**Extension function**:
| Hàm | Dòng | Mô tả |
|---|---|---|
| `Date.toISO8601String()` | 36 | Chuyển Date sang "yyyy-MM-dd'T'HH:mm:ss'Z'" (UTC). |
| `GetCertificateTemplateResponse.buildScepUrl()` | 580-581 | Xây dựng SCEP proxy URL: `{serverUrl}/mdm/scep/proxy/{hostUUID},g{id},{caType},{fleetChallenge}` |

#### Data Classes (API Models)

| Class | Dòng | Mô tả |
|---|---|---|
| `EnrollRequest` | 389-401 | Request body cho enrollment: enrollSecret, hardwareUUID, hardwareSerial, platform, computerName |
| `EnrollResponse` | 403-407 | Response: orbit_node_key |
| `GetConfigRequest` | 410-413 | Request body cho getOrbitConfig |
| `OrbitConfig` | 415-434 | Cấu hình orbit: scriptExecutionTimeout, extensions, nudgeConfig, notifications, updateChannels |
| `OrbitConfigNotifications` | 436-470 | Thông báo: pending scripts, software installers, enrollment profile renewal, disk encryption, MDM migration |
| `OrbitUpdateChannels` | 472-482 | Update channels cho orbit, osqueryd, desktop |
| `GetCertificateTemplateRequest` | 484-488 | Request lấy certificate template |
| `UpdateCertificateStatusRequest` | 490-504 | Request cập nhật trạng thái: status, operationType, detail, notAfter, notBefore, serialNumber |
| `UpdateCertificateStatusStatus` | 506-513 | Enum: VERIFIED, FAILED |
| `UpdateCertificateStatusOperation` | 515-522 | Enum: INSTALL, REMOVE |
| `UpdateCertificateStatusResponse` | 524-528 | Response: error (nullable) |
| `GetCertificateTemplateResponseWrapper` | 530-534 | Wrapper chứa certificate object |
| `GetCertificateTemplateResponse` | 536-575 | Template chi tiết: id, name, certificateAuthorityId, subjectName, caType, status, scepChallenge, fleetChallenge, keyLength (default 2048), signatureAlgorithm (default SHA256withRSA) |
| `CertificateTemplateResult` | 43 | Kết hợp template + computed scepUrl |

---

### 📄 `BootReceiver.kt` (51 dòng)

**Vai trò**: `BroadcastReceiver` lắng nghe `ACTION_BOOT_COMPLETED` — đảm bảo enrollment chạy ngay sau khi thiết bị khởi động lại.

#### Class: `BootReceiver : BroadcastReceiver()`

| Hàm | Dòng | Mô tả |
|---|---|---|
| `onReceive(context, intent)` | 21-49 | Khi nhận boot completed → tạo `OneTimeWorkRequest` cho `CertificateEnrollmentWorker` với tên `certificate_enrollment_boot`. Policy: REPLACE (chạy mới mỗi lần boot). Cấu hình: Exponential Backoff + yêu cầu mạng. |

**Tại sao dùng OneTimeWork thay vì chạy trực tiếp?**
- BroadcastReceiver có giới hạn 10 giây thực thi
- WorkManager đảm bảo task chạy ngay cả khi process bị kill
- Constraints đảm bảo có mạng trước khi chạy

---

### 📄 `CertificateEnrollmentHandler.kt` (84 dòng)

**Vai trò**: Xử lý business logic enrollment **không có dependency vào Android framework** → dễ unit test.

#### Class: `CertificateEnrollmentHandler`

**Constructor**: `(scepClient: ScepClient, certificateInstaller: CertificateInstaller)`

| Hàm | Dòng | Mô tả |
|---|---|---|
| `handleEnrollment(config, scepUrl)` | 40-83 | Luồng enrollment chính: (1) Gọi `scepClient.enroll(config, scepUrl)` → nhận privateKey + certificateChain → (2) Gọi `certificateInstaller.installCertificate()` → (3) Trả về `EnrollmentResult`. Bắt và phân loại 6 loại exception khác nhau. |

#### Interface: `CertificateInstaller`

| Hàm | Mô tả |
|---|---|
| `installCertificate(alias, privateKey, certificateChain)` | Cài đặt certificate vào keystore. Production = DPM, Test = mock. |

#### Sealed Class: `EnrollmentResult`

| Variant | Thuộc tính | Mô tả |
|---|---|---|
| `Success` | alias, notAfter, notBefore, serialNumber | Enrollment thành công |
| `Failure` | reason, exception?, isRetryable | Thất bại — `isRetryable=true` cho lỗi mạng |
| `PermanentlyFailed` | alias | Đã hết retry, không thử lại |

---

### 📄 `CertificateEnrollmentWorker.kt` (140 dòng)

**Vai trò**: `CoroutineWorker` chạy background mỗi 15 phút hoặc khi boot.

#### Class: `CertificateEnrollmentWorker : CoroutineWorker`

| Hàm | Dòng | Mô tả |
|---|---|---|
| `doWork()` | 19-131 | Chạy 4 bước tuần tự: **STEP 0**: `retryUnreportedStatuses()` — báo cáo lại các trạng thái chưa gửi được. **STEP 1**: `cleanupRemovedCertificates()` — dọn dẹp certificates bị xóa. **STEP 2**: Lọc certificates có operation=install. **STEP 3**: `enrollCertificates()` — enroll song song. Phân tích kết quả và trả về Worker Result. |

**Logic trả Result**:
- Có transient failure + chưa hết retry → `Result.retry()` (exponential backoff)
- Có transient failure + hết retry (MAX_RETRY_ATTEMPTS=5) → `Result.success()` (để periodic schedule tiếp quản)
- Có permanent failure → `Result.failure()`
- Tất cả success → `Result.success()`

**Constants**: `WORK_NAME = "certificate_enrollment"`, `MAX_RETRY_ATTEMPTS = 5`

---

### 📄 `CertificateOrchestrator.kt` (924 dòng)

**Vai trò**: **File quan trọng nhất** — "bộ não" điều phối toàn bộ certificate lifecycle. Phối hợp API calls, SCEP enrollment, certificate installation, và DataStore tracking.

#### Class: `CertificateOrchestrator`

**Constructor**: `(apiClient, scepClient, deviceKeystoreManager?)` — hỗ trợ dependency injection cho testing.

##### Quản lý trạng thái Certificate (DataStore)

| Hàm | Dòng | Mô tả |
|---|---|---|
| `installedCertsFlow(context)` | 85-91 | Trả `Flow<CertificateStateMap>` — reactive stream theo dõi thay đổi certificates trong DataStore. UI dùng flow này để tự cập nhật. |
| `getHostCertificates(context)` | 99-113 | Đọc certificate templates từ **Managed Configuration** (RestrictionsManager). Parse `bundle_array` "certificate_templates" → List`<HostCertificate>`. Mỗi bundle chứa: id (int), status (string), operation (string), uuid (string). |
| `getCertificateStates(context)` | 121-138 | Đọc map `CertificateStateMap` từ DataStore (JSON). Thread-safe qua `Mutex`. |
| `getCertificateState(context, id)` | 140-143 | Lấy trạng thái 1 certificate theo ID. |
| `markCertificateInstalled()` | 145-151 | Đánh dấu certificate đã cài thành công, reset retries=0, cập nhật uuid. |
| `markCertificateFailure()` | 153-171 | Tăng `retries+1`. Nếu `retries >= MAX_CERT_INSTALL_RETRIES (3)` → chuyển status sang FAILED. |
| `storeCertificateState()` | 181-214 | Read-modify-write DataStore: đọc map hiện tại → thêm/cập nhật entry → serialize JSON → lưu lại. Thread-safe qua Mutex. |
| `removeCertificateState()` | 222-254 | Xóa 1 entry khỏi DataStore map. |
| `getCertificateAlias()` | 263-268 | Lấy alias từ DataStore theo certificate ID. |
| `markCertificateUnreported()` | 526-551 | Đánh dấu trạng thái `INSTALLED_UNREPORTED` hoặc `REMOVED_UNREPORTED`. Lưu kèm metadata (notAfter, notBefore, serialNumber) để retry report sau. |
| `incrementStatusReportRetries()` | 561-588 | Tăng retry count. Nếu đạt `MAX_STATUS_REPORT_RETRIES (10)` → chuyển sang trạng thái cuối (INSTALLED hoặc REMOVED). |
| `retryUnreportedStatuses()` | 597-642 | Duyệt tất cả certificates có status UNREPORTED → gọi `updateCertificateStatus()` → nếu thành công → mark installed/removed. Nếu thất bại → increment retries. |

##### Enrollment & Cleanup

| Hàm | Dòng | Mô tả |
|---|---|---|
| `enrollCertificate()` | 654-791 | **Luồng enrollment đầy đủ cho 1 certificate**: (1) Check đã install + uuid khớp → skip. (2) Check FAILED + uuid khớp → skip (PermanentlyFailed). (3) Gọi API lấy template. (4) Check status=="delivered" → nếu không thì skip. (5) Tạo `CertificateEnrollmentHandler` → `handleEnrollment()`. (6) Nếu Success → mark unreported → report status → mark installed. (7) Nếu Failure → `markCertificateFailure()` → nếu hết retry → report FAILED lên server. |
| `enrollCertificates()` | 800-812 | Enroll nhiều certificates **song song** bằng `coroutineScope { async { ... } }`. Trả `Map<Int, EnrollmentResult>`. |
| `cleanupRemovedCertificates()` | 340-455 | **Xử lý xóa certificates** theo 2 bước: **Step 1**: Process certificates có operation="remove" — xóa keypair → report server → mark REMOVED. Xử lý nhiều edge case: already removed, uuid changed, not in DataStore. **Step 2**: Clean up orphaned certificates (trong DataStore nhưng không trong host config) — nếu status=REMOVED → xóa tracking. Nếu status khác → xóa certificate. |
| `removeCertificateFromDevice()` | 460-507 | Private — thực hiện xóa keypair: (1) Mark unreported (persist trước network call). (2) `removeKeyPair()`. (3) Report server. (4) Nếu report thành công → mark REMOVED, nếu thất bại → giữ REMOVED_UNREPORTED. |

##### Helper Functions

| Hàm | Dòng | Mô tả |
|---|---|---|
| `getDeviceKeystoreManager()` | 273-274 | Lấy DPM hoặc injected mock. |
| `isCertificateInstalled()` | 283-287 | Check keypair tồn tại trong keystore. |
| `removeKeyPair()` | 296 | Xóa keypair qua DPM. |
| `isCertificateIdInstalled()` | 306-321 | Check DataStore tracking + keystore thực tế. |
| `markCertificateRemoved()` | 512-515 | Đánh dấu certificate đã bị xóa. |
| `Date.toISO8601String()` | 69-73 | Format date ISO8601. |
| `parseISO8601()` | 80 | Parse ISO8601 string → Date. |

#### Inner Class: `AndroidCertificateInstaller`

| Hàm | Dòng | Mô tả |
|---|---|---|
| `installCertificate()` | 826-848 | Cài keypair qua `DevicePolicyManager.installKeyPair()`. Admin component = null vì app là DELEGATED app (không phải DPC). |

#### Data Classes & Enums (cuối file)

| Type | Dòng | Mô tả |
|---|---|---|
| `CertificateStateMap` | 852 | `typealias Map<Int, CertificateState>` |
| `CertificateStatus` (enum) | 854-873 | 6 trạng thái: `INSTALLED`, `INSTALLED_UNREPORTED`, `FAILED`, `RETRY`, `REMOVED`, `REMOVED_UNREPORTED` |
| `CertificateState` | 876-896 | alias, status, retries, statusReportRetries, uuid, notAfter, notBefore, serialNumber. Hàm: `shouldRetry()`, `shouldRetryStatusReport()` |
| `CleanupResult` (sealed) | 901-905 | `Success(alias)`, `Failure(reason, exception, shouldRetry)`, `AlreadyRemoved(alias)` |
| `HostCertificate` | 915-923 | id, status, operation, uuid. Hàm: `shouldInstall()`, `shouldRemove()`. Constants: `OPERATION_INSTALL`, `OPERATION_REMOVE` |

---

### 📄 `KeystoreManager.kt` (99 dòng)

**Vai trò**: Singleton object — mã hóa/giải mã API key (orbit_node_key) bằng AES-GCM, sử dụng Android Hardware Keystore.

#### Object: `KeystoreManager`

| Hàm | Dòng | Mô tả |
|---|---|---|
| `enableTestMode()` | 27-32 | Bật test mode — dùng in-memory AES key thay vì hardware keystore. |
| `disableTestMode()` | 34-37 | Tắt test mode. |
| `getOrCreateKey()` | 39-69 | Lấy hoặc tạo AES-256 key trong AndroidKeyStore. Cấu hình: `PURPOSE_ENCRYPT|DECRYPT`, `GCM`, `NoPadding`, `userAuthenticationRequired=false`, `randomizedEncryptionRequired=true`. |
| `encrypt(plaintext)` | 71-81 | Mã hóa chuỗi: Cipher init ENCRYPT → lấy IV → encrypt → trả format `{iv_base64}]{ciphertext_base64}`. IV mới mỗi lần encrypt. |
| `decrypt(ciphertext)` | 84-97 | Giải mã: tách IV và ciphertext theo `]` separator → Cipher init DECRYPT với GCMParameterSpec(128bit tag) → decrypt. |

**Constants**: `ANDROID_KEYSTORE`, `KEY_ALIAS="fleet_api_key_encryption"`, `TRANSFORMATION="AES/GCM/NoPadding"`, `GCM_TAG_LENGTH=128`, `IV_SEPARATOR="]"`

---

### 📄 `DeviceKeystoreManager.kt` (65 dòng)

**Vai trò**: Interface + Implementation quản lý keypair qua `DevicePolicyManager`.

#### Interface: `DeviceKeystoreManager`

| Hàm | Mô tả |
|---|---|
| `hasKeyPair(alias)` | Kiểm tra keypair tồn tại trong keystore |
| `removeKeyPair(alias)` | Xóa keypair. Trả true nếu thành công hoặc keypair không tồn tại |

#### Class: `AndroidDeviceKeystoreManager(context)`

| Hàm | Dòng | Mô tả |
|---|---|---|
| `hasKeyPair(alias)` | 37-42 | Gọi `dpm.hasKeyPair(alias)`. Catch exception → return false. |
| `removeKeyPair(alias)` | 44-63 | Check `hasKeyPair` → nếu không có thì trả true (coi như đã xóa). Nếu có → `dpm.removeKeyPair(null, alias)`. Admin=null vì app là delegated app. Catch SecurityException riêng. |

---

### 📄 `RoleNotificationReceiverService.kt` (25 dòng)

**Vai trò**: Service nhận thông báo từ Android Device Policy khi app được gán COMPANION_APP role.

#### Class: `RoleNotificationReceiverService : NotificationReceiverService()`

| Hàm | Dòng | Mô tả |
|---|---|---|
| `getAppRolesListener()` | 18-23 | Trả về `AppRolesListener` — khi nhận `onAppRolesSet()` chỉ log và trả default response. **Mục đích thật**: Service declaration buộc Android khởi động app process ngay khi cài qua MDM. |

**Tại sao cần file này?**
- Khi MDM cài app, AMAPI SDK gán COMPANION_APP role
- `NotificationReceiverService` được kích hoạt → process start → `AgentApplication.onCreate()` chạy
- Đây là cơ chế để app "tự thức dậy" mà không cần người dùng mở

---

### 📄 `MainActivity.kt` (386 dòng)

**Vai trò**: Activity chính — Giao diện Jetpack Compose hiển thị thông tin agent và certificates.

#### Class: `MainActivity : ComponentActivity()`

| Hàm | Dòng | Mô tả |
|---|---|---|
| `onCreate()` | 76-91 | Enable edge-to-edge display → set Compose content với `MyApplicationTheme` → `AppNavigation()`. |

#### Composable Functions

| Hàm | Dòng | Mô tả |
|---|---|---|
| `AppNavigation()` | 93-113 | Navigation graph: 2 destination — `MainDestination` (trang chính) và `DebugDestination` (trang debug). Dùng `NavHost` + typed navigation. |
| `MainScreen()` | 116-155 | Trang chính: Logo + "About Fleet" (link tới fleetdm.com) + danh sách certificates đã install + App version. Click version 8 lần → mở Debug screen. Click version 1 lần → copy version vào clipboard. |
| `DebugScreen()` | 158-220 | Trang debug ẩn: Hiển thị packageName, versionName, longVersionCode, delegatedScopes, host_uuid (masked ****xxxx), server_url (từ MC và DataStore), host_certificates, certificate status chi tiết, permission list. |
| `DebugCertificateList()` | 222-246 | Hiển thị chi tiết mỗi certificate: alias, status, retries, uuid, notBefore, notAfter, serialNumber. |
| `PermissionList()` | 248-259 | Hiển thị danh sách permissions đã được grant. |
| `KeyValue()` | 261-272 | Component key-value đơn giản với bold key. |
| `AboutFleet()` | 274-295 | Mô tả app + link "About Fleet". Nếu không có browser trong work profile → hiện Toast với URL. |
| `LogoHeader()` | 297-304 | Hiển thị logo Fleet. |
| `CertificateList()` | 306-323 | Danh sách certificates đã install (chỉ hiện INSTALLED và INSTALLED_UNREPORTED). |
| `AppVersion()` | 325-344 | Hiển thị version name. Clickable. |

**Constants**: `CLICKS_TO_DEBUG = 8`

---

## 5. Giao Thức SCEP

### 📄 `ScepClient.kt` (25 dòng)

**Vai trò**: Interface định nghĩa contract cho SCEP client.

| Hàm | Mô tả |
|---|---|
| `enroll(config, scepUrl)` | Thực hiện SCEP enrollment đầy đủ. Trả về `ScepResult` hoặc throw `ScepException`. |

### 📄 `ScepClientImpl.kt` (183 dòng)

**Vai trò**: Implementation SCEP enrollment sử dụng jScep library + BouncyCastle.

#### Class: `ScepClientImpl : ScepClient`

| Hàm | Dòng | Mô tả |
|---|---|---|
| `enroll()` | 47-132 | **Luồng SCEP đầy đủ** (7 bước): (1) `generateKeyPair()` RSA. (2) Parse X500Name từ subjectName. (3) `createSelfSignedCertificate()` cho PKCS7 envelope. (4) Tạo jScep Client với `OptimisticCertificateVerifier`. (5) `buildCsr()` với challenge password. (6) `client.enrol()` gửi request. (7) Xử lý response: success → extract certificates, pending → throw exception, failed → throw exception. |
| `generateKeyPair(keyLength)` | 134-140 | Tạo RSA keypair (mặc định 2048 bit). |
| `createSelfSignedCertificate()` | 142-161 | Tạo X509v3 self-signed cert, hạn 100 ngày. Dùng BouncyCastle `JcaX509v3CertificateBuilder`. Cert này chỉ dùng để ký PKCS7 envelope gửi SCEP server, KHÔNG phải cert cuối cùng. |
| `buildCsr()` | 163-174 | Tạo PKCS#10 CSR. Gắn `challengePassword` attribute — mật khẩu 1 lần để SCEP server xác thực quyền cấp phát. |
| `extractCertificates()` | 176-181 | Lấy danh sách certificates từ `CertStore` response. |

**Tại sao dùng `OptimisticCertificateVerifier`?**
- SCEP URL do MDM server cung cấp (đã xác thực)
- Challenge password xác thực enrollment request
- Enterprise SCEP servers thường dùng internal CA không có trong system trust stores
- Certificate khi sử dụng sẽ được validate riêng

### 📄 `ScepException.kt` (32 dòng)

**Hệ thống phân loại exception cho SCEP**:

| Class | Mô tả | Retryable? |
|---|---|---|
| `ScepException` | Base class | — |
| `ScepEnrollmentException` | Server reject hoặc pending | ❌ |
| `ScepNetworkException` | Lỗi mạng | ✅ |
| `ScepCertificateException` | Lỗi xử lý/validate certificate | ❌ |
| `ScepKeyGenerationException` | Lỗi sinh keypair | ❌ |
| `ScepCsrException` | Lỗi tạo CSR | ❌ |

### 📄 `ScepResult.kt` (24 dòng)

| Thuộc tính | Type | Mô tả |
|---|---|---|
| `privateKey` | PrivateKey | Khóa private đã sinh |
| `certificateChain` | List\<Certificate\> | Chuỗi certificates (leaf first) |
| `notAfter` | Date | Ngày hết hạn certificate |
| `notBefore` | Date | Ngày bắt đầu hiệu lực |
| `serialNumber` | BigInteger | Serial number của leaf cert |

---

## 6. Bảo Mật & Lưu Trữ

### Mã hóa API Key

```
Plaintext (orbit_node_key)
    ↓
KeystoreManager.encrypt()
    ↓ AES-256-GCM (Hardware Keystore)
"{iv_base64}]{ciphertext_base64}"
    ↓
DataStore (Preferences)
```

- **Key**: AES-256 bit, lưu trong Android Hardware Keystore
- **Algorithm**: AES/GCM/NoPadding với 128-bit authentication tag
- **IV**: Ngẫu nhiên mỗi lần encrypt (randomizedEncryptionRequired=true)
- **Bảo vệ**: Không yêu cầu user authentication (hoạt động background)

### Certificate Storage

```
DevicePolicyManager.installKeyPair()
    ↓ Administrator delegation
Android Keystore (per certificate alias)
```

- App phải được MDM delegate quyền `CERT_INSTALL`
- Keypair cài qua `installKeyPair(null, ...)` — admin=null cho delegated app
- Certificates dùng cho Wifi doanh nghiệp, VPN, etc.

### DataStore Structure

```json
{
  "api_key": "{iv}]{encrypted_orbit_node_key}",
  "server_url": "https://fleet.company.com",
  "enroll_secret": "...",
  "hardware_uuid": "...",
  "computer_name": "Samsung Galaxy S24",
  "installed_certificates": {
    "1": {
      "alias": "WIFI-Enterprise",
      "status": "installed",
      "retries": 0,
      "status_report_retries": 0,
      "uuid": "abc-123",
      "not_after": "2026-12-31T23:59:59Z",
      "not_before": "2025-01-01T00:00:00Z",
      "serial_number": "123456789"
    }
  }
}
```

---

## 7. Giao Diện Người Dùng

### UI Theme

| File | Nội dung |
|---|---|
| `Color.kt` | Bảng màu: Purple80/40, PurpleGrey80/40, Pink80/40, `FleetTextLight=#515774`, `FleetTextDark=#192147` |
| `Theme.kt` | Light-only theme dùng `lightColorScheme` Material 3 |
| `Type.kt` | Typography: bodyLarge = 16sp, Default font, FleetTextLight color |

### Trang chính (MainScreen)

```
┌──────────────────────┐
│  [Fleet Logo]        │
├──────────────────────┤
│  App description...  │
│  ➡ About Fleet      │
├──────────────────────┤
│  Installed certs:    │
│  • WIFI-Enterprise   │
│  • VPN-Corporate     │
├──────────────────────┤
│  App version: 1.1.0  │
│  (click 8x → debug) │
└──────────────────────┘
```

### Trang Debug (DebugScreen) — Ẩn

Truy cập bằng cách nhấn version 8 lần. Hiển thị:
- Package name, version name/code
- Delegated scopes (từ MDM)
- host_uuid (masked), server_url (từ MC và DataStore)
- Host certificates (id:operation)
- Chi tiết mỗi certificate: alias, status, retries, uuid, notBefore, notAfter, serial
- Permission list (granted)

---

## 8. Cấu Hình & Resources

### AndroidManifest.xml

| Component | Type | Mô tả |
|---|---|---|
| `AgentApplication` | Application | Custom Application class |
| `MainActivity` | Activity | LAUNCHER activity |
| `BootReceiver` | Receiver | ACTION_BOOT_COMPLETED |
| `RoleNotificationReceiverService` | Service | AMAPI COMPANION_APP role |

**Permissions**: `INTERNET`, `RECEIVE_BOOT_COMPLETED`

**Queries**: `com.google.android.apps.work.clouddpc` (Android Device Policy), `ACTION_VIEW` với `https` scheme

### App Restrictions (Managed Configuration)

File `app_restrictions.xml` định nghĩa các key MDM có thể push:

| Key | Type | Mô tả |
|---|---|---|
| `enroll_secret` | string | Secret enrollment |
| `server_url` | string | Fleet server URL |
| `host_uuid` | string | Device UUID |
| `certificate_templates` | bundle_array | Mảng certificate templates |
| `certificate_templates[].id` | integer | Template ID |
| `certificate_templates[].status` | string | Trạng thái |
| `certificate_templates[].operation` | string | install/remove |

### Build Configuration

- `applicationId`: `com.fleetdm.agent`
- `minSdk`: 24, `targetSdk`/`compileSdk`: 35
- `versionCode`: 6, `versionName`: "1.1.0"
- `INFO_URL`: "https://fleetdm.com/better"
- Java/Kotlin toolchain: JDK 17, JVM target 11

---

## 9. Xử Lý Lỗi & Khả Năng Phục Hồi

### Certificate Installation Retries

```
Lần 1 thất bại → status: RETRY, retries: 1
Lần 2 thất bại → status: RETRY, retries: 2
Lần 3 thất bại → status: FAILED, retries: 3 (MAX_CERT_INSTALL_RETRIES)
→ Report FAILED lên server → Không retry nữa
→ Trừ khi MDM đẩy UUID mới → reset và thử lại
```

### Status Report Retries

```
Install/Remove thành công → status: INSTALLED_UNREPORTED / REMOVED_UNREPORTED
Mỗi 15 phút retryUnreportedStatuses() thử report
Sau 10 lần thất bại (MAX_STATUS_REPORT_RETRIES) → chuyển sang INSTALLED/REMOVED (bỏ cuộc)
```

### Auto Re-enrollment (HTTP 401)

```
API call → 401 Unauthorized
→ clearApiKey()
→ Retry block (tự enroll lại trong getNodeKeyOrEnroll())
→ Retry API call với key mới
```
Cơ chế này xử lý trường hợp host bị xóa khỏi Fleet server.

### Worker Retry Logic

```
CertificateEnrollmentWorker (MAX_RETRY_ATTEMPTS=5)
Transient failure + attempts < 5 → Result.retry() (exponential backoff)
Transient failure + attempts >= 5 → Result.success() (để periodic 15min tiếp quản)
Permanent failure → Result.failure()
```

---

## 10. Data Models & Serialization

### Certificate Status State Machine

```
                 ┌─────────────┐
     install     │             │     install success
  ─────────────→ │   RETRY     │ ──────────────────→ INSTALLED_UNREPORTED
                 │ (retries<3) │                            │
                 └──────┬──────┘                            │
                        │ retries>=3                   report success
                        ↓                                   │
                 ┌─────────────┐                            ↓
                 │   FAILED    │                     ┌─────────────┐
                 └─────────────┘                     │  INSTALLED  │
                                                     └──────┬──────┘
                                                            │ remove
                                                            ↓
                                                     REMOVED_UNREPORTED
                                                            │ report
                                                            ↓
                                                     ┌─────────────┐
                                                     │   REMOVED   │
                                                     └─────────────┘
```

### API Endpoints sử dụng

| Method | Endpoint | Mô tả |
|---|---|---|
| POST | `/api/fleet/orbit/enroll` | Đăng ký thiết bị |
| POST | `/api/fleet/orbit/config` | Lấy cấu hình orbit |
| GET | `/api/fleetd/certificates/{id}` | Lấy certificate template |
| PUT | `/api/fleetd/certificates/{id}/status` | Cập nhật trạng thái certificate |

---

*Tài liệu này được tạo tự động bằng cách phân tích toàn bộ mã nguồn Fleet Android Agent. Tham khảo các file `.kt` tương ứng để xem chi tiết từng dòng code.*
