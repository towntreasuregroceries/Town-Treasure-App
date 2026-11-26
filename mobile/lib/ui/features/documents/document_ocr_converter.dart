import '../../../data/repositories/vault_repository.dart';
import '../../../data/services/ocr_consensus_service.dart';
import '../../../domain/models/models.dart';
import '../invoices/invoice_formatters.dart';

/// Smart target document role when scanning or importing into Branded Document Studio.
enum DocSmartConversionMode {
  deliveryNote(
    'Delivery Note',
    'Strips prices, totals & fee rows — keeps physical items, units & quantities only',
  ),
  quotation(
    'Quotation / Proforma',
    'Includes pricing table & auto-fills missing LPO prices from Vault Price Lists',
  ),
  discrepancyMemo(
    'Dispatch / Credit Memo',
    'Creates a formal dispatch, short-supply, or adjustment letter linked to the ref #',
  ),
  fullEditableDocument(
    'Editable Word Document',
    'Digitizes headings, paragraphs, bullets & tables for freeform editing',
  );

  const DocSmartConversionMode(this.label, this.subtitle);
  final String label;
  final String subtitle;
}

/// Interactive line-item row staged before generating a Delivery Note, Quotation, or Memo.
class SelectableDocItem {
  const SelectableDocItem({
    required this.id,
    required this.desc,
    required this.orderedQty,
    required this.dispatchedQty,
    required this.unit,
    required this.sellPrice,
    this.selected = true,
    this.excludedReason,
    this.priceAutoFilledFromVault = false,
    this.remarks = '',
  });

  final String id;
  final String desc;
  final double orderedQty;
  final double dispatchedQty;
  final String unit;
  final double sellPrice;
  final bool selected;
  final String? excludedReason;
  final bool priceAutoFilledFromVault;
  final String remarks;

  double get lineTotal => dispatchedQty * sellPrice;
  bool get isPartialQty => (orderedQty - dispatchedQty).abs() > 0.001;

  SelectableDocItem copyWith({
    String? desc,
    double? orderedQty,
    double? dispatchedQty,
    String? unit,
    double? sellPrice,
    bool? selected,
    String? excludedReason,
    bool clearExcludedReason = false,
    bool? priceAutoFilledFromVault,
    String? remarks,
  }) {
    return SelectableDocItem(
      id: id,
      desc: desc ?? this.desc,
      orderedQty: orderedQty ?? this.orderedQty,
      dispatchedQty: dispatchedQty ?? this.dispatchedQty,
      unit: unit ?? this.unit,
      sellPrice: sellPrice ?? this.sellPrice,
      selected: selected ?? this.selected,
      excludedReason:
          clearExcludedReason ? null : (excludedReason ?? this.excludedReason),
      priceAutoFilledFromVault:
          priceAutoFilledFromVault ?? this.priceAutoFilledFromVault,
      remarks: remarks ?? this.remarks,
    );
  }
}

/// Pure domain converter that transforms OCR scans (`OcrDocketResult`,
/// `OcrBrandedDocResult`) or saved `Invoice` records into zero-leakage
/// Town Treasure [BrandedDocument]s and [BrandedDocBlock]s.
class DocumentOcrConverter {
  DocumentOcrConverter._();

  static final List<RegExp> _nonDeliverablePatterns = [
    RegExp(
      r'^(?:delivery|transport|transportation|carriage|freight|shipping|courier|rider|boda(?:\s*boda)?)(?:\s+(?:fee|cost|charge|charges|levy|expense))?$',
      caseSensitive: false,
    ),
    RegExp(
      r'\b(?:delivery\s+(?:fee|cost|charge)|transport\s+(?:fee|cost|charge)|fuel\s+surcharge|service\s+charge|handling\s+fee|packaging\s+fee|crate\s+deposit|bag\s+deposit)\b',
      caseSensitive: false,
    ),
    RegExp(
      r'^(?:sub\s*total|subtotal|grand\s*total|total(?:\s+amount|\s+due)?|vat(?:\s*\d+%)?|output\s+vat|tax(?:\s+amount)?|withholding\s+tax|discount|rebate|credit\s+note|debit\s+note|previous\s+balance|balance\s+(?:b\/f|brought\s+forward|due)|arrears|rounding(?:\s+adjustment)?|m-?pesa\s+(?:fee|charge|transaction))$',
      caseSensitive: false,
    ),
  ];

