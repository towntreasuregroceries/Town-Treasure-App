import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../../domain/models/models.dart';
import 'paddle_ocr_spatial_parser.dart';

export 'paddle_ocr_spatial_parser.dart';

/// Abstraction over Google ML Kit on-device text recognition for testability.
abstract class OcrTextRecognizerGateway {
  Future<String> recognizeTextFromFile(String filePath);
  Future<void> close();
}

/// Optional 2D layout capability for recognizers exposing bounding-box coordinates.
abstract class OcrSpatialRecognizerGateway {
  Future<List<OcrTextBox>> recognizeBoxesFromFile(String filePath);
}

/// Live Google ML Kit Latin script text recognizer with 2D bounding-box support.
class MlKitTextRecognizerGateway
    implements OcrTextRecognizerGateway, OcrSpatialRecognizerGateway {
  MlKitTextRecognizerGateway([TextRecognizer? recognizer])
      : _injectedRecognizer = recognizer;

  final TextRecognizer? _injectedRecognizer;
  TextRecognizer? _lazyRecognizer;

  TextRecognizer _getRecognizer() {
    if (_injectedRecognizer != null) return _injectedRecognizer;
    return _lazyRecognizer ??= TextRecognizer(
      script: TextRecognitionScript.latin,
    );
  }

  @override
  Future<String> recognizeTextFromFile(String filePath) async {
    final inputImage = InputImage.fromFilePath(filePath);
    final recognized = await _getRecognizer().processImage(inputImage);
    return recognized.text;
  }

  @override
  Future<List<OcrTextBox>> recognizeBoxesFromFile(String filePath) async {
    final inputImage = InputImage.fromFilePath(filePath);
    final recognized = await _getRecognizer().processImage(inputImage);
    final boxes = <OcrTextBox>[];
    for (final block in recognized.blocks) {
      for (final line in block.lines) {
        final txt = line.text.trim();
        if (txt.isEmpty) continue;
        final rect = line.boundingBox;
        boxes.add(
          OcrTextBox(
            text: txt,
            confidence: line.confidence ?? 0.85,
            centerX: rect.center.dx,
            centerY: rect.center.dy,
            width: rect.width,
            height: rect.height,
            angle: line.angle ?? 0,
            left: rect.left,
            top: rect.top,
            right: rect.right,
            bottom: rect.bottom,
          ),
        );
      }
    }
    return boxes;
  }

  @override
  Future<void> close() async {
    if (_injectedRecognizer != null) {
      await _injectedRecognizer.close();
      return;
    }
    if (_lazyRecognizer != null) {
      await _lazyRecognizer!.close();
      _lazyRecognizer = null;
    }
  }
}

/// Abstraction over `image_picker` for multi-photo camera/gallery capture.
abstract class ImagePickerGateway {
  Future<XFile?> pickCameraImage({int imageQuality = 85});
  Future<List<XFile>> pickGalleryImages({int imageQuality = 85});
}

/// Live `ImagePicker` wrapper supporting camera single-shot and gallery multi-select.
class DeviceImagePickerGateway implements ImagePickerGateway {
  DeviceImagePickerGateway([ImagePicker? picker])
      : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<XFile?> pickCameraImage({int imageQuality = 85}) {
    return _picker.pickImage(
      source: ImageSource.camera,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: imageQuality,
    );
  }

  @override
  Future<List<XFile>> pickGalleryImages({int imageQuality = 85}) {
    return _picker.pickMultiImage(
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: imageQuality,
    );
  }
}

/// Platform interface for picking a PDF document and rasterizing its pages
/// into local JPEG images for multi-page offline & cloud OCR.
abstract class PdfPagePickerGateway {
  Future<List<({String? filePath, Uint8List bytes})>> pickPdfRenderedPages();
}

/// Android `ACTION_OPEN_DOCUMENT` + `PdfRenderer` implementation via MethodChannel.
class MethodChannelPdfPagePickerGateway implements PdfPagePickerGateway {
  MethodChannelPdfPagePickerGateway([MethodChannel? channel])
      : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'com.towntreasuregroceries/pdf_picker';
  final MethodChannel _channel;

  @override
  Future<List<({String? filePath, Uint8List bytes})>> pickPdfRenderedPages() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const [];
    }
    final raw = await _channel.invokeListMethod<dynamic>('pickAndRenderPdf');
    if (raw == null) return const [];
    final pages = <({String? filePath, Uint8List bytes})>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final rawBytes = entry['bytes'];
      if (rawBytes is! Uint8List || rawBytes.isEmpty) continue;
      final path = entry['filePath']?.toString();
      pages.add((filePath: path, bytes: rawBytes));
    }
    return pages;
  }
}

/// Captured image page ready for OCR and receipt attachment.
class OcrImagePage {
  const OcrImagePage({
    required this.dataUrl,
    this.filePath,
    this.bytes,
  });

  final String dataUrl;
  final String? filePath;
  final Uint8List? bytes;
}

/// Structured docket extraction result from `OcrConsensusService.processDocket`.
class OcrDocketResult {
  const OcrDocketResult({
    required this.restaurantName,
    required this.invoiceNumber,
    required this.date,
    required this.items,
    required this.deliveryCost,
    required this.otherCost,
    required this.subtotal,
    required this.grandTotal,
    required this.csv,
    required this.enginesUsed,
    required this.confidence,
    required this.receiptPhoto,
    required this.receiptPhotos,
    required this.pageCount,
    this.rawMlKitText = '',
  });

  final String restaurantName;
  final String invoiceNumber;
  final String date;
  final List<InvoiceLineItem> items;
  final double deliveryCost;
  final double otherCost;
  final double subtotal;
  final double grandTotal;
  final String csv;
  final List<String> enginesUsed;
  final int confidence;
  final String? receiptPhoto;
  final List<String> receiptPhotos;
  final int pageCount;
  final String rawMlKitText;
}

/// Structured produce price list extraction result from `OcrConsensusService.processPriceList`.
class OcrPriceListResult {
  const OcrPriceListResult({
    required this.name,
    required this.subtitle,
    required this.effectiveDate,
    required this.items,
    required this.pageCount,
    required this.sourcePhotos,
    required this.enginesUsed,
  });

  final String name;
  final String subtitle;
  final String effectiveDate;
  final List<PriceListItem> items;
  final int pageCount;
  final List<String> sourcePhotos;
  final List<String> enginesUsed;
}

/// Redundant Consensus OCR & CSV Pipeline matching `ocr-consensus.js`:
/// - Engine 1: Optional Gemini Vision REST API (when an API key is configured)
/// - Engine 2: On-device Google ML Kit Latin text recognition + deterministic line parser
/// - Engine 3: Deterministic Mathematical Invariant Validator & Discrepancy Arbiter
class OcrConsensusService {
  OcrConsensusService({
    http.Client? httpClient,
    OcrTextRecognizerGateway? textRecognizer,
    PaddleOcrGateway? paddleOcr,
    ImagePickerGateway? imagePicker,
    PdfPagePickerGateway? pdfPicker,
    String? geminiApiKey,
    this.apiKeyProvider,
  })  : _http = httpClient ?? http.Client(),
        _textRecognizer = textRecognizer ?? MlKitTextRecognizerGateway(),
        _paddleOcr = paddleOcr ?? MethodChannelPaddleOcrGateway(),
        _imagePicker = imagePicker ?? DeviceImagePickerGateway(),
        _pdfPicker = pdfPicker ?? MethodChannelPdfPagePickerGateway(),
        _staticApiKey = geminiApiKey;

