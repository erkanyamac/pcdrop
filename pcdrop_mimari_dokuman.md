# Proje Adı: PCDrop (iPadOS & Windows Kablosuz Dosya Transfer Sistemi)

> **AI Asistanı (GitHub Copilot / Cursor) İçin Yönerge:**
> Bu doküman, iPadOS ve Windows PC arasında yerel ağ (LAN) üzerinden çalışan, sıfır yapılandırma (Zero-Conf) gerektiren, AirDrop benzeri bir dosya paylaşım uygulamasının tam teknik şartnamesidir. Kod üretimi yaparken bu dokümandaki paket isimlerine, port numaralarına, JSON şemalarına, klasör yapısına ve işletim sistemi izinlerine birebir sadık kal. Masaüstü hedefi olarak yalnızca **Windows** desteklenecektir.

## 1. Proje Özeti ve Hedefler

**PCDrop**, aynı yerel ağ (Wi-Fi/Ethernet) üzerindeki bir iPad ve Windows PC arasında, internet bağlantısı veya harici bir sunucu gerektirmeden yüksek hızlı, şifreli dosya ve metin aktarımı sağlayan bir uygulamadır.

### Temel Özellikler (MVP)

1. **Otomatik Keşif (Auto-Discovery):** iPad ve Windows PC aynı ağa bağlandığında birbirlerini mDNS (Multicast DNS / Bonjour) ile otomatik olarak bulur.

2. **iPadOS Paylaşım Menüsü (Share Extension):** Kullanıcı iPad'de Fotoğraflar veya Dosyalar uygulamasında "Paylaş" butonuna bastığında PCDrop ikonunu görür ve uygulamayı açmadan doğrudan Windows PC'ye dosya gönderebilir.

3. **Çift Yönlü Aktarım:** Hem iPad'den Windows PC'ye hem de Windows PC'den iPad'e çoklu dosya, klasör veya pano (clipboard) metni gönderilebilir.

4. **Akış Tabanlı Transfer (Streaming):** Büyük dosyalar (örn. 4K videolar) RAM'i şişirmeden doğrudan diske/akışa (Chunked HTTP Stream) yazılır.

5. **PIN / Onay Mekanizması:** Alıcı ekranda göndericinin adını, dosya sayısını ve boyutunu görür; "Kabul Et" veya "Reddet" seçeneğine tıklar.

## 2. Teknoloji Yığını (Tech Stack)

Tek kod tabanıyla hem iPadOS hem de Windows hedefleneceği için **Flutter (Dart)** kullanılacaktır.

### Gerekli Donanım ve Yazılımlar (Geliştirici İçin)

* **Windows PC:** Ana geliştirme ortamı ve Windows masaüstü derlemesi (Visual Studio C++ Masaüstü Geliştirme iş yükü yüklü olmalıdır).

* **macOS veya Bulut CI/CD (GitHub Actions / Codemagic):** iPadOS derlemesi ve Share Extension imzalaması için.

* **Flutter SDK:** `>=3.19.0` (Dart `>=3.3.0`)

### Kullanılacak Flutter Paketleri (`pubspec.yaml`)

