import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../domain/models/models.dart';
import '../../ui/core/app_lock_guard.dart';
import '../../ui/features/invoices/invoice_formatters.dart';

enum WifiPrintProtocol {
  ippPdf('ipp', 'Wi-Fi IPP (Port 631)', 631),
  rawPdf9100('raw9100', 'Direct LAN PDF (Port 9100)', 9100),
  escPos9100('escpos9100', 'ESC/POS Thermal (Port 9100)', 9100);

  const WifiPrintProtocol(this.id, this.label, this.defaultPort);

  final String id;
  final String label;
  final int defaultPort;

  static WifiPrintProtocol fromId(String? id) {
    for (final val in values) {
      if (val.id == id) return val;
    }
    return WifiPrintProtocol.ippPdf;
  }
}

enum PrintPaperFormat {
  a4('a4', 'A4'),
  letter('letter', 'Letter'),
  roll80('roll80', '80mm Roll'),
  roll58('roll58', '58mm Roll');

  const PrintPaperFormat(this.id, this.label);

  final String id;
  final String label;

  bool get isThermalRoll => this == roll80 || this == roll58;
  int get escPosColumns => this == roll58 ? 32 : 48;

  PdfPageFormat get pdfPageFormat {
    switch (this) {
      case PrintPaperFormat.a4:
        return PdfPageFormat.a4;
      case PrintPaperFormat.letter:
        return PdfPageFormat.letter;
      case PrintPaperFormat.roll80:
        return PdfPageFormat.roll80;
      case PrintPaperFormat.roll58:
        return PdfPageFormat.roll57;
    }
  }

  static PrintPaperFormat fromId(String? id) {
    for (final val in values) {
      if (val.id == id) return val;
    }
    return PrintPaperFormat.a4;
  }
}

class SavedPrinterConfig {
  const SavedPrinterConfig({
    this.host = '',
    this.port = 631,
    this.protocol = WifiPrintProtocol.ippPdf,
    this.paperFormat = PrintPaperFormat.a4,
  });

  final String host;
  final int port;
  final WifiPrintProtocol protocol;
  final PrintPaperFormat paperFormat;

  bool get hasHost => host.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
        'host': host.trim(),
        'port': port,
        'protocol': protocol.id,
        'paperFormat': paperFormat.id,
      };

  factory SavedPrinterConfig.fromJson(Map<String, dynamic> json) {
    final protocol = WifiPrintProtocol.fromId(json['protocol']?.toString());
    final rawPort = json['port'];
    final parsedPort = rawPort is int
        ? rawPort
        : int.tryParse(rawPort?.toString() ?? '') ?? protocol.defaultPort;
    return SavedPrinterConfig(
      host: (json['host'] ?? '').toString().trim(),
      port: parsedPort > 0 && parsedPort <= 65535
          ? parsedPort
          : protocol.defaultPort,
      protocol: protocol,
      paperFormat: PrintPaperFormat.fromId(json['paperFormat']?.toString()),
    );
  }
}

class DiscoveredLanPrinter {
  const DiscoveredLanPrinter({
    required this.host,
    required this.port,
    required this.protocol,
  });

  final String host;
  final int port;
  final WifiPrintProtocol protocol;

  String get displayLabel => '$host:$port (${protocol.label})';
}

typedef TcpSocketSender = Future<void> Function(
  String host,
  int port,
  Uint8List bytes,
  Duration timeout,
);

typedef TcpPortProber = Future<bool> Function(
  String host,
  int port,
  Duration timeout,
);

typedef LocalIpv4AddressesProvider = Future<List<String>> Function();

/// Universal printing service supporting:
/// 1. Android System Print Spooler (Mopria / Wi-Fi Direct / Vendor Print Services / USB OTG / Save PDF)
/// 2. Direct Wi-Fi / LAN IPP (`Print-Job` over Port 631)
/// 3. Direct Raw TCP JetDirect PDF Streaming (Port 9100)
/// 4. Direct Wi-Fi ESC/POS Thermal Receipt Printing (80mm / 58mm, Port 9100)
/// 5. External Printer Bridge / App Share (RawBT Bluetooth / PrinterShare / Save & Open PDF)
class PrintService {
  PrintService({
    http.Client? httpClient,
    TcpSocketSender? tcpSender,
    TcpPortProber? portProber,
    LocalIpv4AddressesProvider? localIpProvider,
  })  : _http = httpClient ?? http.Client(),
        _tcpSender = tcpSender ?? _defaultTcpSend,
        _portProber = portProber ?? _defaultPortProbe,
        _localIpProvider = localIpProvider ?? _defaultLocalIpv4Addresses;