  static const List<String> models = [
    'gemini-3-flash-preview',
    'gemini-2.5-flash',
    'gemini-flash-lite-latest',
  ];

  static const List<String> validPriceListCategories = [
    'vegetables',
    'fruits',
    'cereals',
    'dairy',
    'meat',
    'fish',
    'legumes',
    'spices',
    'packaged',
    'other',
  ];

  static const List<String> validPriceListUnits = [
    'kgs',
    'litres',
    'pieces',
    'crates',
    'bags',
    'trays',
    'bundles',
    'dozen',
    'packets',
    'bunch',
    'pnts',
    'heads',
  ];

  static const List<String> docketDropdownUnits = [
    'kgs',
    'crates',
    'bags',
    'pieces',
    'bunches',
    'heads',
    'pnts',
    'bundles',
    'litres',
    'trays',
    'dozen',
  ];

  final http.Client _http;
  final OcrTextRecognizerGateway _textRecognizer;
  final PaddleOcrGateway _paddleOcr;
  final ImagePickerGateway _imagePicker;
  final PdfPagePickerGateway _pdfPicker;
  final String? _staticApiKey;
  final String? Function()? apiKeyProvider;

  static const String _envGeminiKey = String.fromEnvironment('TTG_GEMINI_KEY');
  static const String _defaultEncodedGeminiKey =
      'QVEuQWI4Uk42SW01Smc5akhENVRMMDZxcE1vZXptdzdWTDRBa2tKYU1CUElfdDhscGY1YWc=';

  /// Resolves the configured Gemini API key (override -> provider -> static -> dart-define -> web app default).
  String getApiKey([String? overrideKey]) {
    if (overrideKey != null && overrideKey.trim().isNotEmpty) {
      return overrideKey.trim();
    }
    final provided = apiKeyProvider?.call();
    if (provided != null && provided.trim().isNotEmpty) {
      return provided.trim();
    }
    if (_staticApiKey != null && _staticApiKey.trim().isNotEmpty) {
      return _staticApiKey.trim();
    }
    if (_envGeminiKey.trim().isNotEmpty) {
      return _envGeminiKey.trim();
    }
    try {
      return utf8.decode(base64Decode(_defaultEncodedGeminiKey)).trim();
    } catch (_) {
      return '';
    }
  }

  /// Picks a single photo from the device camera and compresses it to a JPEG data URL.
  Future<OcrImagePage?> pickCameraPage({int maxDim = 1600, int quality = 85}) async {
    final file = await _imagePicker.pickCameraImage(imageQuality: quality);
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    final dataUrl = compressAndEncodeDataUrl(bytes, maxDim: maxDim, quality: quality);
    return OcrImagePage(dataUrl: dataUrl, filePath: file.path, bytes: bytes);
  }

  /// Picks one or more photos from the device gallery and encodes each as a JPEG data URL.
  Future<List<OcrImagePage>> pickGalleryPages({
    int maxDim = 1600,
    int quality = 85,
  }) async {
    final files = await _imagePicker.pickGalleryImages(imageQuality: quality);
    final pages = <OcrImagePage>[];
    for (final file in files) {
      final bytes = await file.readAsBytes();
      final dataUrl = compressAndEncodeDataUrl(bytes, maxDim: maxDim, quality: quality);
      pages.add(OcrImagePage(dataUrl: dataUrl, filePath: file.path, bytes: bytes));
    }
    return pages;
  }

  /// Picks a PDF file from device storage and renders its pages as high-res
  /// JPEG pages ready for offline `PP-OCRv5` ONNX, ML Kit, and Cloud Vision.
  Future<List<OcrImagePage>> pickPdfPages({
    int maxDim = 1800,
    int quality = 88,
  }) async {
    final rendered = await _pdfPicker.pickPdfRenderedPages();
    final pages = <OcrImagePage>[];
    for (final r in rendered) {
      final dataUrl = compressAndEncodeDataUrl(
        r.bytes,
        maxDim: maxDim,
        quality: quality,
      );
      pages.add(
        OcrImagePage(
          dataUrl: dataUrl,
          filePath: r.filePath,
          bytes: r.bytes,
        ),
      );
    }
    return pages;
  }

  /// Compresses and resizes image bytes to fit `maxDim` and returns a `data:image/jpeg;base64,...` URL.
  static String compressAndEncodeDataUrl(
    Uint8List rawBytes, {
    int maxDim = 1600,
    int quality = 85,
  }) {
    try {
      final decoded = img.decodeImage(rawBytes);
      if (decoded != null) {
        img.Image processed = decoded;
        if (decoded.width > maxDim || decoded.height > maxDim) {
          if (decoded.width >= decoded.height) {
            processed = img.copyResize(decoded, width: maxDim);
          } else {
            processed = img.copyResize(decoded, height: maxDim);
          }
        }
        final jpgBytes = img.encodeJpg(processed, quality: quality);
        return 'data:image/jpeg;base64,${base64Encode(jpgBytes)}';
      }
    } catch (_) {
      // Fall back to encoding raw bytes if image decoder cannot parse test/mock bytes.
    }
    return 'data:image/jpeg;base64,${base64Encode(rawBytes)}';
  }

  /// Extracts mime type and raw bytes from a `data:image/...;base64,...` URL.
  static ({String mimeType, Uint8List bytes})? decodeImageDataUrl(String? dataUrl) {
    if (dataUrl == null || dataUrl.isEmpty) return null;
    final match = RegExp(
      r'^data:(image\/[a-zA-Z0-9+.-]+);base64,(.+)$',
      dotAll: true,
    ).firstMatch(dataUrl.trim());
    if (match == null) return null;
    try {
      final mime = match.group(1)!;
      final cleanB64 = match.group(2)!.replaceAll(RegExp(r'\s+'), '');
      return (mimeType: mime, bytes: base64Decode(cleanB64));
    } catch (_) {
      return null;
    }
  }

