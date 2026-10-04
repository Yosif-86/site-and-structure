import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:pdfx/pdfx.dart';
import 'package:uuid/uuid.dart';

import '../i18n/strings.dart';
import '../services/error_reporter.dart';
import '../services/screen_security.dart';
import '../services/supabase_service.dart';
import '../services/tap_guard.dart';
import '../theme.dart';
import '../widgets/arc_icons.dart';
import '../widgets/dashboard_kit.dart';
import '../widgets/watermark_overlay.dart';

/// Course files: PDFs, Word/Excel/PowerPoint (turned into PDF on the
/// server), photos. Stored privately; students view them only inside the
/// app, with the Arc logo stamped on the file and their own name and phone
/// drawn over it. There is no download, share or print anywhere.

const _bucket = 'course-files';
const _office = {'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx'};
const _images = {'jpg', 'jpeg', 'png'};
const _cad = {'dwg', 'dxf', 'dwf', 'rvt', 'skp'};
const _maxBytes = 50 * 1024 * 1024; // storage limit per file

String _t(String k) => AppStrings.instance.t(k);

ArcIcon _iconFor(String? kind) => kind == 'image' ? ArcIcon.image : ArcIcon.lessons;

// ---------------------------------------------------------------------------
// Student: list on the course page
// ---------------------------------------------------------------------------

class CourseFilesSection extends StatelessWidget {
  final List<Map<String, dynamic>> files;
  final bool unlocked;
  final VoidCallback onLocked;

  const CourseFilesSection({
    super.key,
    required this.files,
    required this.unlocked,
    required this.onLocked,
  });