  final http.Client _http;
  final TcpSocketSender _tcpSender;
  final TcpPortProber _portProber;
  final LocalIpv4AddressesProvider _localIpProvider;

  static Future<void> _defaultTcpSend(
    String host,
    int port,
    Uint8List bytes,
    Duration timeout,
  ) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    try {
      socket.add(bytes);
      await socket.flush().timeout(timeout);
    } finally {
      await socket.close().catchError((_) {});
    }
  }

  static Future<bool> _defaultPortProbe(
    String host,
    int port,
    Duration timeout,
  ) async {
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: timeout);
      return true;
    } catch (_) {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  static Future<List<String>> _defaultLocalIpv4Addresses() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    final addresses = <String>[];
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        final ip = addr.address.trim();
        if (ip.isNotEmpty && !ip.startsWith('127.') && !ip.startsWith('169.254.')) {
          addresses.add(ip);
        }
      }
    }
    return addresses;
  }

  /// Parses `192.168.1.50`, `192.168.1.50:9100`, or `ipp://192.168.1.50:631/ipp/print`
  /// cleanly into host + port.
  static ({String host, int port}) parseHostAndPort(
    String rawInput, {
    int fallbackPort = 631,
  }) {
    final trimmed = rawInput.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Enter a printer IP address or hostname.');
    }

    if (trimmed.contains('://')) {
      final uri = Uri.tryParse(trimmed);
      if (uri != null && uri.host.isNotEmpty) {
        final p = uri.hasPort && uri.port > 0 && uri.port <= 65535
            ? uri.port
            : fallbackPort;
        return (host: uri.host, port: p);
      }
    }

    final colonIdx = trimmed.lastIndexOf(':');
    if (colonIdx > 0 && colonIdx < trimmed.length - 1) {
      final hostPart = trimmed.substring(0, colonIdx).trim();
      final portPart = int.tryParse(trimmed.substring(colonIdx + 1).trim());
      if (portPart != null && portPart > 0 && portPart <= 65535) {
        return (host: hostPart, port: portPart);
      }
    }

    return (host: trimmed, port: fallbackPort);
  }

  /// Scans the phone's local Wi-Fi `/24` subnet(s) in fast parallel batches for
  /// active IPP (631) and Raw/ESC-POS (9100) printers.
  Future<List<DiscoveredLanPrinter>> discoverLanPrinters({
    Duration probeTimeout = const Duration(milliseconds: 550),
    int concurrency = 36,
  }) async {
    final localIps = await _localIpProvider();
    if (localIps.isEmpty) return const [];

    final prefixes = <String>{};
    for (final ip in localIps) {
      final octets = ip.split('.');
      if (octets.length == 4) {
        prefixes.add('${octets[0]}.${octets[1]}.${octets[2]}');
      }
    }
    if (prefixes.isEmpty) return const [];

    final candidates = <({String host, int port, WifiPrintProtocol protocol})>[];
    for (final prefix in prefixes) {
      for (var lastOctet = 1; lastOctet <= 254; lastOctet++) {
        final host = '$prefix.$lastOctet';
        if (localIps.contains(host)) continue;
        candidates.add((
          host: host,
          port: 631,
          protocol: WifiPrintProtocol.ippPdf,
        ));
        candidates.add((
          host: host,
          port: 9100,
          protocol: WifiPrintProtocol.rawPdf9100,
        ));
      }
    }

    final found = <DiscoveredLanPrinter>[];
    for (var i = 0; i < candidates.length; i += concurrency) {
      final end = (i + concurrency).clamp(0, candidates.length);
      final batch = candidates.sublist(i, end);
      final results = await Future.wait(
        batch.map((c) async {
          final open = await _portProber(c.host, c.port, probeTimeout);
          return open
              ? DiscoveredLanPrinter(
                  host: c.host,
                  port: c.port,
                  protocol: c.protocol,
                )
              : null;
        }),
      );
      for (final item in results) {
        if (item != null) found.add(item);
      }
    }

    found.sort((a, b) {
      final hostCmp = a.host.compareTo(b.host);
      return hostCmp != 0 ? hostCmp : a.port.compareTo(b.port);
    });
    return found;
  }

  /// Opens Android's native System Print Dialog (Mopria, Wi-Fi Direct, USB, Save as PDF).
  Future<bool> printViaSystem({
    required String documentName,
    required PdfPageFormat format,
    required FutureOr<Uint8List> Function(PdfPageFormat format) onLayout,
  }) async {
    return AppLockGuard.runWithoutRelock(
      () => Printing.layoutPdf(
        name: documentName,
        format: format,
        onLayout: onLayout,
      ),
    );
  }

  /// Shares PDF bytes to any installed print bridge (RawBT, PrinterShare, etc.) or app.
  Future<void> sharePdfToApps({
    required Uint8List bytes,
    required String filename,
    String? subject,
    String? text,
  }) async {
    final file = await writeTempPdf(bytes: bytes, filename: filename);
    await AppLockGuard.runWithoutRelock(
      () => Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/pdf', name: filename)],
        subject: subject,
        text: text,
      ),
    );
  }

  /// Writes PDF bytes to temp storage and opens it in the device PDF viewer / print menu.
  Future<OpenResult> openTempPdf({
    required Uint8List bytes,
    required String filename,
  }) async {
    final file = await writeTempPdf(bytes: bytes, filename: filename);
    return AppLockGuard.runWithoutRelock(() => OpenFilex.open(file.path));
  }

  Future<File> writeTempPdf({
    required Uint8List bytes,
    required String filename,
  }) async {
    final dir = await getTemporaryDirectory();
    final safeName = filename.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final file = File('${dir.path}/$safeName');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// Sends a document directly to a Wi-Fi / LAN printer using IPP (631) or Raw TCP (9100).
  Future<String> sendDirectWifiPrint({
    required String hostInput,
    required int port,
    required WifiPrintProtocol protocol,
    required String jobName,
    required Uint8List pdfBytes,
    Uint8List? escPosBytes,
    int copies = 1,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final parsed = parseHostAndPort(hostInput, fallbackPort: port);
    final safeCopies = copies.clamp(1, 20);

    switch (protocol) {
      case WifiPrintProtocol.ippPdf:
        await _sendIppPrintJob(
          host: parsed.host,
          port: parsed.port,
          jobName: jobName,
          pdfBytes: pdfBytes,
          copies: safeCopies,
          timeout: timeout,
        );
        return 'Sent $safeCopies cop${safeCopies == 1 ? 'y' : 'ies'} to Wi-Fi printer ${parsed.host}:${parsed.port} (IPP).';
      case WifiPrintProtocol.rawPdf9100:
        if (pdfBytes.isEmpty) {
          throw StateError('Generated PDF is empty.');
        }
        for (var c = 0; c < safeCopies; c++) {
          await _tcpSender(parsed.host, parsed.port, pdfBytes, timeout);
        }
        return 'Sent $safeCopies cop${safeCopies == 1 ? 'y' : 'ies'} directly to ${parsed.host}:${parsed.port} (LAN RAW).';
      case WifiPrintProtocol.escPos9100:
        final thermal = escPosBytes;
        if (thermal == null || thermal.isEmpty) {
          throw StateError(
            'ESC/POS thermal mode requires receipt data. Switch to Wi-Fi IPP (631) or Direct LAN PDF (9100).',
          );
        }
        for (var c = 0; c < safeCopies; c++) {
          await _tcpSender(parsed.host, parsed.port, thermal, timeout);
        }
        return 'Printed $safeCopies thermal receipt cop${safeCopies == 1 ? 'y' : 'ies'} on ${parsed.host}:${parsed.port}.';
    }
  }

  Future<void> _sendIppPrintJob({
    required String host,
    required int port,
    required String jobName,
    required Uint8List pdfBytes,
    required int copies,
    required Duration timeout,
  }) async {
    const candidatePaths = ['/ipp/print', '/printers/default', '/ipp/printer', '/'];
    Object? lastError;

    for (final path in candidatePaths) {
      final ippPayload = buildIppPrintJobPayload(
        printerUri: 'ipp://$host:$port$path',
        jobName: jobName,
        documentBytes: pdfBytes,
        copies: copies,
      );
      final uri = Uri.parse('http://$host:$port$path');
      try {
        final response = await _http
            .post(
              uri,
              headers: const {'Content-Type': 'application/ipp'},
              body: ippPayload,
            )
            .timeout(timeout);

        if (response.statusCode == 404 || response.statusCode == 405) {
          lastError = StateError('IPP endpoint $path returned HTTP ${response.statusCode}');
          continue;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw StateError(
            'Printer rejected IPP job (HTTP ${response.statusCode}).',
          );
        }
        final ippStatus = parseIppStatusCode(response.bodyBytes);
        if (ippStatus != null && ippStatus >= 0x0100) {
          throw StateError(
            'Printer returned IPP error code 0x${ippStatus.toRadixString(16).padLeft(4, '0')}.',
          );
        }
        return;
      } catch (err) {
        lastError = err;
        if (err is SocketException || err is TimeoutException) {
          rethrow;
        }
      }
    }

    if (lastError != null) {
      throw lastError;
    }
    throw StateError('Could not complete IPP print job on $host:$port.');
  }

  /// Extracts IPP 16-bit status code from response bytes `[major, minor, statusHi, statusLo, ...]`.
  @visibleForTesting
  static int? parseIppStatusCode(Uint8List responseBytes) {
    if (responseBytes.length < 4) return null;
    return (responseBytes[2] << 8) | responseBytes[3];
  }

  /// Encodes an RFC 8010/8011 binary IPP/2.0 `Print-Job` (`0x0002`) request.
  @visibleForTesting
  static Uint8List buildIppPrintJobPayload({
    required String printerUri,
    required String jobName,
    required Uint8List documentBytes,
    int copies = 1,
    String mimeType = 'application/pdf',
  }) {
    final builder = BytesBuilder(copy: false);

    // IPP/2.0 header: version 2.0, operation Print-Job (0x0002), requestId = 1
    builder.add([0x02, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01]);

    // Operation attributes group
    builder.addByte(0x01);
    _writeIppAttribute(builder, 0x47, 'attributes-charset', utf8.encode('utf-8'));
    _writeIppAttribute(
      builder,
      0x48,
      'attributes-natural-language',
      utf8.encode('en'),
    );
    _writeIppAttribute(builder, 0x45, 'printer-uri', utf8.encode(printerUri));
    _writeIppAttribute(
      builder,
      0x42,
      'requesting-user-name',
      utf8.encode('TownTreasure'),
    );
    final cleanJob = jobName.replaceAll(RegExp(r'[^\x20-\x7E]'), '').trim();
    _writeIppAttribute(
      builder,
      0x42,
      'job-name',
      utf8.encode(cleanJob.isEmpty ? 'TownTreasureDoc' : cleanJob),
    );
    _writeIppAttribute(builder, 0x49, 'document-format', utf8.encode(mimeType));

    if (copies > 1) {
      // Job attributes group
      builder.addByte(0x02);
      final bd = ByteData(4)..setInt32(0, copies, Endian.big);
      _writeIppAttribute(builder, 0x21, 'copies', bd.buffer.asUint8List());
    }

    // End of attributes tag followed immediately by PDF document data
    builder.addByte(0x03);
    builder.add(documentBytes);
    return builder.toBytes();
  }

  static void _writeIppAttribute(
    BytesBuilder builder,
    int valueTag,
    String name,
    List<int> valueBytes,
  ) {
    final nameBytes = utf8.encode(name);
    builder.addByte(valueTag);
    builder.add([(nameBytes.length >> 8) & 0xFF, nameBytes.length & 0xFF]);
    builder.add(nameBytes);
    builder.add([(valueBytes.length >> 8) & 0xFF, valueBytes.length & 0xFF]);
    builder.add(valueBytes);
  }
}

/// Clean ESC/POS thermal receipt command generator (works on 80mm/48-col and 58mm/32-col printers).
class EscPosReceiptBuilder {
  EscPosReceiptBuilder._();

  static Uint8List buildInvoicesReceipt({
    required List<Invoice> invoices,
    required List<Restaurant> restaurants,
    int lineWidth = 48,
  }) {
    final buf = BytesBuilder(copy: false);
    // ESC @ (Initialize printer)
    buf.add([0x1B, 0x40]);

    for (var i = 0; i < invoices.length; i++) {
      final inv = invoices[i];
      final restName = Restaurant.invoiceDisplayName(inv, restaurants);

      // Center, bold, double size title
      buf.add([0x1B, 0x61, 0x01, 0x1B, 0x45, 0x01, 0x1D, 0x21, 0x11]);
      _writeLine(buf, 'TOWN TREASURE');
      buf.add([0x1D, 0x21, 0x00, 0x1B, 0x45, 0x00]);
      _writeLine(buf, 'Town Treasure Limited - Fresh Produce');
      _writeLine(buf, 'Tel: 0708567696');
      _writeLine(buf, '-' * lineWidth);

      // Left align metadata
      buf.add([0x1B, 0x61, 0x00]);
      _writeLine(
        buf,
        _twoCol('INV: ${inv.number}', inv.status.toUpperCase(), lineWidth),
      );
      _writeLine(buf, 'Client: ${_truncate(restName, lineWidth - 8)}');
      _writeLine(
        buf,
        'Date: ${InvoiceFormatters.formatDisplayDate(inv.date)}',
      );
      _writeLine(buf, '=' * lineWidth);

      for (final item in inv.items) {
        _writeLine(buf, _truncate(item.desc, lineWidth));
        final qtyStr =
            '${item.qty == item.qty.roundToDouble() ? item.qty.toInt() : item.qty} ${item.unit} x ${InvoiceFormatters.formatMoney(item.sellPrice)}';
        final totStr = InvoiceFormatters.formatMoney(item.total);
        _writeLine(buf, _twoCol('  $qtyStr', totStr, lineWidth));
      }

      _writeLine(buf, '=' * lineWidth);
      buf.add([0x1B, 0x45, 0x01]);
      _writeLine(
        buf,
        _twoCol(
          'TOTAL (KES)',
          InvoiceFormatters.formatMoney(inv.totalSell),
          lineWidth,
        ),
      );
      buf.add([0x1B, 0x45, 0x00]);
      _writeLine(buf, '-' * lineWidth);
      buf.add([0x1B, 0x61, 0x01]);
      _writeLine(buf, 'Thank you for your business!');
      buf.add([0x1B, 0x64, 0x04]); // Feed 4 lines
      // GS V 66 0 (Partial cut)
      buf.add([0x1D, 0x56, 0x42, 0x00]);
    }

    return buf.toBytes();
  }

  static Uint8List buildSummaryReceipt({
    required String title,
    required List<String> lines,
    int lineWidth = 48,
  }) {
    final buf = BytesBuilder(copy: false);
    buf.add([0x1B, 0x40]);
    buf.add([0x1B, 0x61, 0x01, 0x1B, 0x45, 0x01]);
    _writeLine(buf, 'TOWN TREASURE GROCERIES');
    _writeLine(buf, _truncate(title.toUpperCase(), lineWidth));
    buf.add([0x1B, 0x45, 0x00, 0x1B, 0x61, 0x00]);
    _writeLine(buf, '=' * lineWidth);
    for (final line in lines) {
      _writeWrapped(buf, line, lineWidth);
    }
    _writeLine(buf, '-' * lineWidth);
    buf.add([0x1B, 0x64, 0x04, 0x1D, 0x56, 0x42, 0x00]);
    return buf.toBytes();
  }

  static void _writeLine(BytesBuilder buf, String text) {
    final ascii = text.replaceAll(RegExp(r'[^\x20-\x7E]'), ' ');
    buf.add(utf8.encode('$ascii\n'));
  }

  static void _writeWrapped(BytesBuilder buf, String text, int width) {
    if (text.length <= width) {
      _writeLine(buf, text);
      return;
    }
    for (var i = 0; i < text.length; i += width) {
      final end = (i + width).clamp(0, text.length);
      _writeLine(buf, text.substring(i, end));
    }
  }

  static String _truncate(String s, int maxLen) {
    if (maxLen <= 0) return '';
    if (s.length <= maxLen) return s;
    if (maxLen <= 3) return s.substring(0, maxLen);
    return '${s.substring(0, maxLen - 3)}...';
  }

  static String _twoCol(String left, String right, int width) {
    final gap = width - left.length - right.length;
    if (gap >= 1) return '$left${' ' * gap}$right';
    final trimmedLeft = _truncate(left, (width - right.length - 1).clamp(1, width));
    final nextGap = (width - trimmedLeft.length - right.length).clamp(1, width);
    return '$trimmedLeft${' ' * nextGap}$right';
  }
}