  /// Runs the redundant OCR pipeline on one or more docket image pages.
  Future<OcrDocketResult> processDocket(
    List<OcrImagePage> pages, {
    void Function(String status)? onProgress,
    String? geminiApiKey,
  }) async {
    if (pages.isEmpty) {
      throw ArgumentError('At least one docket photo is required.');
    }
    final pageCount = pages.length;
    onProgress?.call(
      'Analyzing $pageCount docket page${pageCount > 1 ? 's' : ''} with Town Treasure Optical Engine...',
    );

    final apiKey = getApiKey(geminiApiKey);
    Map<String, dynamic>? geminiResult;
    Object? lastError;

    // Engine 1: Cloud Vision (same multi-tier fallback as web ocr-consensus.js; fail fast only if truly offline)
    if (apiKey.isNotEmpty) {
      final dataUrls = pages.map((p) => p.dataUrl).toList();
      for (var i = 0; i < models.length; i++) {
        final model = models[i];
        try {
          onProgress?.call('Scanning produce lines & pricing (Cloud Vision Pass)...');
          final candidate = await _runGeminiDocketVision(dataUrls, model, apiKey);
          final items = candidate['items'];
          if (items is List && items.isNotEmpty) {
            geminiResult = candidate;
            break;
          }
          lastError = StateError('Gemini model $model returned 0 items.');
        } catch (err) {
          lastError = err;
          if (_isNetworkUnavailableError(err)) {
            onProgress?.call('No internet detected — switching to bundled offline OCR...');
            break;
          }
        }
        if (i + 1 < models.length) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
      }
    }

    // Engine 2: Bundled Offline Primary — PaddleOCR PP-OCRv5 ONNX + 2D Spatial Parser
    final filePages =
        pages.where((p) => p.filePath != null && p.filePath!.isNotEmpty).toList();
    Map<String, dynamic>? paddleParsed;
    final paddleTextChunks = <String>[];
    if (geminiResult == null && filePages.isNotEmpty) {
      onProgress?.call('Running offline PaddleOCR PP-OCRv5 ONNX engine...');
      final pagePayloads = <Map<String, dynamic>>[];
      for (final page in filePages) {
        try {
          final boxes = await _paddleOcr.recognizeBoxesFromFile(page.filePath!);
          if (boxes.isNotEmpty) {
            final rows = SpatialOcrParser.reconstructDeskewedRows(boxes);
            final txt = SpatialOcrParser.rowsToPlainText(rows);
            if (txt.isNotEmpty) paddleTextChunks.add(txt);
            pagePayloads.add(SpatialOcrParser.parseBoxesToDocket(boxes));
          }
        } catch (err) {
          lastError ??= err;
        }
      }
      if (pagePayloads.isNotEmpty) {
        paddleParsed = _mergeDocketPagePayloads(pagePayloads);
      }
    }

    // Engine 3: Offline Redundancy — Google ML Kit 2D Bounding Boxes / Text
    final mlKitTexts = <String>[];
    final mlKitPagePayloads = <Map<String, dynamic>>[];
    if (filePages.isNotEmpty &&
        (geminiResult == null ||
            (paddleParsed == null ||
                (paddleParsed['items'] as List?)?.isEmpty == true))) {
      onProgress?.call('Cross-checking with on-device Google ML Kit recognition...');
      for (final page in filePages) {
        try {
          if (_textRecognizer is OcrSpatialRecognizerGateway) {
            final spatial = _textRecognizer as OcrSpatialRecognizerGateway;
            final boxes = await spatial.recognizeBoxesFromFile(page.filePath!);
            if (boxes.isNotEmpty) {
              final rows = SpatialOcrParser.reconstructDeskewedRows(boxes);
              final txt = SpatialOcrParser.rowsToPlainText(rows);
              if (txt.isNotEmpty) mlKitTexts.add(txt);
              mlKitPagePayloads.add(SpatialOcrParser.parseBoxesToDocket(boxes));
              continue;
            }
          }
          final txt = await _textRecognizer.recognizeTextFromFile(page.filePath!);
          if (txt.trim().isNotEmpty) {
            mlKitTexts.add(txt.trim());
          }
        } catch (err) {
          lastError ??= err;
        }
      }
    }

    final combinedMlKitText = mlKitTexts.join('\n--- PAGE BREAK ---\n');
    final mlKitParsed = mlKitPagePayloads.isNotEmpty &&
            mlKitPagePayloads.any((p) => (p['items'] as List?)?.isNotEmpty == true)
        ? _mergeDocketPagePayloads(mlKitPagePayloads)
        : (combinedMlKitText.trim().isNotEmpty
            ? parseRawTextToDocket(combinedMlKitText)
            : null);

    final paddleHasItems =
        (paddleParsed?['items'] as List?)?.isNotEmpty == true;
    final offlineData = paddleHasItems ? paddleParsed : mlKitParsed;
    final offlineRawText = paddleTextChunks.isNotEmpty
        ? paddleTextChunks.join('\n--- PAGE BREAK ---\n')
        : combinedMlKitText;

    if (geminiResult == null &&
        (offlineData == null ||
            ((offlineData['items'] as List?)?.isEmpty ?? true))) {
      final detail = lastError?.toString().toLowerCase() ?? '';
      if (detail.contains('socket') ||
          detail.contains('network') ||
          detail.contains('host lookup') ||
          detail.contains('timeout')) {
        throw StateError(
          'Could not reach the cloud scanner and the photo was unclear offline. Please check your internet connection or retake a sharper photo.',
        );
      }
      throw StateError(
        'Could not read items clearly from this docket photo. Please retake in good lighting or enter the items manually.',
      );
    }

    // Engine 4: Deterministic Mathematical Invariant Validator & Discrepancy Arbiter
    onProgress?.call('Running Deterministic Mathematical Arbiter & checksum verification...');
    final consensus = reconcileWithMath(
      geminiData: geminiResult,
      mlKitData: offlineData,
      rawMlKitText: offlineRawText,
      offlineEngineLabel: paddleHasItems
          ? 'PaddleOCR PP-OCRv5 ONNX (Offline)'
          : (offlineData != null || combinedMlKitText.trim().isNotEmpty
              ? 'Google ML Kit On-Device'
              : null),
      pageCount: pageCount,
    );

    final csvData = itemsToCsv(consensus.items);
    final photoUrls = pages.map((p) => p.dataUrl).toList();

    return OcrDocketResult(
      restaurantName: consensus.restaurantName,
      invoiceNumber: consensus.invoiceNumber,
      date: consensus.date,
      items: consensus.items,
      deliveryCost: consensus.deliveryCost,
      otherCost: consensus.otherCost,
      subtotal: consensus.subtotal,
      grandTotal: consensus.grandTotal,
      csv: csvData,
      enginesUsed: consensus.enginesUsed,
      confidence: consensus.confidence,
      receiptPhoto: photoUrls.isNotEmpty ? photoUrls.first : null,
      receiptPhotos: photoUrls,
      pageCount: pageCount,
      rawMlKitText: offlineRawText,
    );
  }

