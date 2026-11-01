abstract final class NetworkConstants {
  static const int defaultPort = 53317;
  static const int mdnsPort = 5353;
  static const String serviceType = '_pcdrop._tcp';
  static const String protocolVersion = '1.0';

  static const String prepareUploadPath = '/api/v1/prepare-upload';
  static const String uploadPath = '/api/v1/upload';
  static const String contentTypeJson = 'application/json';
  static const String contentTypeOctetStream = 'application/octet-stream';
}
