import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../services/money.dart';
import '../theme.dart';
import 'arc_icons.dart';
import 'dashboard_kit.dart';

/// Asks why a payment is being rejected. Quick picks plus free text; the
/// reason is shown to the student. Returns null if cancelled.
Future<String?> askRejectReason(BuildContext context,
    {String? title, String? sub, List<String>? presets}) {
  final t = AppStrings.instance.t;
  final ctrl = TextEditingController();
  presets ??= [
    t('reject_amount_mismatch'),
    t('reject_proof_unclear'),
    t('reject_not_received'),
  ];
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(title ?? t('reject_title'),
            style: AppFonts.body(size: 18, weight: FontWeight.w700)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(sub ?? t('reject_sub'),
                  style: AppFonts.body(size: 13, color: AppColors.muted)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in presets!)
                    ChoiceChip(
                      label: Text(p),
                      selected: ctrl.text == p,
                      onSelected: (_) => setState(() => ctrl.text = p),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                maxLines: 3,
                maxLength: 300,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(hintText: t('reject_custom_hint')),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(t('cancel'))),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            onPressed: ctrl.text.trim().isEmpty
                ? null
                : () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: Text(t('btn_reject')),
          ),
        ],
      ),
    ),
  );
}

/// One pending payment request: who, which course, how they paid, the
/// proof, and either approve/reject actions or a read-only note saying who
/// decides it.
class PaymentRequestCard extends StatelessWidget {
  Widget _amountLines(String Function(String) t) {
    final listPrice = Money.digitsOf(price) ?? paid ?? 0;
    final shownPaid = paid ?? listPrice;
    final shownDiscount = discount ?? 0;
    Widget line(String label, String value, {bool strong = false, Color? color}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Row(children: [
            Expanded(
                child: Text(label,
                    style: AppFonts.body(size: 12.5, color: AppColors.muted))),
            Text(value,
                style: AppFonts.code(
                    size: strong ? 15 : 13,
                    weight: strong ? FontWeight.w700 : FontWeight.w500,
                    color: color ?? AppColors.text)),
          ]),
        );
    return Column(children: [
      line(t('pay_lbl_price'), Money.iqd(listPrice)),
      if (shownDiscount > 0)
        line(
            '${t('pay_lbl_discount')}${(code != null && code!.isNotEmpty) ? ' ($code)' : ''}',
            '-${Money.iqd(shownDiscount)}',
            color: AppColors.error),
      line(t('pay_lbl_paid'), Money.iqd(shownPaid),
          strong: true, color: AppColors.teal),
    ]);
  }

  final String studentName;
  final String? contact;
  final String courseTitle;
  final String? price;
  // What was actually charged: list price, discount taken off, amount paid.
  final int? discount;
  final int? paid;
  final String? code;
  final String? method;
  final String? detail;
  final String? createdAt;
  final bool canDecide;
  final String? decidedByNote;
  final VoidCallback? onViewProof;
  final VoidCallback? onApprove;
  final VoidCallback? onReject;

  const PaymentRequestCard({
    super.key,
    required this.studentName,
    required this.courseTitle,
    this.contact,
    this.price,
    this.discount,
    this.paid,
    this.code,
    this.method,
    this.detail,
    this.createdAt,
    required this.canDecide,
    this.decidedByNote,
    this.onViewProof,
    this.onApprove,
    this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    final methodLabel = switch (method) {
      'zain' => t('zain_cash'),
      'qi' => t('qi_card'),
      _ => method ?? '—',
    };
    return DashCard(
      leading: DashAvatar(name: studentName),
      title: studentName,
      subtitle: courseTitle,
      trailing: StatusPill(t('status_pending'), tone: StatusTone.warn),
      meta: [
        if (contact != null && contact!.isNotEmpty) contact!,
        '$methodLabel${detail != null && detail!.isNotEmpty ? ' · $detail' : ''}',
        if (createdAt != null) createdAt!,
      ],
      extra: [
        if (paid != null || Money.digitsOf(price) != null) ...[
          const SizedBox(height: 10),
          _amountLines(t),
        ],
        if (!canDecide && decidedByNote != null) ...[
          const SizedBox(height: 10),
          Row(children: [
            ArcIconView(ArcIcon.clock, size: 16, color: AppColors.muted2),
            const SizedBox(width: 6),
            Expanded(
              child: Text(decidedByNote!,
                  style: AppFonts.body(size: 12, color: AppColors.muted2)),
            ),
          ]),
        ],
      ],
      actions: [
        if (canDecide && onApprove != null)
          DashButton(t('approve'),
              primary: true, icon: ArcIcon.check, onPressed: onApprove),
        if (onViewProof != null)
          DashButton(t('view_proof'), icon: ArcIcon.image, onPressed: onViewProof),
        if (canDecide && onReject != null)
          DashButton(t('btn_reject'),
              danger: true, icon: ArcIcon.close, onPressed: onReject),
      ],
    );
  }
}