  /// Runs optical extraction on produce price list photos (Gemini Vision if configured,
  /// with Google ML Kit on-device fallback).
  Future<OcrPriceListResult> processPriceList(
    List<OcrImagePage> pages, {
    void Function(String status)? onProgress,
    String? geminiApiKey,
  }) async {
    if (pages.isEmpty) {
      throw ArgumentError('At least one price list photo is required.');
    }
    final pageCount = pages.length;
    onProgress?.call(
      'Analyzing $pageCount price list page${pageCount > 1 ? 's' : ''} with Town Treasure Optical Engine...',
    );

    final apiKey = getApiKey(geminiApiKey);
    Map<String, dynamic>? extractionResult;
    final enginesUsed = <String>[];
    Object? lastError;

    if (apiKey.isNotEmpty) {
      final dataUrls = pages.map((p) => p.dataUrl).toList();
      for (var i = 0; i < models.length; i++) {
        final model = models[i];
        try {
          onProgress?.call('Digitizing produce catalog & commodity prices...');
          final candidate = await _runGeminiPriceListVision(dataUrls, model, apiKey);
          final items = candidate['items'];
          if (items is List && items.isNotEmpty) {
            extractionResult = candidate;
            enginesUsed.add('Town Treasure Optical Engine');
            break;
          }
          lastError = StateError('Gemini model $model returned 0 price list items.');
        } catch (err) {
          lastError = err;
          if (_isNetworkUnavailableError(err)) {
            onProgress?.call('No internet detected — switching to offline PaddleOCR ONNX...');
            break;
          }
        }
        if (i + 1 < models.length) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
      }
    }

    if (extractionResult == null) {
      final filePages =
          pages.where((p) => p.filePath != null && p.filePath!.isNotEmpty).toList();
      if (filePages.isNotEmpty) {
        onProgress?.call('Running offline PaddleOCR PP-OCRv5 ONNX on price list...');
        final combinedItems = <Map<String, dynamic>>[];
        for (final page in filePages) {
          try {
            final boxes = await _paddleOcr.recognizeBoxesFromFile(page.filePath!);
            if (boxes.isNotEmpty) {
              final parsed = SpatialOcrParser.parseBoxesToPriceList(boxes);
              final pageItems = parsed['items'];
              if (pageItems is List && pageItems.isNotEmpty) {
                combinedItems.addAll(pageItems.whereType<Map>().map((e) => Map<String, dynamic>.from(e)));
              }
            }
          } catch (err) {
            lastError ??= err;
          }
        }
        if (combinedItems.isNotEmpty) {
          extractionResult = {
            'name': 'Scanned Price List',
            'subtitle': 'Food Supplies (Veg and Fruits)',
            'effectiveDate': AppHelpers.normalizeAppDate(DateTime.now()),
            'items': combinedItems,
          };
          enginesUsed.add('PaddleOCR PP-OCRv5 ONNX (Offline)');
        }
      }
    }

    if (extractionResult == null) {
      final mlKitTexts = <String>[];
      final spatialItems = <Map<String, dynamic>>[];
      for (final page in pages) {
        if (page.filePath != null && page.filePath!.isNotEmpty) {
          try {
            if (_textRecognizer is OcrSpatialRecognizerGateway) {
              final spatial = _textRecognizer as OcrSpatialRecognizerGateway;
              final boxes = await spatial.recognizeBoxesFromFile(page.filePath!);
              if (boxes.isNotEmpty) {
                final parsed = SpatialOcrParser.parseBoxesToPriceList(boxes);
                final list = parsed['items'];
                if (list is List && list.isNotEmpty) {
                  spatialItems.addAll(list.whereType<Map>().map((e) => Map<String, dynamic>.from(e)));
                  continue;
                }
              }
            }
            final txt = await _textRecognizer.recognizeTextFromFile(page.filePath!);
            if (txt.trim().isNotEmpty) mlKitTexts.add(txt.trim());
          } catch (err) {
            lastError ??= err;
          }
        }
      }
      if (spatialItems.isNotEmpty) {
        extractionResult = {
          'name': 'Scanned Price List',
          'subtitle': 'Food Supplies (Veg and Fruits)',
          'effectiveDate': AppHelpers.normalizeAppDate(DateTime.now()),
          'items': spatialItems,
        };
        enginesUsed.add('Google ML Kit On-Device');
      } else if (mlKitTexts.isNotEmpty) {
        extractionResult = parseRawTextToPriceList(mlKitTexts.join('\n'));
        enginesUsed.add('Google ML Kit On-Device');
      }
    }

    final rawItems = extractionResult?['items'];
    if (extractionResult == null || rawItems is! List || rawItems.isEmpty) {
      final errStr = (lastError ?? '').toString().toLowerCase();
      if (errStr.contains('socketexception') ||
          errStr.contains('failed host lookup') ||
          errStr.contains('timed out')) {
        throw StateError(
          'Could not reach the optical scan service. Please check your internet connection or try a sharper photo.',
        );
      }
      throw StateError(
        'Could not read price list items from the photo. Please try a clearer, well-lit photo.',
      );
    }

    var currentCategory = 'vegetables';
    final processedItems = <PriceListItem>[];

    for (final raw in rawItems) {
      if (raw is! Map) continue;
      final it = Map<String, dynamic>.from(raw);
      if (it['isHeader'] == true) {
        final headerName = (it['name'] ?? '').toString().trim().toUpperCase();
        if (headerName.isNotEmpty) {
          processedItems.add(
            PriceListItem(
              id: 'h_${AppHelpers.genId()}',
              isHeader: true,
              name: headerName,
            ),
          );
          final lowerH = headerName.toLowerCase();
          if (lowerH.contains('fruit')) {
            currentCategory = 'fruits';
          } else if (lowerH.contains('veg')) {
            currentCategory = 'vegetables';
          } else if (lowerH.contains('herb') ||
              lowerH.contains('spice') ||
              lowerH.contains('culinary')) {
            currentCategory = 'spices';
          } else if (lowerH.contains('dairy') ||
              lowerH.contains('milk') ||
              lowerH.contains('egg')) {
            currentCategory = 'dairy';
          } else if (lowerH.contains('meat') ||
              lowerH.contains('beef') ||
              lowerH.contains('chicken') ||
              lowerH.contains('pork')) {
            currentCategory = 'meat';
          } else if (lowerH.contains('fish') || lowerH.contains('seafood')) {
            currentCategory = 'fish';
          } else if (lowerH.contains('cereal') ||
              lowerH.contains('grain') ||
              lowerH.contains('rice') ||
              lowerH.contains('flour')) {
            currentCategory = 'cereals';
          } else if (lowerH.contains('legume') ||
              lowerH.contains('bean') ||
              lowerH.contains('pea')) {
            currentCategory = 'legumes';
          }
        }
      } else {
        final name = (it['name'] ?? it['desc'] ?? '').toString().trim();
        if (name.isEmpty) continue;

        var cat = (it['category'] ?? '').toString().toLowerCase().trim();
        if (!validPriceListCategories.contains(cat)) cat = currentCategory;

        var unit = (it['unit'] ?? 'kgs').toString().toLowerCase().trim();
        if (unit.startsWith('kg')) {
          unit = 'kgs';
        } else if (unit.startsWith('bunch') || unit == 'bchs') {
          unit = 'bundles';
        } else if (unit == 'pcs' || unit == 'piece') {
          unit = 'pieces';
        } else if (unit == 'crate') {
          unit = 'crates';
        } else if (unit == 'bag' || unit == 'baq' || unit == 'baqs') {
          unit = 'bags';
        } else if (unit == 'punnet' || unit == 'punnets') {
          unit = 'pnts';
        } else if (unit == 'head') {
          unit = 'heads';
        } else if (unit == 'tray') {
          unit = 'trays';
        } else if (!validPriceListUnits.contains(unit)) {
          unit = 'kgs';
        }

        final price = AppHelpers.parseDouble(
          it['price'] ?? it['sellPrice'] ?? it['rate'],
        );
        final notes =
            (it['notes'] ?? it['grade'] ?? it['variety'] ?? '').toString().trim();

        processedItems.add(
          PriceListItem(
            id: 'it_${AppHelpers.genId()}',
            isHeader: false,
            name: name,
            category: cat,
            unit: unit,
            price: price,
            notes: notes,
          ),
        );
      }
    }

    final today = AppHelpers.normalizeAppDate(DateTime.now());
    return OcrPriceListResult(
      name: (extractionResult['name'] ?? '').toString().trim().isNotEmpty
          ? extractionResult['name'].toString().trim()
          : 'Price List - $today',
      subtitle: (extractionResult['subtitle'] ?? '').toString().trim().isNotEmpty
          ? extractionResult['subtitle'].toString().trim()
          : 'Food Supplies (Veg and Fruits)',
      effectiveDate: AppHelpers.normalizeAppDate(
        extractionResult['effectiveDate'],
      ).isNotEmpty
          ? AppHelpers.normalizeAppDate(extractionResult['effectiveDate'])
          : today,
      items: processedItems,
      pageCount: pageCount,
      sourcePhotos: pages.map((p) => p.dataUrl).toList(),
      enginesUsed: enginesUsed,
    );
  }