  /// Returns `true` when [rawDescription] represents a physical deliverable good
  /// rather than a financial fee, transport charge, tax line, or balance row.
  static bool isPhysicalDeliverableItem(String rawDescription) {
    final cleaned = cleanDeliveryItemDescription(rawDescription).trim();
    if (cleaned.isEmpty) return false;
    for (final pattern in _nonDeliverablePatterns) {
      if (pattern.hasMatch(cleaned)) {
        return false;
      }
    }
    return true;
  }

  /// Strips leading row serial numbers (`01.`, `2)`) AND any inline/trailing
  /// currency or unit-price annotations (`@ KSh 120/kg`, `KES 1,500.00`, `@ 80/=`)
  /// so zero pricing ever leaks onto a receiving-bay Delivery Note.
  static String cleanDeliveryItemDescription(String rawDesc) {
    if (rawDesc.trim().isEmpty) return '';
    final spatial = SpatialOcrParser.sanitizeProduceDescription(rawDesc);
    var out = spatial.desc.isNotEmpty ? spatial.desc : rawDesc.trim();

    // Strip leading serial numbers like "01.", "1)", "#3 - "
    out = out.replaceFirst(RegExp(r'^(?:#?\d{1,3}[\.\)\-:]\s*)+'), '');

    // Strip inline or trailing price expressions: "@ 120", "@ KSh 120/kg", "- KES 1,400.00", "80/="
    out = out.replaceAll(
      RegExp(
        r'(?:\s*[-–:]?\s*)?(?:@\s*)?(?:kes|ksh\.?|kshs\.?)\s*[\d,]+(?:\.\d+)?(?:\s*\/=|\s*(?:\/|per)\s*[a-zA-Z]+)?',
        caseSensitive: false,
      ),
      '',
    );
    out = out.replaceAll(
      RegExp(
        r'\s*@\s*[\d,]+(?:\.\d+)?(?:\s*\/=|\s*(?:\/|per)\s*[a-zA-Z]+)?',
        caseSensitive: false,
      ),
      '',
    );
    out = out.replaceAll(RegExp(r'\s+\d[\d,]*(?:\.\d+)?\s*\/='), '');
    out = out.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    // Clean dangling separators (including trailing '@' left after currency stripping)
    out = out.replaceAll(RegExp(r'^[-–:|,@\s]+|[-–:|,@\s]+$'), '').trim();
    return out;
  }

  /// Looks up the best selling price for [itemDesc] from Vault:
  /// 1) Matched restaurant's latest non-draft invoice,
  /// 2) Active Vault Price Lists,
  /// 3) Any recent non-draft invoice in Vault.
  static double? lookupVaultSellingPrice(
    String itemDesc,
    VaultRepository vault, {
    Restaurant? matchedRestaurant,
  }) {
    final targetKey = AppHelpers.canonicalProduce(itemDesc);
    if (targetKey.isEmpty) return null;

    final sortedInvoices = vault.invoices
        .where((inv) => !inv.isDraft)
        .toList()
      ..sort(
        (a, b) => AppHelpers.appDateKey(b.date)
            .compareTo(AppHelpers.appDateKey(a.date)),
      );

    // 1. Client-specific historical selling price
    if (matchedRestaurant != null) {
      for (final inv in sortedInvoices) {
        if (!Restaurant.invoiceBelongsToRestaurant(
          inv,
          matchedRestaurant,
          vault.restaurants,
        )) {
          continue;
        }
        for (final line in inv.items) {
          if (line.sellPrice > 0 &&
              AppHelpers.canonicalProduce(line.desc) == targetKey) {
            return line.sellPrice;
          }
        }
      }
    }

    // 2. Latest active Price List catalog price
    for (final pl in vault.priceLists) {
      for (final it in pl.items) {
        if (!it.isHeader &&
            it.price > 0 &&
            AppHelpers.canonicalProduce(it.name) == targetKey) {
          return it.price;
        }
      }
    }

    // 3. General recent invoice selling price
    for (final inv in sortedInvoices) {
      for (final line in inv.items) {
        if (line.sellPrice > 0 &&
            AppHelpers.canonicalProduce(line.desc) == targetKey) {
          return line.sellPrice;
        }
      }
    }
    return null;
  }

