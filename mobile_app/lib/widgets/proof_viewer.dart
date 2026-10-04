import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../i18n/strings.dart';
import '../services/supabase_service.dart';

/// Opens a student's payment-proof screenshot (private bucket) through a
/// 60-second signed URL. Used by admins and by teachers of pay-to-teacher
/// courses (storage policy allows both).
bool _proofOpening = false;

Future<void> openPaymentProof(BuildContext context, String path) async {
  // A double tap used to open two viewers.
  if (_proofOpening) return;
  _proofOpening = true;
  try {
    final signedUrl = await SupabaseService.instance.client.storage
        .from('payment-proofs')
        .createSignedUrl(path, 60);
    if (!context.mounted) return;
    await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ProofViewerScreen(url: signedUrl)));
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(AppStrings.instance.t('alert_proof_failed'))));
  } finally {
    _proofOpening = false;
  }
}

/// Shows a payment-proof screenshot in-app via WebView instead of handing
/// the signed URL to an external browser — the URL never sits in a browser
/// address bar, history, or share sheet, and it expires in 60s regardless.
/// Renders images directly (the common case); a PDF proof falls back to
/// whatever the system WebView does with a bare PDF URL, which varies by
/// device — acceptable since screenshots are the overwhelming majority.
class ProofViewerScreen extends StatefulWidget {
  final String url;
  const ProofViewerScreen({required this.url});

  @override
  State<ProofViewerScreen> createState() => _ProofViewerScreenState();
}

class _ProofViewerScreenState extends State<ProofViewerScreen> {
  late final WebViewController _controller;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // The signed URL's path contains the file name the *student* chose when
    // uploading, so it's attacker-controlled text going into HTML: escaped
    // before interpolation, and JavaScript is off entirely (showing an image
    // needs none) so even a missed edge case can't run script in an admin's
    // session.
    final safeUrl = widget.url
        .replaceAll('&', '&amp;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.disabled)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          if (mounted) setState(() => _loading = false);
        },
      ))
      ..loadHtmlString('''
<!DOCTYPE html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=5">
<style>
  html, body { margin:0; padding:0; background:#000; height:100%; display:flex; align-items:center; justify-content:center; }
  img { max-width:100%; max-height:100vh; width:auto; height:auto; object-fit:contain; }
</style>
</head>
<body><img src="$safeUrl"></body>
</html>
''');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar:
          AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading) const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