  /// Engine 3: Deterministic Mathematical Invariant Validator & Discrepancy Arbiter.
  /// Matches `_reconcileWithMath` in `ocr-consensus.js`.
  static ({
    String restaurantName,
    String invoiceNumber,
    String date,
    List<InvoiceLineItem> items,
    double deliveryCost,
    double otherCost,
    double subtotal,
    double grandTotal,
    int confidence,
    List<String> enginesUsed,
  }) reconcileWithMath({
    Map<String, dynamic>? geminiData,
    Map<String, dynamic>? mlKitData,
    String rawMlKitText = '',
    String? offlineEngineLabel,
    int pageCount = 1,
  }) {
    final enginesUsed = <String>[];
    if (geminiData != null) enginesUsed.add('Town Treasure Optical Engine');
    if (mlKitData != null || rawMlKitText.trim().isNotEmpty) {
      enginesUsed.add(offlineEngineLabel ?? 'Google ML Kit On-Device');
    }
    enginesUsed.add('Math Invariant Arbiter');

    final primary = geminiData ?? mlKitData ?? const <String, dynamic>{};
    final rawItems = primary['items'] is List
        ? (primary['items'] as List)
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList()
        : <Map<String, dynamic>>[];

    final statedSubtotal = AppHelpers.parseDouble(primary['subtotal']);
    final sumOfRawTotals = rawItems.fold<double>(
      0,
      (acc, it) => acc + AppHelpers.parseDouble(it['total']),
    );
    final totalsAreGroundTruth =
        statedSubtotal > 0 && (sumOfRawTotals - statedSubtotal).abs() <= 2;

    final items = rawItems.map((it) {
      final descRaw = (it['desc'] ?? it['name'] ?? 'Produce Item').toString().trim();
      final sanitizedDesc = SpatialOcrParser.sanitizeProduceDescription(descRaw);
      final desc = sanitizedDesc.desc.isNotEmpty
          ? sanitizedDesc.desc
          : (descRaw.isEmpty ? 'Produce Item' : descRaw);
      var qty = AppHelpers.parseDouble(it['qty'], 1);
      var price = AppHelpers.parseDouble(it['price'] ?? it['sellPrice']);
      if (price == 0 && (sanitizedDesc.embeddedPrice ?? 0) > 0) {
        price = sanitizedDesc.embeddedPrice!;
      }
      var total = AppHelpers.parseDouble(it['total']);
      final rawUnit = (it['unit'] ?? sanitizedDesc.embeddedUnit ?? 'kgs').toString();
      final unit = normalizeUnit(rawUnit);

      // Mathematical Arbitration: line Total is highest-clarity anchor.
      if (qty > 0 && total > 0) {
        if (price > 0 && (qty * price - total).abs() > 0.5) {
          final candidateQty = total / price;
          // Catch table-border digit prepend (e.g. "115" * 40 != 600 -> 15 * 40 == 600)
          if (candidateQty >= 1 &&
              (candidateQty - candidateQty.roundToDouble()).abs() < 0.001 &&
              qty == qty.roundToDouble() &&
              qty.toInt().toString().contains(candidateQty.round().toString())) {
            qty = candidateQty.roundToDouble();
          } else {
            price = ((total / qty) * 100).roundToDouble() / 100;
          }
        } else if (price == 0) {
          price = ((total / qty) * 100).roundToDouble() / 100;
        }
      } else if (qty > 0 && price > 0 && total == 0) {
        total = ((qty * price) * 100).roundToDouble() / 100;
      }

      final resolvedTotal = total > 0
          ? total
          : (((qty * price) * 100).roundToDouble() / 100);

      return InvoiceLineItem(
        desc: desc,
        qty: qty > 0 ? qty : 1,
        unit: unit,
        buyPrice: AppHelpers.parseDouble(it['buyPrice']),
        sellPrice: price,
        total: resolvedTotal,
      );
    }).toList();

    final calculatedSubtotal = items.fold<double>(0, (s, it) => s + it.total);
    final delCost = AppHelpers.parseDouble(
      primary['delivery_cost'] ?? primary['deliveryCost'],
    );
    final othCost = AppHelpers.parseDouble(
      primary['other_cost'] ?? primary['otherCost'],
    );
    final finalSubtotal = totalsAreGroundTruth ? statedSubtotal : calculatedSubtotal;
    final grandTotal = finalSubtotal + delCost + othCost;

    final gemRest = (geminiData?['restaurant_name'] ??
            geminiData?['restaurantName'] ??
            '')
        .toString()
        .trim();
    final mlRest = (mlKitData?['restaurant_name'] ??
            mlKitData?['restaurantName'] ??
            '')
        .toString()
        .trim();
    final restaurantName = gemRest.isNotEmpty ? gemRest : mlRest;

    final gemInv =
        (geminiData?['invoice_number'] ?? geminiData?['invoiceNumber'] ?? '')
            .toString()
            .trim();
    final mlInv =
        (mlKitData?['invoice_number'] ?? mlKitData?['invoiceNumber'] ?? '')
            .toString()
            .trim();
    final invoiceNumber = gemInv.isNotEmpty ? gemInv : mlInv;

    final rawDate = (geminiData?['invoice_date'] ??
            geminiData?['date'] ??
            mlKitData?['invoice_date'] ??
            mlKitData?['date'] ??
            '')
        .toString()
        .trim();
    final normalizedDate = AppHelpers.normalizeAppDate(rawDate);
    final date = normalizedDate.isNotEmpty
        ? normalizedDate
        : AppHelpers.normalizeAppDate(DateTime.now());

    return (
      restaurantName: restaurantName,
      invoiceNumber: invoiceNumber,
      date: date,
      items: items,
      deliveryCost: delCost,
      otherCost: othCost,
      subtotal: finalSubtotal,
      grandTotal: grandTotal,
      confidence: geminiData != null ? 99 : 85,
      enginesUsed: enginesUsed,
    );
  }