  /// Prepares interactive [SelectableDocItem] rows from scanned or saved invoice items.
  static List<SelectableDocItem> prepareSelectableItems({
    required List<InvoiceLineItem> sourceItems,
    required DocSmartConversionMode mode,
    required VaultRepository vault,
    Restaurant? matchedRestaurant,
  }) {
    final result = <SelectableDocItem>[];
    for (final raw in sourceItems) {
      final cleanDesc = cleanDeliveryItemDescription(raw.desc);
      if (cleanDesc.isEmpty) continue;
      final deliverable = isPhysicalDeliverableItem(raw.desc) &&
          isPhysicalDeliverableItem(cleanDesc);
      final qty = raw.qty > 0 ? raw.qty : 1.0;
      final unit = _formatDisplayUnit(raw.unit);

      if (mode == DocSmartConversionMode.deliveryNote) {
        result.add(
          SelectableDocItem(
            id: AppHelpers.genId(),
            desc: cleanDesc,
            orderedQty: qty,
            dispatchedQty: qty,
            unit: unit,
            sellPrice: 0, // Strictly zeroed on Delivery Notes
            selected: deliverable,
            excludedReason:
                deliverable ? null : 'Non-goods charge excluded from delivery',
          ),
        );
      } else {
        var price = raw.sellPrice;
        var hydrated = false;
        if (price <= 0 && deliverable) {
          final lookedUp = lookupVaultSellingPrice(
            cleanDesc,
            vault,
            matchedRestaurant: matchedRestaurant,
          );
          if (lookedUp != null && lookedUp > 0) {
            price = lookedUp;
            hydrated = true;
          }
        }
        result.add(
          SelectableDocItem(
            id: AppHelpers.genId(),
            desc: cleanDesc,
            orderedQty: qty,
            dispatchedQty: qty,
            unit: unit,
            sellPrice: price,
            selected: mode == DocSmartConversionMode.quotation
                ? deliverable
                : true,
            excludedReason: (!deliverable &&
                    mode == DocSmartConversionMode.quotation)
                ? 'Fee row (optional on quotation)'
                : null,
            priceAutoFilledFromVault: hydrated,
          ),
        );
      }
    }
    return result;
  }

