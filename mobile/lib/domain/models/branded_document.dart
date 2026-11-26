import 'package:flutter/material.dart';

import 'app_helpers.dart';
import 'restaurant.dart';

enum BrandedDocTemplate {
  blank,
  businessLetter,
  quotation,
  noticeMemo,
  deliveryNote,
}

/// Inline styled text span produced by [BrandedInlineParser].
class BrandedInlineSpan {
  const BrandedInlineSpan({
    required this.text,
    this.bold = false,
    this.italic = false,
    this.underline = false,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
}

/// Parses and toggles lightweight inline rich formatting (`**bold**`, `*italic*`,
/// `__underline__`) so users can format individual words/selections inside a
/// block just like MS Word, or toggle block-wide styles.
class BrandedInlineParser {
  BrandedInlineParser._();

  static final RegExp _tokenPattern = RegExp(
    r'(_{3,}|\*\*\*(.+?)\*\*\*|\*\*(.+?)\*\*|__(?!_)([^\n]+?)(?<!_)__(?!_)|\*(.+?)\*)',
    dotAll: true,
  );

  static List<BrandedInlineSpan> parse(
    String input, {
    bool baseBold = false,
    bool baseItalic = false,
    bool baseUnderline = false,
  }) {
    if (input.isEmpty) {
      return [
        BrandedInlineSpan(
          text: '',
          bold: baseBold,
          italic: baseItalic,
          underline: baseUnderline,
        ),
      ];
    }

    final spans = <BrandedInlineSpan>[];
    var cursor = 0;
    for (final match in _tokenPattern.allMatches(input)) {
      if (match.start > cursor) {
        spans.add(
          BrandedInlineSpan(
            text: input.substring(cursor, match.start),
            bold: baseBold,
            italic: baseItalic,
            underline: baseUnderline,
          ),
        );
      }

      final full = match.group(0) ?? '';
      if (full.startsWith('___')) {
        // Preserve fill-in blank lines (3+ underscores) verbatim without
        // collapsing them or bleeding underline formatting into adjacent text.
        spans.add(
          BrandedInlineSpan(
            text: full,
            bold: baseBold,
            italic: baseItalic,
            underline: baseUnderline,
          ),
        );
      } else if (match.group(2) != null) {
        spans.addAll(
          parse(
            match.group(2)!,
            baseBold: true,
            baseItalic: true,
            baseUnderline: baseUnderline,
          ),
        );
      } else if (match.group(3) != null) {
        spans.addAll(
          parse(
            match.group(3)!,
            baseBold: true,
            baseItalic: baseItalic,
            baseUnderline: baseUnderline,
          ),
        );
      } else if (match.group(4) != null) {
        spans.addAll(
          parse(
            match.group(4)!,
            baseBold: baseBold,
            baseItalic: baseItalic,
            baseUnderline: true,
          ),
        );
      } else if (match.group(5) != null) {
        spans.addAll(
          parse(
            match.group(5)!,
            baseBold: baseBold,
            baseItalic: true,
            baseUnderline: baseUnderline,
          ),
        );
      }
      cursor = match.end;
    }

    if (cursor < input.length) {
      spans.add(
        BrandedInlineSpan(
          text: input.substring(cursor),
          bold: baseBold,
          italic: baseItalic,
          underline: baseUnderline,
        ),
      );
    }
    return spans;
  }

  /// Wraps or unwraps the current non-collapsed selection in [value] with [marker]
  /// (`**`, `*`, or `__`), keeping the inner text selected.
  static TextEditingValue toggleSelectionMarker(
    TextEditingValue value,
    String marker,
  ) {
    final sel = value.selection;
    if (!sel.isValid || sel.isCollapsed) return value;
    final start = sel.start;
    final end = sel.end;
    final text = value.text;
    final selected = text.substring(start, end);
    final mLen = marker.length;

    // Case 1: Selected text itself starts and ends with the marker
    if (selected.length >= mLen * 2 &&
        selected.startsWith(marker) &&
        selected.endsWith(marker)) {
      final unwrapped = selected.substring(mLen, selected.length - mLen);
      final next = text.replaceRange(start, end, unwrapped);
      return value.copyWith(
        text: next,
        selection: TextSelection(
          baseOffset: start,
          extentOffset: start + unwrapped.length,
        ),
      );
    }

    // Case 2: Surrounding characters immediately outside selection are the marker
    if (start >= mLen &&
        end + mLen <= text.length &&
        text.substring(start - mLen, start) == marker &&
        text.substring(end, end + mLen) == marker) {
      final next = text.replaceRange(start - mLen, end + mLen, selected);
      return value.copyWith(
        text: next,
        selection: TextSelection(
          baseOffset: start - mLen,
          extentOffset: start - mLen + selected.length,
        ),
      );
    }

    // Case 3: Wrap selection with marker
    final wrapped = '$marker$selected$marker';
    final next = text.replaceRange(start, end, wrapped);
    return value.copyWith(
      text: next,
      selection: TextSelection(
        baseOffset: start + mLen,
        extentOffset: start + mLen + selected.length,
      ),
    );
  }
}

/// A rich block inside a [BrandedDocument] (paragraph, heading, list item,
/// callout box, horizontal divider, or structured table).
class BrandedDocBlock {
  const BrandedDocBlock({
    required this.id,
    this.kind = 'paragraph',
    this.text = '',
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.fontFamily = 'sans',
    this.fontSize = 11.0,
    this.align = 'left',
    this.colorHex = '#1E293B',
    this.indent = 0,
    this.lineSpacing = 1.35,
    this.tableRows = const [],
  });

  final String id;
  final String kind;
  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final String fontFamily;
  final double fontSize;
  final String align;
  final String colorHex;
  final int indent;
  final double lineSpacing;
  final List<List<String>> tableRows;

  bool get isTable => kind == 'table';
  bool get isDivider => kind == 'divider';
  bool get isHeading =>
      kind == 'heading1' || kind == 'heading2' || kind == 'heading3';

  /// Detects legacy Delivery Note plain-text underscore signatory paragraphs so
  /// existing saved Delivery Notes in the vault automatically upgrade to the
  /// spacious Signatory Verification Grid.
  bool get isLegacySignatoryParagraph {
    if (kind != 'paragraph') return false;
    final lower = text.toLowerCase();
    if (!RegExp(r'_{4,}').hasMatch(lower)) return false;
    final hasDispatchAndReceive =
        lower.contains('dispatched by') && lower.contains('received by');
    final hasReceiveAndSignTime = lower.contains('received by') &&
        (lower.contains('signature') || lower.contains('name & sign')) &&
        lower.contains('time');
    return hasDispatchAndReceive || hasReceiveAndSignTime;
  }

  bool get isSignatory => kind == 'signatory' || isLegacySignatoryParagraph;

  factory BrandedDocBlock.fromJson(Map<String, dynamic> json) {
    final rawRows = json['tableRows'];
    final parsedRows = <List<String>>[];
    if (rawRows is List) {
      for (final r in rawRows) {
        if (r is List) {
          parsedRows.add(r.map((c) => (c ?? '').toString()).toList());
        }
      }
    }
    return BrandedDocBlock(
      id: (json['id'] ?? AppHelpers.genId()).toString(),
      kind: (json['kind'] ?? 'paragraph').toString(),
      text: (json['text'] ?? '').toString(),
      bold: json['bold'] == true,
      italic: json['italic'] == true,
      underline: json['underline'] == true,
      fontFamily: (json['fontFamily'] ?? 'sans').toString(),
      fontSize: AppHelpers.parseDouble(json['fontSize'], 11.0).clamp(8.0, 36.0),
      align: (json['align'] ?? 'left').toString(),
      colorHex: (json['colorHex'] ?? '#1E293B').toString(),
      indent: AppHelpers.parseInt(json['indent'], 0).clamp(0, 4),
      lineSpacing:
          AppHelpers.parseDouble(json['lineSpacing'], 1.35).clamp(1.0, 2.5),
      tableRows: parsedRows,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'kind': kind,
      'text': text,
      'bold': bold,
      'italic': italic,
      'underline': underline,
      'fontFamily': fontFamily,
      'fontSize': fontSize,
      'align': align,
      'colorHex': colorHex,
      'indent': indent,
      'lineSpacing': lineSpacing,
      if (tableRows.isNotEmpty) 'tableRows': tableRows,
    };
  }

  BrandedDocBlock copyWith({
    String? id,
    String? kind,
    String? text,
    bool? bold,
    bool? italic,
    bool? underline,
    String? fontFamily,
    double? fontSize,
    String? align,
    String? colorHex,
    int? indent,
    double? lineSpacing,
    List<List<String>>? tableRows,
  }) {
    return BrandedDocBlock(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      text: text ?? this.text,
      bold: bold ?? this.bold,
      italic: italic ?? this.italic,
      underline: underline ?? this.underline,
      fontFamily: fontFamily ?? this.fontFamily,
      fontSize: fontSize ?? this.fontSize,
      align: align ?? this.align,
      colorHex: colorHex ?? this.colorHex,
      indent: indent ?? this.indent,
      lineSpacing: lineSpacing ?? this.lineSpacing,
      tableRows: tableRows ??
          this.tableRows.map((r) => List<String>.from(r)).toList(),
    );
  }
}

/// Custom Town Treasure branded document stored in the encrypted vault and
/// rendered with the exact corporate letterhead, watermark, stamp, and signature.
class BrandedDocument {
  const BrandedDocument({
    required this.id,
    required this.title,
    this.documentType = 'OFFICIAL LETTER',
    this.referenceNumber = '',
    this.date = '',
    this.recipientName = '',
    this.recipientContact = '',
    this.recipientAddress = '',
    this.recipientPhone = '',
    this.recipientKraPin = '',
    this.subject = '',
    this.blocks = const [],
    this.showLetterheadBanner = true,
    this.showWatermark = true,
    this.showRecipientCard = true,
    this.showKraPin = true,
    this.showStamp = true,
    this.showSignature = true,
    this.showQrCode = true,
    this.stampCaption = 'AUTHORIZED',
    this.footerNote =
        'Town Treasure Limited · Fresh Produce & Hospitality Supply · Tel: 0708567696 · Nairobi',
    this.pageSize = 'a4',
    this.marginPreset = 'normal',
    this.defaultFontFamily = 'sans',
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  final String id;
  final String title;
  final String documentType;
  final String referenceNumber;
  final String date;
  final String recipientName;
  final String recipientContact;
  final String recipientAddress;
  final String recipientPhone;
  final String recipientKraPin;
  final String subject;
  final List<BrandedDocBlock> blocks;
  final bool showLetterheadBanner;
  final bool showWatermark;
  final bool showRecipientCard;
  final bool showKraPin;
  final bool showStamp;
  final bool showSignature;
  final bool showQrCode;
  final String stampCaption;
  final String footerNote;
  final String pageSize;
  final String marginPreset;
  final String defaultFontFamily;
  final String? createdAt;
  final String? updatedAt;
  final String? deletedAt;

  bool get isDeleted => deletedAt != null && deletedAt!.trim().isNotEmpty;

  static String generateReferenceNumber([int sequenceHint = 1]) {
    final now = DateTime.now();
    final ym =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final suffix = sequenceHint.toString().padLeft(2, '0');
    return 'TTG-DOC-$ym-$suffix';
  }

  factory BrandedDocument.fromTemplate(
    BrandedDocTemplate template, {
    String? refNumber,
    String? dateIso,
  }) {
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final today = dateIso ?? AppHelpers.normalizeAppDate(DateTime.now());
    final ref = refNumber ?? generateReferenceNumber();

    switch (template) {
      case BrandedDocTemplate.blank:
        return BrandedDocument(
          id: AppHelpers.genId(),
          title: 'Untitled Branded Document',
          documentType: 'OFFICIAL DOCUMENT',
          referenceNumber: ref,
          date: today,
          showRecipientCard: false,
          blocks: [
            BrandedDocBlock(
              id: AppHelpers.genId(),
              kind: 'heading1',
              text: 'Document Heading',
              bold: true,
              fontSize: 16,
              colorHex: '#1B5E20',
            ),
            BrandedDocBlock(
              id: AppHelpers.genId(),
              kind: 'paragraph',
              text:
                  'Start typing your official Town Treasure document here. Use the **Home**, **Insert**, **Layout**, and **Brand & Export** tabs above to format fonts, colours, lists, and tables.',
              fontSize: 11,
            ),
          ],
          createdAt: nowIso,
          updatedAt: nowIso,
        );

      case BrandedDocTemplate.businessLetter:
        return BrandedDocument(
          id: AppHelpers.genId(),
          title: 'Official Business Letter',
          documentType: 'OFFICIAL LETTER',
          referenceNumber: ref,
          date: today,
          subject: 'FRESH PRODUCE SUPPLY PARTNERSHIP',
          blocks: [
            BrandedDocBlock(
              id: AppHelpers.genId(),
              kind: 'paragraph',
              text: 'Dear Procurement & Kitchen Management Team,',
              bold: true,
              fontSize: 11,
            ),
            BrandedDocBlock(
              id: AppHelpers.genId(),
              kind: 'paragraph',
              text:
                  'We are pleased to write to you on behalf of **Town Treasure Limited**, Nairobi\'s dedicated hospitality supplier of farm-fresh vegetables, fruits, herbs, and dry kitchen essentials.',
              fontSize: 11,
            ),
            BrandedDocBlock(
              id: AppHelpers.genId(),
              kind: 'paragraph',
              text:
                  'Our team guarantees strict morning cold-chain dispatch, consistent chef-grade sorting, and transparent KRA eTIMS-compliant billing tailored to your kitchen schedule.',
              fontSize: 11,
            ),
            BrandedDocBlock(
              id: AppHelpers.genId(),
              kind: 'paragraph',
              text:
                  'Please reach out to us directly on **0708 567 696** for any custom order scheduling or account inquiries. We truly value your partnership.',
              fontSize: 11,
            ),
            BrandedDocBlock(
              id: AppHelpers.genId(),
              kind: 'paragraph',
              text: 'Yours faithfully,\n**For: Town Treasure Limited**',
              fontSize: 11,
            ),
          ],
          createdAt: nowIso,
          updatedAt: nowIso,
        );

      case BrandedDocTemplate.quotation:
        return BrandedDocument(
          id: AppHelpers.genId(),
          title: 'Supply Quotation & Proposal',
          documentType: 'QUOTATION',
          referenceNumber: ref,
          date: today,
          subject: 'QUOTATION FOR FRESH PRODUCE SUPPLY',
          stampCaption: 'APPROVED QUOTE',
          blocks: [
            BrandedDocBlock(
              id: AppHelpers.genId(),
              kind: 'paragraph',
              text:
                  'Thank you for your inquiry. Below is our official **Town Treasure Limited** supply quotation including morning delivery to your premises:',
              fontSize: 11,
            ),
            BrandedDocBlock(
              id: AppHelpers.genId(),
              kind: 'table',
              fontSize: 10,
              tableRows: const [
                ['Item Description', 'Unit', 'Unit Price (KES)', 'Notes'],
                ['Roma Tomatoes (Grade A)', 'Kg', '120.00', 'Farm fresh'],
                ['Red Bulb Onions', 'Kg', '110.00', 'Dry cured'],
                ['Sweet Capsicum (Mixed)', 'Kg', '160.00', 'Sorted'],
                ['Shangi Potatoes', 'Kg', '85.00', 'Clean washed'],
              ],
            ),
            BrandedDocBlock(
              id: AppHelpers.genId(),
              kind: 'callout',
              text:
                  '**Terms & Validity:** Quoted prices are valid for **14 days** from the date above and include scheduled morning delivery within Nairobi.',
              fontSize: 10.5,
              colorHex: '#1B5E20',
            ),
          ],
          createdAt: nowIso,
          updatedAt: nowIso,
        );

      case BrandedDocTemplate.noticeMemo:
        return BrandedDocument(
          id: AppHelpers.genId(),
          title: 'Client Advisory Notice',
          documentType: 'NOTICE',
          referenceNumber: ref,
          date: today,
          subject: 'SERVICE & SEASONAL SUPPLY UPDATE',
          showRecipientCard: false,
          showKraPin: false,
          blocks: [
            BrandedDocBlock(
              id: AppHelpers.genId(),
              kind: 'heading2',
              text: 'Important Notice to Valued Hospitality Partners',
              bold: true,
              fontSize: 14,
              colorHex: '#1B5E20',
            ),
            BrandedDocBlock(
              id: AppHelpers.genId(),
              kind: 'paragraph',
              text:
                  'Please take note of the following operational updates from **Town Treasure Limited**:',
              fontSize: 11,
            ),
            BrandedDocBlock(
              id: AppHelpers.genId(),
              kind: 'bullet',
              text:
                  'All evening kitchen orders placed before **8:00 PM** are dispatched on the first morning route.',
              fontSize: 11,
            ),
            BrandedDocBlock(
              id: AppHelpers.genId(),
              kind: 'bullet',
              text:
                  'Consolidated monthly statements and KRA eTIMS tax invoices are available upon request.',
              fontSize: 11,
            ),
            BrandedDocBlock(
              id: AppHelpers.genId(),
              kind: 'callout',
              text:
                  'For urgent kitchen top-ups or dispatch coordination, contact our operations desk on **0708 567 696**.',
              fontSize: 10.5,
            ),
          ],
          createdAt: nowIso,
          updatedAt: nowIso,
        );

      case BrandedDocTemplate.deliveryNote:
        return BrandedDocument(
          id: AppHelpers.genId(),
          title: 'Delivery Dispatch Note',
          documentType: 'DELIVERY NOTE',
          referenceNumber: ref,
          date: today,
          subject: 'GOODS DISPATCHED IN FRESH CONDITION',
          showKraPin: false,
          stampCaption: 'DISPATCHED',
          blocks: [
            BrandedDocBlock(
              id: AppHelpers.genId(),
              kind: 'paragraph',
              text:
                  'Please receive and verify the following fresh produce items dispatched by **Town Treasure Limited**:',
              fontSize: 11,
            ),
            BrandedDocBlock(
              id: AppHelpers.genId(),
              kind: 'table',
              fontSize: 10,
              tableRows: const [
                ['Produce Description', 'Unit', 'Qty Ordered', 'Qty Received'],
                ['Fresh Tomatoes', 'Kgs', '25', ''],
                ['Red Onions', 'Kgs', '20', ''],
                ['English Cucumbers', 'Kgs', '10', ''],
              ],
            ),
            BrandedDocBlock(
              id: AppHelpers.genId(),
              kind: 'callout',
              text:
                  '**Receiving Confirmation:** Goods inspected for freshness, grade, and weight upon arrival. Any transit discrepancy must be noted at the time of offloading.',
              fontSize: 9.8,
            ),
            BrandedDocBlock(
              id: AppHelpers.genId(),
              kind: 'signatory',
            ),
          ],
          createdAt: nowIso,
          updatedAt: nowIso,
        );
    }
  }

  factory BrandedDocument.fromJson(Map<String, dynamic> json) {
    final rawBlocks = json['blocks'];
    final parsedBlocks = <BrandedDocBlock>[];
    if (rawBlocks is List) {
      for (final b in rawBlocks) {
        if (b is Map) {
          parsedBlocks.add(
            BrandedDocBlock.fromJson(Map<String, dynamic>.from(b)),
          );
        }
      }
    }
    return BrandedDocument(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? 'Untitled Document').toString(),
      documentType: (json['documentType'] ?? 'OFFICIAL LETTER').toString(),
      referenceNumber: (json['referenceNumber'] ?? '').toString(),
      date: AppHelpers.normalizeAppDate(json['date']),
      recipientName: (json['recipientName'] ?? '').toString(),
      recipientContact:
          Restaurant.sanitizeContact(json['recipientContact']?.toString()),
      recipientAddress: Restaurant.sanitizeClientAddress(
        json['recipientAddress']?.toString(),
      ),
      recipientPhone:
          Restaurant.sanitizeClientPhone(json['recipientPhone']?.toString()),
      recipientKraPin: (json['recipientKraPin'] ?? '').toString(),
      subject: (json['subject'] ?? '').toString(),
      blocks: parsedBlocks,
      showLetterheadBanner: json['showLetterheadBanner'] != false,
      showWatermark: json['showWatermark'] != false,
      showRecipientCard: json['showRecipientCard'] != false,
      showKraPin: json['showKraPin'] != false,
      showStamp: json['showStamp'] != false,
      showSignature: json['showSignature'] != false,
      showQrCode: json['showQrCode'] != false,
      stampCaption: (json['stampCaption'] ?? 'AUTHORIZED').toString(),
      footerNote: (json['footerNote'] ??
              'Town Treasure Limited · Fresh Produce & Hospitality Supply · Tel: 0708567696 · Nairobi')
          .toString(),
      pageSize: (json['pageSize'] ?? 'a4').toString(),
      marginPreset: (json['marginPreset'] ?? 'normal').toString(),
      defaultFontFamily: (json['defaultFontFamily'] ?? 'sans').toString(),
      createdAt: AppHelpers.nullableString(json['createdAt']),
      updatedAt: AppHelpers.nullableString(json['updatedAt']),
      deletedAt: AppHelpers.nullableString(json['deletedAt']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'documentType': documentType,
      'referenceNumber': referenceNumber,
      'date': date,
      'recipientName': recipientName,
      'recipientContact': recipientContact,
      'recipientAddress': recipientAddress,
      'recipientPhone': recipientPhone,
      'recipientKraPin': recipientKraPin,
      'subject': subject,
      'blocks': blocks.map((b) => b.toJson()).toList(),
      'showLetterheadBanner': showLetterheadBanner,
      'showWatermark': showWatermark,
      'showRecipientCard': showRecipientCard,
      'showKraPin': showKraPin,
      'showStamp': showStamp,
      'showSignature': showSignature,
      'showQrCode': showQrCode,
      'stampCaption': stampCaption,
      'footerNote': footerNote,
      'pageSize': pageSize,
      'marginPreset': marginPreset,
      'defaultFontFamily': defaultFontFamily,
      if (createdAt != null) 'createdAt': createdAt,
      if (updatedAt != null) 'updatedAt': updatedAt,
      if (deletedAt != null) 'deletedAt': deletedAt,
    };
  }

  BrandedDocument copyWith({
    String? id,
    String? title,
    String? documentType,
    String? referenceNumber,
    String? date,
    String? recipientName,
    String? recipientContact,
    String? recipientAddress,
    String? recipientPhone,
    String? recipientKraPin,
    String? subject,
    List<BrandedDocBlock>? blocks,
    bool? showLetterheadBanner,
    bool? showWatermark,
    bool? showRecipientCard,
    bool? showKraPin,
    bool? showStamp,
    bool? showSignature,
    bool? showQrCode,
    String? stampCaption,
    String? footerNote,
    String? pageSize,
    String? marginPreset,
    String? defaultFontFamily,
    String? createdAt,
    String? updatedAt,
    String? deletedAt,
    bool clearDeletedAt = false,
  }) {
    return BrandedDocument(
      id: id ?? this.id,
      title: title ?? this.title,
      documentType: documentType ?? this.documentType,
      referenceNumber: referenceNumber ?? this.referenceNumber,
      date: date ?? this.date,
      recipientName: recipientName ?? this.recipientName,
      recipientContact: recipientContact ?? this.recipientContact,
      recipientAddress: recipientAddress ?? this.recipientAddress,
      recipientPhone: recipientPhone ?? this.recipientPhone,
      recipientKraPin: recipientKraPin ?? this.recipientKraPin,
      subject: subject ?? this.subject,
      blocks: blocks ?? this.blocks.map((b) => b.copyWith()).toList(),
      showLetterheadBanner: showLetterheadBanner ?? this.showLetterheadBanner,
      showWatermark: showWatermark ?? this.showWatermark,
      showRecipientCard: showRecipientCard ?? this.showRecipientCard,
      showKraPin: showKraPin ?? this.showKraPin,
      showStamp: showStamp ?? this.showStamp,
      showSignature: showSignature ?? this.showSignature,
      showQrCode: showQrCode ?? this.showQrCode,
      stampCaption: stampCaption ?? this.stampCaption,
      footerNote: footerNote ?? this.footerNote,
      pageSize: pageSize ?? this.pageSize,
      marginPreset: marginPreset ?? this.marginPreset,
      defaultFontFamily: defaultFontFamily ?? this.defaultFontFamily,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
    );
  }
}