  /// Normalizes produce unit aliases matching `ocr-consensus.js`.
  static String normalizeUnit(String rawUnit) {
    final unit = rawUnit.toLowerCase().trim();
    if (unit.isEmpty) return 'kgs';
    if (unit == 'baq' || unit == 'baqs' || unit == 'bag' || unit == 'bags') {
      return 'bags';
    }
    if (unit.startsWith('bunch') || unit == 'bchs' || unit == 'bunche') {
      return 'bunches';
    }
    if (unit.startsWith('pnt') || unit.startsWith('punnet')) return 'pnts';
    if (unit.startsWith('head')) return 'heads';
    if (unit.startsWith('pc') || unit == 'piece') return 'pcs';
    if (unit == 'k' || unit == 'kilo' || unit == 'kilogram') return 'kg';
    return unit;
  }

  /// Maps normalized OCR units to canonical dropdown option keys used by forms.
  static String normalizeDropdownUnit(String rawUnit) {
    final u = normalizeUnit(rawUnit);
    switch (u) {
      case 'kg':
      case 'kilograms':
        return 'kgs';
      case 'pcs':
      case 'piece':
        return 'pieces';
      case 'punnet':
      case 'punnets':
        return 'pnts';
      case 'crate':
        return 'crates';
      case 'bag':
        return 'bags';
      case 'bundle':
        return 'bundles';
      case 'litre':
        return 'litres';
      case 'tray':
        return 'trays';
      default:
        return docketDropdownUnits.contains(u) ? u : 'kgs';
    }
  }

  /// Parses raw on-device ML Kit OCR text into structured docket fields and produce items.
  static Map<String, dynamic> parseRawTextToDocket(String rawText) {
    final lines = rawText
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    var restaurantName = '';
    var invoiceNumber = '';
    var invoiceDate = '';
    var deliveryCost = 0.0;
    var subtotal = 0.0;
    final items = <Map<String, dynamic>>[];

    final invPattern = RegExp(
      r'\b(?:DKT|INV|TTG|TTM)[-#:]\s*[A-Z0-9-]+|\b(?:DKT|INV|TTG|TTM)\s+\d[A-Z0-9-]*|(?:DOCKET|INVOICE|RECEIPT)\s*(?:NO\.?|#)\s*:?\s*([A-Z0-9-]+)',
      caseSensitive: false,
    );
    final clientLabelPattern = RegExp(
      r'^(?:client|customer|restaurant|hotel|deliver\s*to|to)\s*[:\-]\s*(.+)$',
      caseSensitive: false,
    );
    final datePattern = RegExp(
      r'\b(\d{4}-\d{2}-\d{2}|\d{2}[/-]\d{2}[/-]\d{4})\b',
    );
    final deliveryPattern = RegExp(
      r'delivery(?:\s*(?:fee|cost))?\s*[:\-]?\s*(?:kes|ksh)?\s*([\d,]+(?:\.\d+)?)',
      caseSensitive: false,
    );
    final subtotalPattern = RegExp(
      r'^(?:sub\s*total|subtotal)\s*[:\-]?\s*(?:kes|ksh)?\s*([\d,]+(?:\.\d+)?)',
      caseSensitive: false,
    );
    final lineItemPattern = RegExp(
      r'^(?:\d+[\.\)]\s*)?([A-Za-z][A-Za-z0-9\s\(\)\/&,-]{1,60}?)\s+(\d+(?:\.\d+)?)\s*(kgs?|kilograms?|crates?|bags?|pcs|pieces?|bunches?|bchs|bundles?|heads?|pnts?|punnets?|litres?|trays?|dozen|boxes?)\b(?:\s*(?:@|x|kes|ksh)?\s*([\d,]+(?:\.\d+)?))?(?:\s*(?:=|kes|ksh)?\s*([\d,]+(?:\.\d+)?))?$',
      caseSensitive: false,
    );

    for (final line in lines) {
      if (invoiceNumber.isEmpty) {
        final invMatch = invPattern.firstMatch(line);
        if (invMatch != null) {
          invoiceNumber = (invMatch.group(1) ?? invMatch.group(0) ?? '').trim();
        }
      }

      if (invoiceDate.isEmpty) {
        final dateMatch = datePattern.firstMatch(line);
        if (dateMatch != null) {
          final norm = AppHelpers.normalizeAppDate(dateMatch.group(1));
          if (norm.isNotEmpty) invoiceDate = norm;
        }
      }

      if (restaurantName.isEmpty) {
        final clientMatch = clientLabelPattern.firstMatch(line);
        if (clientMatch != null) {
          restaurantName = clientMatch.group(1)!.trim();
          continue;
        }
        final lower = line.toLowerCase();
        if (!lower.contains('town treasure') &&
            (lower.contains('hotel') ||
                lower.contains('suites') ||
                lower.contains('resort') ||
                lower.contains('restaurant') ||
                lower.contains('lodge') ||
                lower.contains('kempinski') ||
                lower.contains('serena') ||
                lower.contains('sarova'))) {
          restaurantName = line;
          continue;
        }
      }

      final delMatch = deliveryPattern.firstMatch(line);
      if (delMatch != null) {
        deliveryCost = _parseFormattedNumber(delMatch.group(1));
        continue;
      }

      final subMatch = subtotalPattern.firstMatch(line);
      if (subMatch != null) {
        subtotal = _parseFormattedNumber(subMatch.group(1));
        continue;
      }

      final lower = line.toLowerCase();
      if (lower.startsWith('total') ||
          lower.startsWith('grand total') ||
          lower.startsWith('item description') ||
          lower.startsWith('goods received')) {
        continue;
      }

      final itemMatch = lineItemPattern.firstMatch(line);
      if (itemMatch != null) {
        final desc = itemMatch.group(1)!.trim();
        final qty = double.tryParse(itemMatch.group(2) ?? '1') ?? 1;
        final unit = itemMatch.group(3) ?? 'kgs';
        final num1 = _parseFormattedNumber(itemMatch.group(4));
        final num2 = _parseFormattedNumber(itemMatch.group(5));

        double price = 0;
        double total = 0;
        if (num1 > 0 && num2 > 0) {
          price = num1;
          total = num2;
        } else if (num1 > 0) {
          price = num1;
          total = qty * price;
        }

        items.add({
          'desc': desc,
          'qty': qty,
          'unit': unit,
          'price': price,
          'total': total,
        });
      }
    }

    return {
      'restaurant_name': restaurantName,
      'invoice_number': invoiceNumber,
      'invoice_date': invoiceDate,
      'items': items,
      'delivery_cost': deliveryCost,
      'other_cost': 0.0,
      'subtotal': subtotal,
    };
  }