  /// Generates a complete, branded [BrandedDocument] from staged items & metadata.
  static BrandedDocument buildDocumentFromItems({
    required DocSmartConversionMode mode,
    required List<SelectableDocItem> items,
    required VaultRepository vault,
    String recipientName = '',
    Restaurant? matchedRestaurant,
    String sourceReference = '',
    String dateIso = '',
    String driverOrVehicle = '',
    bool showOrderedQtyColumn = false,
    bool? showKraPin,
  }) {
    final effectiveShowKraPin =
        showKraPin ?? (mode != DocSmartConversionMode.deliveryNote);
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final effectiveDate = AppHelpers.normalizeAppDate(dateIso).isNotEmpty
        ? AppHelpers.normalizeAppDate(dateIso)
        : AppHelpers.normalizeAppDate(DateTime.now());
    final seqHint = vault.brandedDocuments.length + 1;

    final resolvedName = matchedRestaurant?.name.trim().isNotEmpty == true
        ? matchedRestaurant!.name.trim()
        : recipientName.trim();
    final resolvedContact = matchedRestaurant?.contact.trim() ?? '';
    final resolvedAddress = matchedRestaurant?.address.trim() ?? '';
    final resolvedPhone = matchedRestaurant?.phone.trim() ?? '';
    final resolvedPin =
        Restaurant.normalizeKraPin(matchedRestaurant?.kraPin);

    final activeItems = items.where((i) => i.selected).toList();
    final blocks = buildBlocksForItems(
      mode: mode,
      activeItems: activeItems,
      sourceReference: sourceReference,
      driverOrVehicle: driverOrVehicle,
      showOrderedQtyColumn: showOrderedQtyColumn,
    );

    final cleanSourceRef = sourceReference.trim();
    switch (mode) {
      case DocSmartConversionMode.deliveryNote:
        final dnRef = cleanSourceRef.isNotEmpty
            ? 'DN-${cleanSourceRef.replaceFirst(RegExp(r'^(?:INV|DN)[-\s]*', caseSensitive: false), '')}'
            : 'TTG-DN-${effectiveDate.replaceAll('-', '')}-${seqHint.toString().padLeft(2, '0')}';
        return BrandedDocument(
          id: AppHelpers.genId(),
          title: resolvedName.isNotEmpty
              ? 'Delivery Note - $resolvedName'
              : 'Delivery Dispatch Note',
          documentType: 'DELIVERY NOTE',
          referenceNumber: dnRef,
          date: effectiveDate,
          recipientName: resolvedName,
          recipientContact: resolvedContact,
          recipientAddress: resolvedAddress,
          recipientPhone: resolvedPhone,
          recipientKraPin: resolvedPin,
          subject: cleanSourceRef.isNotEmpty
              ? 'GOODS DISPATCHED (ORDER / REF: $cleanSourceRef)'
              : 'FRESH PRODUCE DELIVERY DISPATCH',
          showRecipientCard: resolvedName.isNotEmpty,
          showKraPin: effectiveShowKraPin,
          stampCaption: 'DISPATCHED',
          blocks: blocks,
          createdAt: nowIso,
          updatedAt: nowIso,
        );

      case DocSmartConversionMode.quotation:
        final qRef =
            'TTG-QTN-${effectiveDate.replaceAll('-', '')}-${seqHint.toString().padLeft(2, '0')}';
        return BrandedDocument(
          id: AppHelpers.genId(),
          title: resolvedName.isNotEmpty
              ? 'Supply Quotation - $resolvedName'
              : 'Fresh Produce Quotation',
          documentType: 'QUOTATION',
          referenceNumber: qRef,
          date: effectiveDate,
          recipientName: resolvedName,
          recipientContact: resolvedContact,
          recipientAddress: resolvedAddress,
          recipientPhone: resolvedPhone,
          recipientKraPin: resolvedPin,
          subject: cleanSourceRef.isNotEmpty
              ? 'QUOTATION FOR REQUISITION / REF: $cleanSourceRef'
              : 'FRESH PRODUCE SUPPLY QUOTATION',
          showRecipientCard: resolvedName.isNotEmpty,
          showKraPin: effectiveShowKraPin,
          stampCaption: 'APPROVED QUOTE',
          blocks: blocks,
          createdAt: nowIso,
          updatedAt: nowIso,
        );

      case DocSmartConversionMode.discrepancyMemo:
      case DocSmartConversionMode.fullEditableDocument:
        final mRef = BrandedDocument.generateReferenceNumber(seqHint);
        return BrandedDocument(
          id: AppHelpers.genId(),
          title: resolvedName.isNotEmpty
              ? 'Dispatch & Account Memo - $resolvedName'
              : 'Official Dispatch Memorandum',
          documentType: 'MEMORANDUM',
          referenceNumber: mRef,
          date: effectiveDate,
          recipientName: resolvedName,
          recipientContact: resolvedContact,
          recipientAddress: resolvedAddress,
          recipientPhone: resolvedPhone,
          recipientKraPin: resolvedPin,
          subject: cleanSourceRef.isNotEmpty
              ? 'DELIVERY & BILLING RECONCILIATION (REF: $cleanSourceRef)'
              : 'DELIVERY & ORDER RECONCILIATION',
          showRecipientCard: resolvedName.isNotEmpty,
          showKraPin: effectiveShowKraPin,
          stampCaption: 'AUTHORIZED',
          blocks: blocks,
          createdAt: nowIso,
          updatedAt: nowIso,
        );
    }
  }