```yaml
name: pcdrop
description: iPadOS ve Windows PC arasi kablosuz dosya transfer uygulamasi.
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: '>=3.3.0 <4.0.0'

dependencies:
  flutter:
    sdk: flutter
  # Ağ ve Keşif (Discovery & Server)
  bonsoir: ^5.1.0              # mDNS / Bonjour servis yayını ve keşfi
  shelf: ^1.4.1                # Yerel HTTP sunucusu (Dosya almak için)
  shelf_router: ^1.1.4         # HTTP uç noktalarını (endpoint) yönlendirmek için
  dio: ^5.4.0                  # HTTP istemcisi (Dosya göndermek ve ilerlemeyi takip etmek için)
  # Yerel IPv4 adresleri dart:io NetworkInterface.list() ile alınır.
  
  # Dosya ve Windows / iPadOS İşletim Sistemi Entegrasyonu
  receive_sharing_intent: ^1.6.7 # iPadOS Share Extension'dan gelen dosyaları yakalamak için
  file_picker: ^8.0.0          # Uygulama içinden dosya seçmek için
  path_provider: ^2.1.2        # Windows İndirilenler klasörü ve iPadOS dizinlerini bulmak için
  desktop_drop: ^0.4.4         # Windows PC'de sürükle-bırak (Drag & Drop) desteği
  
  # Durum Yönetimi ve Yardımcılar
  flutter_riverpod: ^2.5.1     # State Management
  uuid: ^4.3.3                 # Benzersiz cihaz ve oturum ID'leri için
  crypto: ^3.0.3               # Dosya bütünlüğü (SHA-256) doğrulaması için
  device_info_plus: ^10.0.1    # Cihaz adını ("Ahmet'in iPad'i" / "Masaüstü-PC") almak için
```

## 3. Sistem Mimarisi ve İletişim Protokolü

Sistemde merkezi bir sunucu yoktur. **Her cihaz (iPad ve Windows PC) aynı anda hem bir HTTP Sunucusu (Alıcı) hem de bir HTTP İstemcisidir (Gönderici).**

```
+---------------------------------------------------+
|                    YEREL AĞ (LAN)                 |
|                                                   |
|  +-----------------+         +-----------------+  |
|  |     iPadOS      |         |   Windows PC    |  |
|  |-----------------|         |-----------------|  |
|  | mDNS Broadcast  |<------->| mDNS Listener   |  |
|  | (UDP Port 5353) |         | (UDP Port 5353) |  |
|  |                 |         |                 |  |
|  | HTTP Client     |========>| HTTP Server     |  |
|  | (Dio Stream)    | TCP/IP  | (Shelf :53317)  |  |
|  +-----------------+         +-----------------+  |
+---------------------------------------------------+
```

### 3.1. Adım 1: Cihaz Keşfi (mDNS / Bonjour)

Uygulama açıldığında her cihaz yerel ağda bir mDNS servisi başlatır ve aynı zamanda diğer servisleri dinler.

* **Servis Tipi:** `_pcdrop._tcp`

* **Varsayılan Port:** `53317` (Eğer doluysa dinamik port seçilir ve mDNS TXT kaydında bildirilir).

* **mDNS TXT Kaydı (Metadata):**

  ```json
  {
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "alias": "Deniz Windows PC",
    "deviceModel": "Windows 11 Pro",
    "os": "windows",
    "port": "53317",
    "version": "1.0"
  }
  ```
  *(Not: `os` alanı yalnızca `"windows"` veya `"ipados"` değerlerini alabilir.)*

### 3.2. Adım 2: El Sıkışma ve Transfer Onayı (Handshake)

Gönderici (örn. iPad), Alıcıya (örn. Windows PC) dosya göndermeden önce alıcıdan izin ister.

* **Endpoint:** `POST http://{ALICI_IP}:53317/api/v1/prepare-upload`

* **İstek Gövdesi (Request Body - JSON):**

  ```json
  {
    "sessionId": "session-98765",
    "sender": {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "alias": "Deniz iPad Air",
      "os": "ipados"
    },
    "files": [
      {
        "fileId": "file-1",
        "fileName": "sunum_notlari.pdf",
        "size": 4582912,
        "mimeType": "application/pdf",
        "sha256": "a1b2c3d4..."
      },
      {
        "fileId": "file-2",
        "fileName": "IMG_2048.MOV",
        "size": 154829120,
        "mimeType": "video/quicktime",
        "sha256": null
      }
    ]
  }
  ```

* **Alıcı Davranışı:** Alıcı Windows PC'de bir bildirim/pencere açılır: *"Deniz iPad Air size 2 dosya (152 MB) göndermek istiyor. Kabul ediyor musunuz?"*