  /// Parses raw on-device ML Kit text into structured price list headers and items.
  static Map<String, dynamic> parseRawTextToPriceList(String rawText) {
    final lines = rawText
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    final items = <Map<String, dynamic>>[];
    final headerKeywords = RegExp(
      r'^(VEGETABLES|FRUITS|HERBS\s*&\s*SPICES|SPICES|DAIRY(?:\s*&\s*EGGS)?|CEREALS|MEAT|FISH|LEGUMES|ROOT\s*CROPS)$',
      caseSensitive: false,
    );
    final priceRowPattern = RegExp(
      r'^([A-Za-z][A-Za-z0-9\s\(\)\/&,-]{1,50}?)\s*[-:]?\s*(?:kes|ksh)?\s*([\d,]+(?:\.\d+)?)\s*(?:/|\s*per)?\s*(kgs?|crates?|bags?|pieces?|pcs|bunches?|bundles?|heads?|pnts?|punnets?|litres?|trays?|dozen)?$',
      caseSensitive: false,
    );

    for (final line in lines) {
      if (headerKeywords.hasMatch(line)) {
        items.add({'isHeader': true, 'name': line.toUpperCase()});
        continue;
      }
      final match = priceRowPattern.firstMatch(line);
      if (match != null) {
        final name = match.group(1)!.trim();
        final price = _parseFormattedNumber(match.group(2));
        final unit = (match.group(3) ?? 'kgs').trim();
        if (name.isNotEmpty && price > 0) {
          items.add({
            'isHeader': false,
            'name': name,
            'unit': unit,
            'price': price,
          });
        }
      }
    }

    return {
      'name': 'Scanned Price List',
      'subtitle': 'Food Supplies (Veg and Fruits)',
      'effectiveDate': AppHelpers.normalizeAppDate(DateTime.now()),
      'items': items,
    };
  }

  /// Converts line items to structured CSV format matching `itemsToCSV` in `ocr-consensus.js`.
  static String itemsToCsv(List<InvoiceLineItem> items) {
    const header = 'Item Description,Quantity,Unit,Unit Price,Total';
    final rows = items.map((it) {
      final escapedDesc = it.desc.replaceAll('"', '""');
      final qtyStr = _formatCsvNumber(it.qty);
      final unit = it.unit.isNotEmpty ? it.unit : 'kgs';
      final priceStr = _formatCsvNumber(it.sellPrice);
      final totalStr = _formatCsvNumber(it.total);
      return '"$escapedDesc",$qtyStr,$unit,$priceStr,$totalStr';
    });
    return [header, ...rows].join('\n');
  }

  /// Parses CSV string into `InvoiceLineItem` list matching `csvToItems` in `ocr-consensus.js`.
  static List<InvoiceLineItem> csvToItems(String csvString) {
    final trimmed = csvString.trim();
    if (trimmed.isEmpty) return const [];
    final lines = trimmed.split(RegExp(r'\r?\n'));
    if (lines.length <= 1) return const [];

    final items = <InvoiceLineItem>[];
    for (var i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      final parts = _splitCsvLine(line);
      var desc = parts.isNotEmpty ? parts[0].trim() : 'Item';
      if (desc.startsWith('"') && desc.endsWith('"') && desc.length >= 2) {
        desc = desc.substring(1, desc.length - 1);
      }
      desc = desc.replaceAll('""', '"');
      if (desc.isEmpty) desc = 'Item';

      final qty =
          parts.length > 1 ? (double.tryParse(parts[1].trim()) ?? 1.0) : 1.0;
      final unitRaw = parts.length > 2 ? parts[2].trim() : '';
      final unit = unitRaw.isNotEmpty ? unitRaw : 'kgs';
      final price =
          parts.length > 3 ? (double.tryParse(parts[3].trim()) ?? 0.0) : 0.0;
      final total = parts.length > 4 && parts[4].trim().isNotEmpty
          ? (double.tryParse(parts[4].trim()) ?? (qty * price))
          : (qty * price);

      items.add(
        InvoiceLineItem(
          desc: desc,
          qty: qty,
          unit: unit,
          buyPrice: 0,
          sellPrice: price,
          total: total,
        ),
      );
    }
    return items;
  }

  Future<Map<String, dynamic>> _runGeminiDocketVision(
    List<String> imgList,
    String modelName,
    String apiKey,
  ) async {
    final isMultiPage = imgList.length > 1;
    final systemPrompt = '''You are a precision OCR accountant for Town Treasure Groceries, a Kenyan wholesale produce supplier.
Extract all produce line items from this physical delivery docket/invoice.
${isMultiPage ? 'IMPORTANT: This is a MULTI-PAGE docket (${imgList.length} pages). Combine all line items from ALL pages into a single continuous list of items in natural order. If the last page contains the final subtotal/total due, extract that.' : ''}

The standard columns are:
1. ITEM DESCRIPTION
2. QTY & UNIT (e.g. 2 bags, 5 bunches, 2 pnts, 10 pcs, 4 heads, 5 kg, 8 pcs, 10 kgs)
3. UNIT PRICE (Ksh)
4. TOTAL (Ksh)

CRITICAL INSTRUCTIONS:
- Read each line strictly horizontally across all columns.
- For each row, QTY * UNIT PRICE = TOTAL.
- Do NOT vertically shift unit prices into adjacent rows.
- Read the line totals in the rightmost column carefully.
- Put ONLY the clean produce item name in "desc" (e.g. "Dhania", NEVER include leading row serial numbers like "01" or prices like "KSh 15.00" or "KSh 15.00 / kgs" in "desc").
- Extract the Customer / Restaurant name, Invoice #, Date, Subtotal, Delivery Cost, and Grand Total.
- Common Kenyan units: bags, bunches, pnts (punnets), pcs (pieces), heads, kg, kgs, crates, trays, boxes, litres.

Return ONLY a JSON object matching this exact structure:
{
  "restaurant_name": "Customer or restaurant name if visible",
  "invoice_number": "Invoice/docket number if visible",
  "invoice_date": "YYYY-MM-DD date if visible",
  "items": [
    {
      "desc": "Maize (Dry Bag)",
      "qty": 2.0,
      "unit": "bags",
      "price": 4500.0,
      "total": 9000.0
    }
  ],
  "subtotal": 13810.0,
  "delivery_cost": 300.0,
  "grand_total": 14110.0
}''';

    return _callGeminiVision(imgList, modelName, apiKey, systemPrompt, 'docket');
  }

  Future<Map<String, dynamic>> _runGeminiPriceListVision(
    List<String> imgList,
    String modelName,
    String apiKey,
  ) async {
    final isMultiPage = imgList.length > 1;
    final systemPrompt = '''You are a precision wholesale produce catalog specialist for Town Treasure Groceries in Kenya.
Analyze this produce price list or price sheet (single or multi-page) and extract all category headers and produce items into structured JSON.
${isMultiPage ? 'IMPORTANT: This document has ${imgList.length} pages. Extract items from ALL pages into a continuous structured sequence.' : ''}

CRITICAL RULES:
1. Detect section/category headers (e.g. "VEGETABLES", "FRUITS", "HERBS & SPICES", "DAIRY & EGGS", "CEREALS", "ROOT CROPS").
   Represent each section header as an object with "isHeader": true and "name": "SECTION TITLE".
2. Under each section, extract individual produce items:
   - "name": Produce item name (e.g. "Roma Tomatoes", "Red Onions", "Baby Spinach")
   - "category": One of "vegetables", "fruits", "spices", "cereals", "dairy", "meat", "fish", "legumes", "packaged", "other"
   - "unit": Kenyan produce unit ("kgs", "crates", "bags", "pieces", "bunches", "heads", "pnts", "litres", "trays", "dozen", "bundles")
   - "price": Selling price in KES as a number (e.g. 155.0, 3200.0)
   - "notes": Grade, variety, or packaging specification if mentioned
3. Extract Document Title / Header ("name"), Subtitle ("subtitle"), and Effective Date ("effectiveDate" as YYYY-MM-DD if visible).

Return ONLY JSON matching:
{
  "name": "Produce Price List",
  "subtitle": "Fresh Vegetables & Fruits",
  "effectiveDate": "YYYY-MM-DD",
  "items": [
    { "isHeader": true, "name": "VEGETABLES" },
    { "isHeader": false, "name": "Roma Tomatoes", "category": "vegetables", "unit": "crates", "price": 3200.0, "notes": "Grade A" }
  ]
}''';

    return _callGeminiVision(
      imgList,
      modelName,
      apiKey,
      systemPrompt,
      'price list',
    );
  }