  /// Builds formatted [BrandedDocBlock]s for either full-document creation or
  /// cursor insertion inside an existing document in `BrandedDocumentEditorScreen`.
  static List<BrandedDocBlock> buildBlocksForItems({
    required DocSmartConversionMode mode,
    required List<SelectableDocItem> activeItems,
    String sourceReference = '',
    String driverOrVehicle = '',
    bool showOrderedQtyColumn = false,
  }) {
    final blocks = <BrandedDocBlock>[];
    final cleanRef = sourceReference.trim();
    final cleanDispatch = driverOrVehicle.trim();

    if (mode == DocSmartConversionMode.deliveryNote) {
      final hasPartial =
          showOrderedQtyColumn || activeItems.any((i) => i.isPartialQty);

      blocks.add(
        BrandedDocBlock(
          id: AppHelpers.genId(),
          kind: 'paragraph',
          text:
              'Please receive, inspect, and sign for the following fresh produce and kitchen supplies dispatched in good condition by **Town Treasure Limited**:',
          fontSize: 11,
        ),
      );

      if (cleanRef.isNotEmpty || cleanDispatch.isNotEmpty) {
        final metaParts = <String>[
          if (cleanRef.isNotEmpty) '**Order / Invoice Ref:** $cleanRef',
          if (cleanDispatch.isNotEmpty) '**Dispatch / Vehicle:** $cleanDispatch',
          '**Total Deliverable Lines:** ${activeItems.length}',
        ];
        blocks.add(
          BrandedDocBlock(
            id: AppHelpers.genId(),
            kind: 'callout',
            text: metaParts.join('    |    '),
            fontSize: 10,
            colorHex: '#1B5E20',
          ),
        );
      }

      final tableRows = <List<String>>[
        if (hasPartial)
          const [
            '#',
            'Item / Produce Description',
            'Unit',
            'Qty Ordered',
            'Qty Dispatched',
            'Received / Remarks',
          ]
        else
          const [
            '#',
            'Item / Produce Description',
            'Unit',
            'Qty Dispatched',
            'Received / Remarks',
          ],
        for (var idx = 0; idx < activeItems.length; idx++)
          if (hasPartial)
            [
              (idx + 1).toString().padLeft(2, '0'),
              activeItems[idx].desc,
              activeItems[idx].unit,
              _fmtQty(activeItems[idx].orderedQty),
              _fmtQty(activeItems[idx].dispatchedQty),
              activeItems[idx].remarks,
            ]
          else
            [
              (idx + 1).toString().padLeft(2, '0'),
              activeItems[idx].desc,
              activeItems[idx].unit,
              _fmtQty(activeItems[idx].dispatchedQty),
              activeItems[idx].remarks,
            ],
      ];

      blocks.add(
        BrandedDocBlock(
          id: AppHelpers.genId(),
          kind: 'table',
          fontSize: 10,
          tableRows: tableRows,
        ),
      );

      blocks.add(
        BrandedDocBlock(
          id: AppHelpers.genId(),
          kind: 'callout',
          text:
              '**Receiving Confirmation:** Goods inspected for freshness, grade, and weight upon arrival. Any transit discrepancy must be noted at the time of offloading.',
          fontSize: 9.8,
        ),
      );

      blocks.add(
        BrandedDocBlock(
          id: AppHelpers.genId(),
          kind: 'signatory',
          text: cleanDispatch,
        ),
      );
      return blocks;
    }

    if (mode == DocSmartConversionMode.quotation) {
      blocks.add(
        BrandedDocBlock(
          id: AppHelpers.genId(),
          kind: 'paragraph',
          text:
              'We are pleased to submit our official **Town Treasure Limited** supply quotation for the items listed below:',
          fontSize: 11,
        ),
      );

      var grandTotal = 0.0;
      final rows = <List<String>>[
        const [
          '#',
          'Item Description',
          'Qty',
          'Unit',
          'Unit Price (KES)',
          'Line Total (KES)',
        ],
      ];
      for (var i = 0; i < activeItems.length; i++) {
        final it = activeItems[i];
        final total = it.lineTotal;
        grandTotal += total;
        rows.add([
          (i + 1).toString().padLeft(2, '0'),
          it.desc,
          _fmtQty(it.dispatchedQty),
          it.unit,
          it.sellPrice > 0 ? InvoiceFormatters.formatMoney(it.sellPrice) : '-',
          total > 0 ? InvoiceFormatters.formatMoney(total) : '-',
        ]);
      }
      if (grandTotal > 0) {
        rows.add([
          '',
          '**GRAND TOTAL (KES)**',
          '',
          '',
          '',
          '**${InvoiceFormatters.formatMoney(grandTotal)}**',
        ]);
      }

      blocks.add(
        BrandedDocBlock(
          id: AppHelpers.genId(),
          kind: 'table',
          fontSize: 9.8,
          tableRows: rows,
        ),
      );

      blocks.add(
        BrandedDocBlock(
          id: AppHelpers.genId(),
          kind: 'callout',
          text:
              '**Terms & Validity:** Prices are valid for **14 days** and include morning cold-chain delivery within Nairobi. Contact **0708 567 696** to confirm dispatch.',
          fontSize: 10,
          colorHex: '#1B5E20',
        ),
      );
      return blocks;
    }

    // Discrepancy / Credit / Dispatch Memo
    blocks.add(
      BrandedDocBlock(
        id: AppHelpers.genId(),
        kind: 'paragraph',
        text: cleanRef.isNotEmpty
            ? 'Reference is made to Order / Invoice **$cleanRef**. Please find below the verified schedule of items for your receiving and accounts team:'
            : 'Please find below the verified item schedule for your receiving and accounts records:',
        fontSize: 11,
      ),
    );
    blocks.add(
      BrandedDocBlock(
        id: AppHelpers.genId(),
        kind: 'table',
        fontSize: 10,
        tableRows: [
          const ['#', 'Item Description', 'Qty', 'Unit', 'Remarks'],
          for (var i = 0; i < activeItems.length; i++)
            [
              (i + 1).toString().padLeft(2, '0'),
              activeItems[i].desc,
              _fmtQty(activeItems[i].dispatchedQty),
              activeItems[i].unit,
              activeItems[i].remarks,
            ],
        ],
      ),
    );
    blocks.add(
      BrandedDocBlock(
        id: AppHelpers.genId(),
        kind: 'paragraph',
        text:
            'Kindly contact **Town Treasure Limited (0708 567 696)** should you require any clarification.\n\nYours faithfully,\n**For: Town Treasure Limited**',
        fontSize: 11,
      ),
    );
    return blocks;
  }