* **Yanıt Gövdesi (Response Body - JSON):**

  * **Kabul Edilirse (`200 OK`):**

    ```json
    {
      "status": "ACCEPTED",
      "sessionId": "session-98765",
      "uploadToken": "secret-jwt-or-random-token-12345",
      "acceptedFileIds": ["file-1", "file-2"]
    }
    ```

  * **Reddedilirse (`403 Forbidden`):**

    ```json
    {
      "status": "REJECTED"
    }
    ```

### 3.3. Adım 3: Dosya Aktarımı (Binary Streaming)

Onay alındıktan sonra gönderici, her bir dosyayı sırayla veya paralel olarak binary stream şeklinde gönderir. `multipart/form-data` yerine doğrudan **Raw Binary Stream** (`application/octet-stream`) kullanılır; bu sayede bellek (RAM) kullanımı sıfıra yakın olur.

* **Endpoint:** `POST http://{ALICI_IP}:53317/api/v1/upload?sessionId=session-98765&fileId=file-1&token=secret-jwt-or-random-token-12345`

* **Headers:**

  * `Content-Type: application/octet-stream`

  * `Content-Length: 4582912`

  * `x-file-name: sunum_notlari.pdf` (URL Encoded)

* **Alıcı (Server) Mantığı:**
  Gelen `Request.read()` (Stream) doğrudan `File(savePath).openWrite()` (IOSink) içine `.pipe()` metodu ile bağlanır. Windows'ta varsayılan kayıt yeri kullanıcının `Downloads\PCDrop` klasörüdür.

## 4. Önerilen Proje Klasör Yapısı (Clean Architecture)

GitHub Copilot'un dosyaları oluştururken takip edeceği dizin yapısı:

```
lib/
├── main.dart
├── core/
│   ├── constants/
│   │   └── network_constants.dart    # Port (53317), servis tipi (_pcdrop._tcp)
│   ├── utils/
│   │   ├── ip_helper.dart            # Yerel IP bulucu
│   │   └── file_utils.dart           # Boyut formatlama, Windows/iPadOS güvenli dosya yolu oluşturma
│   └── theme/
│       └── app_theme.dart
├── data/
│   ├── models/
│   │   ├── peer_device.dart          # Keşfedilen cihaz modeli
│   │   ├── transfer_session.dart     # Oturum ve durum modeli
│   │   └── file_metadata.dart        # Dosya bilgileri modeli
│   └── services/
│       ├── mdns_discovery_service.dart # Bonsoir ile yayın ve dinleme
│       ├── local_http_server.dart      # Shelf tabanlı alıcı sunucu
│       ├── file_sender_client.dart     # Dio tabanlı gönderici istemci
│       └── share_intent_service.dart   # iPadOS Share menüsünden veri yakalayıcı (Sadece iOS'ta aktif)
├── providers/
│   ├── discovery_provider.dart       # Aktif cihaz listesi state'i
│   └── transfer_provider.dart        # Aktif indirme/yükleme yüzdesi state'i
└── ui/
    ├── screens/
    │   ├── home_screen.dart          # Radar ekranı (bulunan cihazlar) ve Windows sürükle-bırak alanı
    │   └── settings_screen.dart      # Cihaz adı, Windows kayıt klasörü ayarları
    └── widgets/
        ├── radar_avatar_widget.dart  # AirDrop tarzı cihaz ikonu
        ├── incoming_request_dialog.dart # "Kabul Et / Reddet" pop-up'ı
        └── transfer_progress_sheet.dart # İlerleme çubuğu ve hız göstergesi
```

## 5. İşletim Sistemi Özel Ayarları ve İzinler (Kritik Bölüm)

Uygulamanın yerel ağda çalışabilmesi ve iPadOS Paylaş menüsünde görünebilmesi için aşağıdaki yapılandırmalar **zorunludur**.

### 5.1. iPadOS (`ios/Runner/Info.plist`) İzinleri

Apple, iOS 14'ten itibaren yerel ağda mDNS araması yapmak için özel izinler ister. `Info.plist` dosyasına şunlar eklenmelidir:

```xml
<!-- Yerel Ağ İzni Açıklaması -->
<key>NSLocalNetworkUsageDescription</key>
<string>PCDrop, aynı Wi-Fi ağındaki Windows bilgisayarınızı bulmak ve dosya göndermek için yerel ağı kullanır.</string>

<!-- Aranacak mDNS Servis Tipi -->
<key>NSBonjourServices</key>
<array>
    <string>_pcdrop._tcp</string>
</array>

<!-- Dosyalara Erişim ve Arka Plan İzinleri -->
<key>UIFileSharingEnabled</key>
<true/>
<key>LSSupportsOpeningDocumentsInPlace</key>
<true/>
```

### 5.2. iPadOS "Share Extension" (Paylaşım Menüsü) Kurulumu

iPad'de herhangi bir uygulamada "Paylaş"a basıldığında PCDrop'un çıkması için:

1. Xcode'da `Runner` projesi açılır -> `File > New > Target > Share Extension` seçilir ve adına `ShareExtension` verilir.

2. Hem ana uygulama (`Runner`) hem de `ShareExtension` için `Signing & Capabilities` altından **App Groups** aktif edilir ve her ikisine de aynı grup adı verilir: `group.com.ornek.pcdrop`.

3. `receive_sharing_intent` paketinin iOS Swift kodu `ShareViewController.swift` içine yerleştirilir. Bu kod, paylaşılan dosyanın yolunu paylaşımlı App Group klasörüne yazar ve ana Flutter uygulamasını (`pcdrop://share`) URL şemasıyla otomatik olarak uyandırır.

### 5.3. Windows PC Güvenlik Duvarı (Firewall) ve Platform Kontrolleri

* **Platform Kontrolü:** `receive_sharing_intent` yalnızca iOS/Android desteklediği için kod içinde mutlaka `if (Platform.isIOS)` kontrolü ile çağrılmalı, `Platform.isWindows` iken devre dışı bırakılmalıdır.

* **Windows Defender Güvenlik Duvarı:** Windows'ta `shelf` sunucusu `0.0.0.0:53317` portunu dinlemeye başladığında Güvenlik Duvarı uyarı verecektir. Geliştirme aşamasında açılan pencerede **"Özel Ağlar (Private Networks)"** ve **"Ortak Ağlar (Public Networks)"** kutucuklarına izin verilmelidir.

* Kurulum paketi (Inno Setup) hazırlanırken aşağıdaki komutlar kurulum scriptine eklenmelidir:

  ```cmd
  netsh advfirewall firewall add rule name="PCDrop Local Server" dir=in action=allow protocol=TCP localport=53317
  netsh advfirewall firewall add rule name="PCDrop mDNS" dir=in action=allow protocol=UDP localport=5353
  ```

## 6. Temel Modüllerin Kod İskeletleri (AI Referansı İçin)

GitHub Copilot'un kod üretirken baz alması gereken çekirdek servis mantıkları aşağıdadır:

### A. Alıcı HTTP Sunucusu (`local_http_server.dart` Özeti)

```dart
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

class LocalHttpServer {
  HttpServer? _server;

  Future<void> startServer(int port, String saveDirectory) async {
    final router = Router();

    // 1. El sıkışma (Handshake) Uç Noktası
    router.post('/api/v1/prepare-upload', (Request request) async {
      final payload = await request.readAsString();
      // JSON'u parse et, UI'da kullanıcıya "Kabul ediyor musun?" diye sor.
      // Kabul edilirse 200 OK ve token dön.
      return Response.ok('{"status": "ACCEPTED", "uploadToken": "xyz"}',
          headers: {'content-type': 'application/json'});
    });

    // 2. Akış (Stream) Tabanlı Dosya Alma Uç Noktası
    router.post('/api/v1/upload', (Request request) async {
      final rawFileName = request.headers['x-file-name'] ?? 'received_file.bin';
      final fileName = Uri.decodeComponent(rawFileName);
      
      final file = File('$saveDirectory${Platform.pathSeparator}$fileName');
      final sink = file.openWrite();

      try {
        // RAM kullanmadan ağdan gelen veriyi doğrudan diske yaz
        await request.read().pipe(sink);
        return Response.ok('{"status": "COMPLETED"}');
      } catch (e) {
        await sink.close();
        return Response.internalServerError(body: e.toString());
      }
    });

    _server = await shelf_io.serve(router, InternetAddress.anyIPv4, port);
  }
}
```