  Future<Map<String, dynamic>> _callGeminiVision(
    List<String> imgList,
    String modelName,
    String apiKey,
    String systemPrompt,
    String docLabel,
  ) async {
    final isMultiPage = imgList.length > 1;
    final parts = <Map<String, dynamic>>[
      {'text': systemPrompt},
    ];

    for (var i = 0; i < imgList.length; i++) {
      final dataUrl = imgList[i];
      final decoded = decodeImageDataUrl(dataUrl);
      final mime = decoded?.mimeType ?? 'image/jpeg';
      final cleanB64 = decoded != null
          ? base64Encode(decoded.bytes)
          : dataUrl.replaceFirst(RegExp(r'^data:image\/[a-zA-Z0-9+.-]+;base64,'), '');
      if (isMultiPage) {
        parts.add({'text': 'Page ${i + 1} of $docLabel:'});
      }
      parts.add({
        'inlineData': {
          'mimeType': mime,
          'data': cleanB64,
        },
      });
    }

    const safetySettings = [
      {'category': 'HARM_CATEGORY_HARASSMENT', 'threshold': 'BLOCK_NONE'},
      {'category': 'HARM_CATEGORY_HATE_SPEECH', 'threshold': 'BLOCK_NONE'},
      {'category': 'HARM_CATEGORY_SEXUALLY_EXPLICIT', 'threshold': 'BLOCK_NONE'},
      {'category': 'HARM_CATEGORY_DANGEROUS_CONTENT', 'threshold': 'BLOCK_NONE'},
      {'category': 'HARM_CATEGORY_CIVIC_INTEGRITY', 'threshold': 'BLOCK_NONE'},
    ];

    final payload = {
      'contents': [
        {'parts': parts},
      ],
      'generationConfig': {
        'responseMimeType': 'application/json',
        'temperature': 0.1,
        'maxOutputTokens': 8192,
      },
      'safetySettings': safetySettings,
    };

    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$modelName:generateContent?key=$apiKey',
    );
    final response = await _http
        .post(
          uri,
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('API error (${response.statusCode}): ${response.body}');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const FormatException('Invalid JSON payload from vision model.');
    }
    final promptFeedback = decoded['promptFeedback'];
    if (promptFeedback is Map && promptFeedback['blockReason'] != null) {
      throw StateError(
        'Vision prompt blocked (${promptFeedback['blockReason']}) on $modelName.',
      );
    }
    final candidates = decoded['candidates'];
    if (candidates is! List || candidates.isEmpty) {
      throw StateError('Empty candidates from vision model ($modelName).');
    }
    final firstCandidate = candidates.first;
    final candidateMap = firstCandidate is Map ? firstCandidate : null;
    final finishReason = candidateMap?['finishReason']?.toString();
    final contentMap = candidateMap?['content'];
    final partsList = contentMap is Map ? contentMap['parts'] : null;
    final firstPart =
        partsList is List && partsList.isNotEmpty ? partsList.first : null;
    final text = firstPart is Map ? firstPart['text']?.toString() : null;
    if (text == null || text.trim().isEmpty) {
      final suffix = finishReason != null && finishReason.isNotEmpty
          ? ' (finishReason: $finishReason)'
          : '';
      throw StateError('Empty response from vision model ($modelName)$suffix.');
    }

    final cleaned = _stripJsonCodeFence(text);
    final parsed = jsonDecode(cleaned);
    if (parsed is! Map) {
      throw const FormatException('Vision response was not a JSON object.');
    }
    return Map<String, dynamic>.from(parsed);
  }

  static String _stripJsonCodeFence(String text) {
    final trimmed = text.trim();
    final match = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$').firstMatch(trimmed);
    return match != null ? match.group(1)!.trim() : trimmed;
  }

  static List<String> _splitCsvLine(String line) {
    final parts = <String>[];
    var inQuotes = false;
    final current = StringBuffer();
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          current.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (ch == ',' && !inQuotes) {
        parts.add(current.toString().trim());
        current.clear();
      } else {
        current.write(ch);
      }
    }
    parts.add(current.toString().trim());
    return parts;
  }

  static String _formatCsvNumber(double value) {
    if (value == value.roundToDouble()) {
      return value.toInt().toString();
    }
    return value.toString();
  }

  static double _parseFormattedNumber(String? raw) {
    if (raw == null) return 0;
    final clean = raw.replaceAll(',', '').trim();
    return double.tryParse(clean) ?? 0;
  }

  static bool _isNetworkUnavailableError(Object err) {
    // Only treat real transport/DNS failures as offline; a single slow model
    // TimeoutException should still allow the next Gemini model in the list.
    if (err is SocketException) return true;
    final lower = err.toString().toLowerCase();
    return lower.contains('socketexception') ||
        lower.contains('failed host lookup') ||
        lower.contains('network is unreachable') ||
        lower.contains('connection refused') ||
        lower.contains('clientexception');
  }

  static Map<String, dynamic> _mergeDocketPagePayloads(
    List<Map<String, dynamic>> payloads,
  ) {
    var restaurantName = '';
    var invoiceNumber = '';
    var invoiceDate = '';
    var deliveryCost = 0.0;
    var otherCost = 0.0;
    var subtotal = 0.0;
    final mergedItems = <Map<String, dynamic>>[];

    for (final p in payloads) {
      final rn = (p['restaurant_name'] ?? '').toString().trim();
      if (restaurantName.isEmpty && rn.isNotEmpty) restaurantName = rn;
      final inv = (p['invoice_number'] ?? '').toString().trim();
      if (invoiceNumber.isEmpty && inv.isNotEmpty) invoiceNumber = inv;
      final dt = (p['invoice_date'] ?? '').toString().trim();
      if (invoiceDate.isEmpty && dt.isNotEmpty) invoiceDate = dt;
      final dc = AppHelpers.parseDouble(p['delivery_cost']);
      if (dc > 0) deliveryCost = dc;
      final oc = AppHelpers.parseDouble(p['other_cost']);
      if (oc > 0) otherCost = oc;
      final sub = AppHelpers.parseDouble(p['subtotal']);
      if (sub > 0) subtotal = sub;
      final items = p['items'];
      if (items is List) {
        mergedItems.addAll(
          items.whereType<Map>().map((e) => Map<String, dynamic>.from(e)),
        );
      }
    }

    return {
      'restaurant_name': restaurantName,
      'invoice_number': invoiceNumber,
      'invoice_date': invoiceDate,
      'items': mergedItems,
      'delivery_cost': deliveryCost,
      'other_cost': otherCost,
      'subtotal': subtotal,
    };
  }

  Future<void> dispose() async {
    await _textRecognizer.close();
    await _paddleOcr.close();
  }
}