  /// Converts a full-layout [OcrBrandedDocResult] into a ready-to-edit [BrandedDocument].
  static BrandedDocument buildFullDocumentFromOcr({
    required OcrBrandedDocResult ocrResult,
    required VaultRepository vault,
    bool showKraPin = true,
  }) {
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final matched = ocrResult.recipientName.isNotEmpty
        ? Restaurant.resolveName(ocrResult.recipientName, vault.restaurants)
            .restaurant
        : null;

    final ref = ocrResult.referenceNumber.isNotEmpty
        ? ocrResult.referenceNumber
        : BrandedDocument.generateReferenceNumber(
            vault.brandedDocuments.length + 1,
          );

    return BrandedDocument(
      id: AppHelpers.genId(),
      title: ocrResult.title,
      documentType: ocrResult.documentType,
      referenceNumber: ref,
      date: ocrResult.date,
      recipientName: matched?.name ?? ocrResult.recipientName,
      recipientContact:
          matched?.contact.isNotEmpty == true
              ? matched!.contact
              : ocrResult.recipientContact,
      recipientAddress:
          matched?.address.isNotEmpty == true
              ? matched!.address
              : ocrResult.recipientAddress,
      recipientPhone:
          matched?.phone.isNotEmpty == true
              ? matched!.phone
              : ocrResult.recipientPhone,
      recipientKraPin: matched?.kraPin.isNotEmpty == true
          ? matched!.kraPin
          : ocrResult.recipientKraPin,
      subject: ocrResult.subject,
      showRecipientCard:
          (matched?.name ?? ocrResult.recipientName).trim().isNotEmpty,
      showKraPin: showKraPin,
      blocks: ocrResult.blocks.isNotEmpty
          ? ocrResult.blocks
          : [
              BrandedDocBlock(
                id: AppHelpers.genId(),
                kind: 'paragraph',
                text: ocrResult.rawText,
              ),
            ],
      createdAt: nowIso,
      updatedAt: nowIso,
    );
  }

  static String _fmtQty(double qty) {
    if (qty == qty.roundToDouble()) return qty.toInt().toString();
    return qty.toStringAsFixed(2).replaceAll(RegExp(r'\.?0+$'), '');
  }

  static String _formatDisplayUnit(String rawUnit) {
    final norm = OcrConsensusService.normalizeDropdownUnit(rawUnit);
    if (norm.isEmpty) return 'Kgs';
    return norm[0].toUpperCase() + norm.substring(1);
  }
}
