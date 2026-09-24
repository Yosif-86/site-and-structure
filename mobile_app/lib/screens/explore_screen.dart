import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../models/course.dart';
import '../services/error_reporter.dart';
import '../services/learning_service.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/course_card.dart';
import '../widgets/fade_slide_in.dart';
import '../widgets/glass_card.dart';
import '../widgets/glass_scaffold.dart';
import 'course_detail_screen.dart';

enum _PriceFilter { all, free, paid }

/// Search + browse every published course. Opened from the bottom bar's
/// center button. Filtering is client-side over the published catalogue --
/// it's small, already loaded by Home, and this avoids sending the user's
/// search text anywhere.
class ExploreScreen extends StatefulWidget {
  final List<Course>? initialCourses;
  final Map<String, CourseStats>? initialStats;
  const ExploreScreen({super.key, this.initialCourses, this.initialStats});

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  late List<Course>? _courses = widget.initialCourses;
  late Map<String, CourseStats> _stats = widget.initialStats ?? {};
  String? _error;
  final _searchCtrl = TextEditingController();
  String _query = '';
  _PriceFilter _filter = _PriceFilter.all;

  @override
  void initState() {
    super.initState();
    if (_courses == null) _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rows = await SupabaseService.instance.client
          .from('courses')
          .select('*')
          .eq('status', 'published')
          .order('order_index', ascending: true);
      final courses = (rows as List)
          .map((r) => Course.fromJson(r as Map<String, dynamic>))
          .toList();
      Map<String, CourseStats> stats = {};
      try {
        stats = await LearningService.fetchCourseStats(
            courses.map((c) => c.id).toList());
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _courses = courses;
        _stats = stats;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = ErrorReporter.userMessage(e, page: 'explore'));
    }
  }

  List<Course> get _filtered {
    final ar = AppStrings.instance.isAr;
    final q = _query.trim().toLowerCase();
    return (_courses ?? const <Course>[]).where((c) {
      if (_filter == _PriceFilter.free && !c.isFree) return false;
      if (_filter == _PriceFilter.paid && c.isFree) return false;
      if (q.isEmpty) return true;
      final hay = [
        c.localizedTitle(ar),
        c.title,
        c.localizedTeacherName(ar) ?? '',
        c.localizedTagLabel(ar) ?? '',
      ].join(' ').toLowerCase();
      return hay.contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    final results = _filtered;

    return Directionality(
      textDirection:
          AppStrings.instance.isAr ? TextDirection.rtl : TextDirection.ltr,
      child: GlassScaffold(
        appBar: AppBar(title: Text(t('nav_explore'))),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
          children: [
            GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              borderRadius: BorderRadius.circular(16),
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _query = v),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: t('explore_search_hint'),
                  prefixIcon: Icon(Icons.search_rounded, color: AppColors.muted),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: t('btn_clear'),
                          icon: Icon(Icons.close_rounded,
                              color: AppColors.muted),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _query = '');
                          },
                        ),
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                _FilterPill(
                    label: t('filter_all'),
                    selected: _filter == _PriceFilter.all,
                    onTap: () => setState(() => _filter = _PriceFilter.all)),
                _FilterPill(
                    label: t('card_free'),
                    selected: _filter == _PriceFilter.free,
                    onTap: () => setState(() => _filter = _PriceFilter.free)),
                _FilterPill(
                    label: t('filter_paid'),
                    selected: _filter == _PriceFilter.paid,
                    onTap: () => setState(() => _filter = _PriceFilter.paid)),
              ],
            ),
            const SizedBox(height: 16),
            if (_error != null)
              GlassCard(
                padding: const EdgeInsets.all(20),
                child: Column(children: [
                  Text(_error!,
                      textAlign: TextAlign.center,
                      style: AppFonts.body(color: AppColors.muted)),
                  const SizedBox(height: 12),
                  OutlinedButton(onPressed: _load, child: Text(t('retry'))),
                ]),
              )
            else if (_courses == null)
              const Padding(
                padding: EdgeInsets.only(top: 40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (results.isEmpty)
              GlassCard(
                padding: const EdgeInsets.all(24),
                child: Column(children: [
                  Icon(Icons.search_off_rounded,
                      size: 36, color: AppColors.muted2),
                  const SizedBox(height: 10),
                  Text(t('explore_no_results'),
                      textAlign: TextAlign.center,
                      style: AppFonts.body(color: AppColors.muted)),
                ]),
              )
            else ...[
              Text('${results.length} ${t('explore_results')}',
                  style: AppFonts.body(size: 12.5, color: AppColors.muted)),
              const SizedBox(height: 8),
              for (var i = 0; i < results.length; i++) ...[
                FadeSlideIn(
                  delayMs: (i % 8) * 35,
                  child: CourseRow(
                    course: results[i],
                    stats: _stats[results[i].id],
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) =>
                            CourseDetailScreen(slug: results[i].slug))),
                  ),
                ),
                const SizedBox(height: 10),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _FilterPill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _FilterPill(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.red.withValues(alpha: 0.16)
                : AppColors.glassBg,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
                color: selected
                    ? AppColors.red.withValues(alpha: 0.5)
                    : AppColors.glassBorder),
          ),
          child: Text(label,
              style: AppFonts.body(
                  size: 13,
                  weight: FontWeight.w600,
                  color: selected ? AppColors.red : AppColors.text)),
        ),
      ),
    );
  }
}