### B. Akış Tabanlı Dosya Gönderici (`file_sender_client.dart` Özeti)

```dart
import 'dart:io';
import 'package:dio/dio.dart';

class FileSenderClient {
  final Dio _dio = Dio();

  Future<void> sendFileStream({
    required String targetIp,
    required int targetPort,
    required File file,
    required Function(int sent, int total) onProgress,
  }) async {
    final fileSize = await file.length();
    final fileName = file.uri.pathSegments.last;

    await _dio.post(
      'http://$targetIp:$targetPort/api/v1/upload?fileId=1',
      data: file.openRead(), // Dosyayı RAM'e yüklemeden Stream olarak okur
      options: Options(
        headers: {
          Headers.contentLengthHeader: fileSize,
          Headers.contentTypeHeader: 'application/octet-stream',
          'x-file-name': Uri.encodeComponent(fileName),
        },
      ),
      onSendProgress: onProgress,
    );
  }
}
```

## 7. Copilot İle Adım Adım Geliştirme Planı (Prompt Sırası)

Bu dokümanı proje klasörünüzün ana dizinine `PROJECT_SPECIFICATION.md` adıyla kaydettikten sonra, GitHub Copilot Chat ekranına sırasıyla şu komutları (prompt) vererek tüm projeyi yazdırabilirsiniz:

1. **Adım 1 (Kurulum ve Modeller):**

   > `@workspace #file:PROJECT_SPECIFICATION.md dokümanını incele. Öncelikle pubspec.yaml dosyasını PCDrop adına uygun olarak oluştur ve Bölüm 4'teki klasör yapısına uygun olarak data/models altındaki tüm model sınıflarını (toJson/fromJson metodlarıyla birlikte) yaz.`

2. **Adım 2 (mDNS Keşif Servisi):**

   > `#file:PROJECT_SPECIFICATION.md Bölüm 3.1'deki kurallara göre bonsoir paketini kullanarak mdns_discovery_service.dart dosyasını yaz. Hem kendi servisini yayınlasın hem de ağdaki diğer _pcdrop._tcp cihazlarını bulup bir Stream olarak döndürsün.`

3. **Adım 3 (Sunucu ve İstemci):**

   > `#file:PROJECT_SPECIFICATION.md Bölüm 3.2, 3.3 ve Bölüm 6'yı referans alarak local_http_server.dart ve file_sender_client.dart dosyalarını eksiksiz şekilde yaz. Windows dosya yolu ayracı (Platform.pathSeparator) uyumluluğuna dikkat et ve aynı isimli dosya varsa üzerine yazmamak için sonuna (1), (2) ekleyen güvenlik kontrolünü ekle.`

4. **Adım 4 (State Management ve Arayüz):**

   > `Riverpod kullanarak discovery_provider.dart ve transfer_provider.dart dosyalarını oluştur. Ardından AirDrop benzeri radar görünümüne sahip home_screen.dart ekranını, Windows PC için sürükle-bırak (desktop_drop) desteğini ve gelen dosya onay penceresini (incoming_request_dialog.dart) kodla.`

5. **Adım 5 (iPadOS Share Extension):**

   > `Yalnızca Platform.isIOS üzerinde çalışacak şekilde, iPadOS'ta başka bir uygulamadan dosya paylaşıldığında bunu yakalayıp doğrudan aktif cihaz seçme ekranına yönlendiren share_intent_service.dart sınıfını receive_sharing_intent paketini kullanarak yaz.`