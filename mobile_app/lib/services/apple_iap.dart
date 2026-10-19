import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:in_app_purchase_platform_interface/in_app_purchase_platform_interface.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';

import 'money.dart';
import 'supabase_service.dart';

/// Apple In-App Purchase for paid courses (iPhone only). Apple requires
/// paid courses that open in the iPhone app to be buyable here too
/// (guideline 3.1.1 / 3.1.3(b)); courses bought on the website still
/// unlock as before.
///
/// Each course is sold as one consumable "price level" product picked
/// from its IQD price; the same table lives in api/_apple-iap.js, which
/// checks Apple's signed transaction and turns the course on. A course
/// bought this way belongs to the account forever (the enrollment), so
/// there is nothing to restore on the device.
class AppleIap {
  AppleIap._();
  static final AppleIap instance = AppleIap._();

  static const int iqdPerUsd = 1300;
  static const double appleMarkup = 1.15;
  static const List<(String, double)> products = [
    ('com.arcplatformiq.app.course.t01', 4.99),
    ('com.arcplatformiq.app.course.t02', 9.99),
    ('com.arcplatformiq.app.course.t03', 14.99),
    ('com.arcplatformiq.app.course.t04', 19.99),
    ('com.arcplatformiq.app.course.t05', 29.99),
    ('com.arcplatformiq.app.course.t06', 39.99),
    ('com.arcplatformiq.app.course.t07', 49.99),
    ('com.arcplatformiq.app.course.t08', 69.99),
    ('com.arcplatformiq.app.course.t09', 99.99),
    ('com.arcplatformiq.app.course.t10', 149.99),
    ('com.arcplatformiq.app.course.t11', 199.99),
    ('com.arcplatformiq.app.course.t12', 299.99),
  ];

  /// The product for a course price, or null above the top level.
  static String? productForPrice(String? price) {
    final iqd = Money.digitsOf(price) ?? 0;
    if (iqd <= 0) return null;
    final usd = iqd / iqdPerUsd * appleMarkup;
    for (final (id, p) in products) {
      if (p >= usd) return id;
    }
    return null;
  }

  bool get available => !kIsWeb && Platform.isIOS;

  // Course slug for each product being bought, kept on disk so a purchase
  // that finishes after the app was closed still reaches the right course.
  static const _pendingKey = 'apple_iap_pending';
  final _storage = const FlutterSecureStorage();
  InAppPurchaseStoreKitPlatform? _store;
  StreamSubscription<List<PurchaseDetails>>? _sub;
  final Map<String, ProductDetails> _details = {};
  Completer<String>? _waiting;

  /// Call once at app start (iPhone only). Delivers purchases that were
  /// paid but not yet handed to the server (app closed mid-purchase).
  void init() {
    if (!available || _store != null) return;
    InAppPurchaseStoreKitPlatform.registerPlatform();
    _store = InAppPurchasePlatform.instance as InAppPurchaseStoreKitPlatform;
    _sub = _store!.purchaseStream.listen(_onPurchases, onError: (_) {});
  }

  /// Apple's localised price for the course ("$9.99", "9,99 €"), or null
  /// if the product can't be loaded (no network, product not on sale).
  Future<String?> priceLabel(String? coursePrice) async {
    final d = await _product(productForPrice(coursePrice));
    return d?.price;
  }

  Future<ProductDetails?> _product(String? id) async {
    if (id == null || _store == null) return null;
    if (_details[id] != null) return _details[id];
    try {
      final r = await _store!.queryProductDetails({id});
      for (final p in r.productDetails) {
        _details[p.id] = p;
      }
    } catch (_) {}
    return _details[id];
  }

  /// Buys a course. Resolves to 'enrolled', 'cancelled', 'pending' (Ask to
  /// Buy / bank check, the course turns on later) or an error key.
  Future<String> buy(
      {required String courseSlug, required String? coursePrice}) async {
    final user = SupabaseService.instance.currentUser;
    if (_store == null || user == null) return 'iap_unavailable';
    if (_waiting != null && !_waiting!.isCompleted) return 'iap_busy';
    final product = await _product(productForPrice(coursePrice));
    if (product == null) return 'iap_unavailable';
    await _setPending(product.id, courseSlug);
    final done = Completer<String>();
    _waiting = done;
    try {
      await _store!.buyConsumable(
        purchaseParam: PurchaseParam(
          productDetails: product,
          // Becomes the transaction's appAccountToken; the server checks it.
          applicationUserName: user.id,
        ),
      );
    } catch (e) {
      if (!done.isCompleted) done.complete('iap_failed');
    }
    return done.future
        .timeout(const Duration(minutes: 10), onTimeout: () => 'pending');
  }

  Future<void> _onPurchases(List<PurchaseDetails> list) async {
    for (final p in list) {
      switch (p.status) {
        case PurchaseStatus.pending:
          _finishWaiting('pending');
        case PurchaseStatus.canceled:
          await _complete(p);
          _finishWaiting('cancelled');
        case PurchaseStatus.error:
          await _complete(p);
          _finishWaiting('iap_failed');
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          _finishWaiting(await _deliver(p));
      }
    }
  }

  /// Hands Apple's signed transaction to the server. The transaction is
  /// finished only once the server has answered for good, so a network
  /// failure leaves it with Apple to be delivered again on the next start.
  Future<String> _deliver(PurchaseDetails p) async {
    final slug = await _pendingSlug(p.productID);
    final token =
        SupabaseService.instance.client.auth.currentSession?.accessToken;
    final jws = p.verificationData.serverVerificationData;
    if (slug == null || token == null || jws.isEmpty) return 'iap_retry_later';
    try {
      final res = await http
          .post(Uri.parse('$kApiBaseUrl/api/wayl-checkout'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $token',
              },
              body: jsonEncode(
                  {'provider': 'apple', 'courseSlug': slug, 'jws': jws}))
          .timeout(const Duration(seconds: 25));
      if (res.statusCode >= 500 || res.statusCode == 401) {
        return 'iap_retry_later';
      }
      await _complete(p);
      await _clearPending(p.productID);
      if (res.statusCode == 200) return 'enrolled';
      return 'iap_rejected';
    } catch (_) {
      return 'iap_retry_later';
    }
  }

  Future<void> _complete(PurchaseDetails p) async {
    if (!p.pendingCompletePurchase &&
        p.status != PurchaseStatus.purchased &&
        p.status != PurchaseStatus.restored) {
      return;
    }
    try {
      await _store?.completePurchase(p);
    } catch (_) {}
  }

  void _finishWaiting(String result) {
    final w = _waiting;
    if (w != null && !w.isCompleted) w.complete(result);
  }

  Future<Map<String, String>> _pending() async {
    try {
      final raw = await _storage.read(key: _pendingKey);
      if (raw == null) return {};
      return (jsonDecode(raw) as Map).map((k, v) => MapEntry('$k', '$v'));
    } catch (_) {
      return {};
    }
  }

  Future<void> _setPending(String productId, String slug) async {
    final m = await _pending();
    m[productId] = slug;
    try {
      await _storage.write(key: _pendingKey, value: jsonEncode(m));
    } catch (_) {}
  }

  Future<String?> _pendingSlug(String productId) async =>
      (await _pending())[productId];

  Future<void> _clearPending(String productId) async {
    final m = await _pending()
      ..remove(productId);
    try {
      await _storage.write(key: _pendingKey, value: jsonEncode(m));
    } catch (_) {}
  }

  @visibleForTesting
  Future<void> dispose() async => _sub?.cancel();
}