  @override
  Widget build(BuildContext context) {
    if (files.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DashSection('${_t('course_files')} (${files.length})'),
        for (final f in files) ...[
          DashCard(
            leading: DashIconBadge(
                icon: _iconFor(f['view_type'] as String?),
                accent: AppColors.teal),
            title: f['title'] as String? ?? '—',
            subtitle: f['view_type'] == 'image' ? _t('file_image') : 'PDF',
            trailing: (unlocked || f['is_free'] == true)
                ? ArcIconView(ArcIcon.chevron, size: 16, color: AppColors.muted2)
                : ArcIconView(ArcIcon.lock, size: 16, color: AppColors.muted2),
            onTap: () {
              if (!(unlocked || f['is_free'] == true)) {
                onLocked();
                return;
              }
              if (!TapGuard.allow()) return;
              Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => CourseFileViewerScreen(file: f)));
            },
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Viewer
// ---------------------------------------------------------------------------

class CourseFileViewerScreen extends StatefulWidget {
  final Map<String, dynamic> file;
  const CourseFileViewerScreen({super.key, required this.file});

  @override
  State<CourseFileViewerScreen> createState() => _CourseFileViewerScreenState();
}

class _CourseFileViewerScreenState extends State<CourseFileViewerScreen> {
  Uint8List? _bytes;
  PdfControllerPinch? _pdf;
  String? _error;
  String _mark = '';

  @override
  void initState() {
    super.initState();
    ScreenSecurity.currentScreen = widget.file['title'] as String?;
    _load();
  }

  @override
  void dispose() {
    _pdf?.dispose();
    ScreenSecurity.currentScreen = null;
    super.dispose();
  }

  Future<void> _load() async {
    final sb = SupabaseService.instance.client;
    final user = SupabaseService.instance.currentUser;
    try {
      // The viewer's own name and phone, drawn over every page.
      if (user != null) {
        final p = await sb
            .from('profiles')
            .select('full_name, phone')
            .eq('id', user.id)
            .maybeSingle();
        _mark = [p?['full_name'], p?['phone'] ?? user.email]
            .whereType<String>()
            .where((s) => s.isNotEmpty)
            .join(' · ');
      }
      final path = widget.file['view_path'] as String?;
      if (path == null) throw StateError('not ready');
      // Short-lived link, bytes kept in memory only (never written to disk).
      final url = await sb.storage.from(_bucket).createSignedUrl(path, 60);
      final res = await http.get(Uri.parse(url)).timeout(const Duration(minutes: 2));
      if (res.statusCode != 200) throw HttpException('file ${res.statusCode}');
      if (!mounted) return;
      setState(() {
        _bytes = res.bodyBytes;
        if (widget.file['view_type'] != 'image') {
          _pdf = PdfControllerPinch(document: PdfDocument.openData(res.bodyBytes));
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = ErrorReporter.userMessage(e, page: 'course_file'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isImage = widget.file['view_type'] == 'image';
    Widget body;
    if (_error != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!,
              textAlign: TextAlign.center,
              style: AppFonts.body(color: AppColors.muted)),
        ),
      );
    } else if (_bytes == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (isImage) {
      body = InteractiveViewer(
        maxScale: 6,
        child: Center(child: Image.memory(_bytes!, fit: BoxFit.contain)),
      );
    } else {
      body = PdfViewPinch(controller: _pdf!, padding: 8);
    }
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFF1E1C19),
        appBar: AppBar(
          title: Text(widget.file['title'] as String? ?? '',
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        body: Stack(children: [
          Positioned.fill(child: body),
          if (_mark.isNotEmpty) ...[
            Positioned.fill(
              child: IgnorePointer(child: _TiledWatermark(text: _mark)),
            ),
            Positioned.fill(
              child: IgnorePointer(child: WatermarkOverlay(label: _mark)),
            ),
          ],
        ]),
      ),
    );
  }
}

/// The viewer's name and phone repeated diagonally across the screen, faint
/// enough to read through, everywhere so it can't be cropped out.
class _TiledWatermark extends StatelessWidget {
  final String text;
  const _TiledWatermark({required this.text});

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _TilePainter(text), size: Size.infinite);
}

class _TilePainter extends CustomPainter {
  final String text;
  _TilePainter(this.text);

  @override
  void paint(Canvas canvas, Size size) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: const Color(0xFF808080).withValues(alpha: 0.18),
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(-pi / 6);
    final diag = sqrt(size.width * size.width + size.height * size.height);
    final stepX = tp.width + 70;
    const stepY = 110.0;
    var row = 0;
    for (var y = -diag / 2; y < diag / 2; y += stepY, row++) {
      final shift = (row.isOdd ? stepX / 2 : 0);
      for (var x = -diag / 2 - shift; x < diag / 2; x += stepX) {
        tp.paint(canvas, Offset(x, y));
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _TilePainter old) => old.text != text;
}

// ---------------------------------------------------------------------------
// Teacher: manage a course's files (inside the curriculum view)
// ---------------------------------------------------------------------------

class TeacherCourseFiles extends StatefulWidget {
  final String courseId;
  const TeacherCourseFiles({super.key, required this.courseId});

  @override
  State<TeacherCourseFiles> createState() => _TeacherCourseFilesState();
}

class _TeacherCourseFilesState extends State<TeacherCourseFiles> {
  List<Map<String, dynamic>> _files = [];
  final _title = TextEditingController();
  PlatformFile? _picked;
  bool _isFree = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rows = await SupabaseService.instance.client
          .from('course_files')
          .select('*')
          .eq('course_id', widget.courseId)
          .order('order_index')
          .order('created_at');
      if (!mounted) return;
      setState(() => _files = (rows as List).cast<Map<String, dynamic>>());
    } catch (_) {
      // Table not added yet (add-oct05-fixes.sql): section stays empty.
    }
  }

  Future<void> _pick() async {
    try {
      final r = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: [..._office, ..._images, 'pdf', ..._cad],
        withData: false,
      );
      final f = r?.files.single;
      if (f == null || !mounted) return;
      final ext = (f.extension ?? '').toLowerCase();
      if (_cad.contains(ext)) {
        setState(() => _error = _t('err_cad_export_pdf'));
        return;
      }
      if (f.size > _maxBytes) {
        setState(() => _error = _t('err_file_too_big'));
        return;
      }
      setState(() {
        _picked = f;
        _error = null;
        if (_title.text.trim().isEmpty) {
          _title.text = f.name.replaceAll(RegExp(r'\.[^.]+$'), '');
        }
      });
    } catch (_) {
      if (mounted) setState(() => _error = _t('err_photo_permission'));
    }
  }

  Future<void> _add() async {
    if (_busy) return;
    final f = _picked;
    final title = _title.text.trim();
    if (title.isEmpty || f == null || f.path == null) {
      setState(() => _error = _t('err_file_fields'));
      return;
    }
    final ext = (f.extension ?? '').toLowerCase();
    final kind = ext == 'pdf'
        ? 'pdf'
        : _images.contains(ext)
            ? 'image'
            : 'office';
    final sb = SupabaseService.instance.client;
    final id = const Uuid().v4();
    final rawPath = 'raw/${widget.courseId}/$id.$ext';
    setState(() {
      _busy = true;
      _error = null;
    });
    var uploaded = false;
    try {
      await sb.storage.from(_bucket).upload(rawPath, File(f.path!));
      uploaded = true;
      await sb.from('course_files').insert({
        'id': id,
        'course_id': widget.courseId,
        'title': title,
        'kind': kind,
        'original_name': f.name,
        'raw_path': rawPath,
        'is_free': _isFree,
        'order_index': _files.length,
        'uploaded_by': SupabaseService.instance.currentUser?.id,
      });
      // Server job: convert/stamp. The row shows "processing" until done.
      final token = sb.auth.currentSession?.accessToken;
      await http
          .post(Uri.parse('$kApiBaseUrl/api/course-file'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $token',
              },
              body: jsonEncode({'action': 'start', 'fileId': id}))
          .timeout(const Duration(seconds: 25));
      if (!mounted) return;
      setState(() {
        _picked = null;
        _title.clear();
        _isFree = false;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_t('file_processing_started'))));
      await _load();
    } catch (e) {
      if (uploaded) {
        // Row or job failed: leave nothing half-made behind.
        sb.from('course_files').delete().eq('id', id).ignore();
        sb.storage.from(_bucket).remove([rawPath]).ignore();
      }
      if (mounted) {
        setState(() => _error = ErrorReporter.userMessage(e, page: 'course_file_add'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(Map<String, dynamic> f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(_t('confirm_delete_file')
            .replaceAll('{title}', f['title'] as String? ?? '')),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(_t('cancel'))),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(_t('btn_delete'),
                  style: TextStyle(color: AppColors.error))),
        ],
      ),
    );
    if (ok != true) return;
    final sb = SupabaseService.instance.client;
    try {
      await sb.from('course_files').delete().eq('id', f['id']);
      final paths = [f['view_path'], f['raw_path']].whereType<String>().toList();
      if (paths.isNotEmpty) sb.storage.from(_bucket).remove(paths).ignore();
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(ErrorReporter.userMessage(e, page: 'course_file_delete'))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DashSection('${_t('course_files')} (${_files.length})',
            trailing: IconButton(
                onPressed: _load,
                icon: ArcIconView(ArcIcon.replay, size: 18, color: AppColors.muted2))),
        for (final f in _files) ...[
          DashCard(
            leading: DashIconBadge(
                icon: _iconFor(f['kind'] as String?), accent: AppColors.teal),
            title: f['title'] as String? ?? '—',
            subtitle: f['original_name'] as String? ?? '',
            trailing: StatusPill(
              switch (f['status']) {
                'published' => _t('file_ready'),
                'failed' => _t('file_failed'),
                _ => _t('file_processing'),
              },
              tone: switch (f['status']) {
                'published' => StatusTone.good,
                'failed' => StatusTone.bad,
                _ => StatusTone.warn,
              },
            ),
            actions: [
              if (f['status'] == 'published')
                DashButton(_t('btn_preview'),
                    icon: ArcIcon.image,
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => CourseFileViewerScreen(file: f)))),
              DashButton(_t('btn_delete'),
                  danger: true, icon: ArcIcon.trash, onPressed: () => _delete(f)),
            ],
          ),
          const SizedBox(height: 10),
        ],
        DashFormPanel(
          title: _t('add_course_file'),
          icon: ArcIcon.lessons,
          children: [
            TextField(
                controller: _title,
                decoration: InputDecoration(labelText: _t('label_file_title'))),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _busy ? null : _pick,
              icon: ArcIconView(ArcIcon.plus, size: 16, color: AppColors.text),
              label: Text(_picked?.name ?? _t('btn_choose_file'),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(height: 6),
            Text(_t('file_types_hint'),
                style: AppFonts.body(size: 11.5, color: AppColors.muted2)),
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => setState(() => _isFree = !_isFree),
              child: Row(children: [
                Checkbox(
                    value: _isFree,
                    onChanged: (v) => setState(() => _isFree = v ?? false)),
                Expanded(
                    child: Text(_t('label_free_file'),
                        style: AppFonts.body(size: 13, color: AppColors.muted))),
              ]),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_error!,
                    style: AppFonts.body(size: 12, color: AppColors.error)),
              ),
            ElevatedButton(
              onPressed: _busy ? null : _add,
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text(_t('btn_add')),
            ),
          ],
        ),
      ],
    );
  }
}
