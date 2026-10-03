import 'package:flutter/material.dart';

/// Arc Platform's own line icons: drawn on a 24-unit grid with a 1.8 rounded
/// stroke so they match the continuous-stroke logo, instead of mixing
/// Material's generic set into a branded app. Each icon can render in two
/// states: outline (resting) and duotone (active: same outline plus a soft
/// fill of the same colour).
enum ArcIcon {
  home,
  courses,
  explore,
  profile,
  settings,
  wallet,
  support,
  moon,
  sun,
  shield,
  logout,
  login,
  trash,
  lessons,
  clock,
  play,
  search,
  edit,
  lock,
  dashboard,
  mail,
  award,
  chevron,
  check,
  phone,
  users,
  money,
  review,
  video,
  warning,
  tag,
  alert,
  plus,
  image,
  qr,
  calendar,
  back,
  skipPrev,
  skipNext,
  rewind,
  forward,
  pause,
  replay,
  fullscreen,
  fullscreenExit,
  playlist,
  close,
  download,
  copy,
}

class ArcIconView extends StatelessWidget {
  final ArcIcon icon;
  final double size;
  final Color color;
  final bool active;
  final double stroke;

  const ArcIconView(
    this.icon, {
    super.key,
    this.size = 24,
    required this.color,
    this.active = false,
    this.stroke = 1.8,
  });

  @override
  Widget build(BuildContext context) {
    // Chevrons and arrows point "forward", which is left in Arabic.
    final mirror = (icon == ArcIcon.chevron || icon == ArcIcon.back) &&
        Directionality.of(context) == TextDirection.rtl;
    Widget paint = CustomPaint(
      size: Size.square(size),
      painter: _ArcIconPainter(icon, color, active, stroke),
    );
    if (mirror) {
      paint = Transform.flip(flipX: true, child: paint);
    }
    return ExcludeSemantics(child: paint);
  }
}

enum _Fill { none, active, solid }

class _Shape {
  final String? d;
  final double cx, cy, r;
  final _Fill fill;
  final bool stroke;
  const _Shape.path(this.d, {this.fill = _Fill.none, this.stroke = true})
      : cx = 0,
        cy = 0,
        r = 0;
  const _Shape.circle(this.cx, this.cy, this.r,
      {this.fill = _Fill.none})
      : stroke = true,
        d = null;
}

const _icons = <ArcIcon, List<_Shape>>{
  ArcIcon.home: [
    _Shape.path('M5.5 9 L12 4 L18.5 9 V19 Q18.5 20.5 17 20.5 H7 Q5.5 20.5 5.5 19 Z',
        fill: _Fill.active, stroke: false),
    _Shape.path('M3.5 10.4 L12 3.6 L20.5 10.4'),
    _Shape.path('M5.5 8.8 V19 Q5.5 20.5 7 20.5 H17 Q18.5 20.5 18.5 19 V8.8'),
    _Shape.path('M9.75 20.5 V15.9 A2.25 2.25 0 0 1 14.25 15.9 V20.5'),
  ],
  ArcIcon.courses: [
    _Shape.path(
        'M12 6.8 C10.2 5.3 7.4 4.7 3.8 5 V18.6 C7.4 18.3 10.2 18.9 12 20.4 C13.8 18.9 16.6 18.3 20.2 18.6 V5 C16.6 4.7 13.8 5.3 12 6.8 Z',
        fill: _Fill.active),
    _Shape.path('M12 6.8 V20.2'),
  ],
  ArcIcon.explore: [
    _Shape.circle(12, 12, 8.8, fill: _Fill.active),
    _Shape.path('M15.6 8.4 L13.3 13.3 L8.4 15.6 L10.7 10.7 Z', fill: _Fill.solid),
  ],
  ArcIcon.profile: [
    _Shape.circle(12, 8.3, 3.6, fill: _Fill.active),
    _Shape.path('M4.8 20.2 C5.4 16.6 8.4 14.6 12 14.6 C15.6 14.6 18.6 16.6 19.2 20.2 Z',
        fill: _Fill.active, stroke: false),
    _Shape.path('M4.8 20.2 C5.4 16.6 8.4 14.6 12 14.6 C15.6 14.6 18.6 16.6 19.2 20.2'),
  ],
  ArcIcon.settings: [
    _Shape.path('M4 7 H12.8 M17.2 7 H20 M4 12 H6.3 M10.7 12 H20 M4 17 H13.8 M18.2 17 H20'),
    _Shape.circle(15, 7, 2.2, fill: _Fill.active),
    _Shape.circle(8.5, 12, 2.2, fill: _Fill.active),
    _Shape.circle(16, 17, 2.2, fill: _Fill.active),
  ],
  ArcIcon.wallet: [
    _Shape.path(
        'M6 7 H18 Q20.5 7 20.5 9.5 V17 Q20.5 19.5 18 19.5 H6 Q3.5 19.5 3.5 17 V9.5 Q3.5 7 6 7 Z',
        fill: _Fill.active),
    _Shape.path('M5.5 7 L15 4.2 Q16.8 3.7 17.1 5.4 L17.4 7'),
    _Shape.path('M20.5 11 H16.6 A2 2 0 0 0 16.6 15 H20.5'),
    _Shape.circle(16.7, 13, 0.6, fill: _Fill.solid),
  ],
  ArcIcon.support: [
    _Shape.path('M4.5 13.5 V12 A7.5 7.5 0 0 1 19.5 12 V13.5'),
    _Shape.path('M4.5 12.5 H5.8 Q7 12.5 7 13.7 V16.8 Q7 18 5.8 18 H4.5 Q3.5 18 3.5 17 V13.5 Q3.5 12.5 4.5 12.5 Z',
        fill: _Fill.active),
    _Shape.path('M19.5 12.5 H18.2 Q17 12.5 17 13.7 V16.8 Q17 18 18.2 18 H19.5 Q20.5 18 20.5 17 V13.5 Q20.5 12.5 19.5 12.5 Z',
        fill: _Fill.active),
    _Shape.path('M20 18 Q20 20.5 16.5 20.5 H13.5'),
  ],
  ArcIcon.moon: [
    _Shape.path('M19.5 14.6 A8 8 0 1 1 9.4 4.5 A6.5 6.5 0 0 0 19.5 14.6 Z',
        fill: _Fill.active),
  ],
  ArcIcon.sun: [
    _Shape.circle(12, 12, 4, fill: _Fill.active),
    _Shape.path(
        'M12 3 V4.8 M12 19.2 V21 M3 12 H4.8 M19.2 12 H21 M5.6 5.6 L6.9 6.9 M17.1 17.1 L18.4 18.4 M5.6 18.4 L6.9 17.1 M17.1 6.9 L18.4 5.6'),
  ],
  ArcIcon.shield: [
    _Shape.path('M12 3.5 L19 6.2 V11.5 C19 15.8 16 19 12 20.5 C8 19 5 15.8 5 11.5 V6.2 Z',
        fill: _Fill.active),
    _Shape.path('M9 12 L11.2 14.2 L15.2 10'),
  ],
  ArcIcon.logout: [
    _Shape.path('M10 4.5 H6.5 Q5 4.5 5 6 V18 Q5 19.5 6.5 19.5 H10'),
    _Shape.path('M10.5 12 H19.5 M16 8.5 L19.5 12 L16 15.5'),
  ],
  ArcIcon.login: [
    _Shape.path('M14 4.5 H17.5 Q19 4.5 19 6 V18 Q19 19.5 17.5 19.5 H14'),
    _Shape.path('M4.5 12 H13.5 M10 8.5 L13.5 12 L10 15.5'),
  ],
  ArcIcon.trash: [
    _Shape.path('M6.5 6.5 L7.3 18.6 Q7.4 20 8.8 20 H15.2 Q16.6 20 16.7 18.6 L17.5 6.5 Z',
        fill: _Fill.active, stroke: false),
    _Shape.path('M4.5 6.5 H19.5'),
    _Shape.path('M9.5 6.5 V5 Q9.5 4 10.5 4 H13.5 Q14.5 4 14.5 5 V6.5'),
    _Shape.path('M6.5 6.5 L7.3 18.6 Q7.4 20 8.8 20 H15.2 Q16.6 20 16.7 18.6 L17.5 6.5'),
    _Shape.path('M10.2 10 V16.5 M13.8 10 V16.5'),
  ],
  ArcIcon.lessons: [
    _Shape.path(
        'M6.5 5 H17.5 Q20.5 5 20.5 8 V16 Q20.5 19 17.5 19 H6.5 Q3.5 19 3.5 16 V8 Q3.5 5 6.5 5 Z',
        fill: _Fill.active),
    _Shape.path('M10.3 9.3 L14.8 12 L10.3 14.7 Z', fill: _Fill.solid),
  ],
  ArcIcon.clock: [
    _Shape.circle(12, 12, 8.5, fill: _Fill.active),
    _Shape.path('M12 7.5 V12 L15 14'),
  ],
  ArcIcon.play: [
    _Shape.path('M8.5 5.8 Q8.5 4.6 9.6 5.2 L18.2 11.1 Q19.1 12 18.2 12.9 L9.6 18.8 Q8.5 19.4 8.5 18.2 Z',
        fill: _Fill.solid),
  ],
  ArcIcon.search: [
    _Shape.circle(11, 11, 6.5, fill: _Fill.active),
    _Shape.path('M16 16 L20 20'),
  ],
  ArcIcon.edit: [
    _Shape.path(
        'M4.5 19.5 L5.3 15.8 L15.6 5.5 Q16.8 4.3 18 5.5 L18.5 6 Q19.7 7.2 18.5 8.4 L8.2 18.7 Z',
        fill: _Fill.active),
    _Shape.path('M14 7.1 L16.9 10'),
  ],
  ArcIcon.lock: [
    _Shape.path(
        'M7.5 10.5 H16.5 Q19 10.5 19 13 V18 Q19 20.5 16.5 20.5 H7.5 Q5 20.5 5 18 V13 Q5 10.5 7.5 10.5 Z',
        fill: _Fill.active),
    _Shape.path('M8 10.5 V8 A4 4 0 0 1 16 8 V10.5'),
    _Shape.circle(12, 15.5, 1.2, fill: _Fill.solid),
  ],
  ArcIcon.dashboard: [
    _Shape.path('M5.5 4 H9 Q10.5 4 10.5 5.5 V9 Q10.5 10.5 9 10.5 H5.5 Q4 10.5 4 9 V5.5 Q4 4 5.5 4 Z',
        fill: _Fill.active),
    _Shape.path('M15 4 H18.5 Q20 4 20 5.5 V9 Q20 10.5 18.5 10.5 H15 Q13.5 10.5 13.5 9 V5.5 Q13.5 4 15 4 Z'),
    _Shape.path('M5.5 13.5 H9 Q10.5 13.5 10.5 15 V18.5 Q10.5 20 9 20 H5.5 Q4 20 4 18.5 V15 Q4 13.5 5.5 13.5 Z'),
    _Shape.path('M15 13.5 H18.5 Q20 13.5 20 15 V18.5 Q20 20 18.5 20 H15 Q13.5 20 13.5 18.5 V15 Q13.5 13.5 15 13.5 Z',
        fill: _Fill.active),
  ],
  ArcIcon.mail: [
    _Shape.path(
        'M6 5.5 H18 Q20.5 5.5 20.5 8 V16 Q20.5 18.5 18 18.5 H6 Q3.5 18.5 3.5 16 V8 Q3.5 5.5 6 5.5 Z',
        fill: _Fill.active),
    _Shape.path('M4.6 7.2 L12 12.4 L19.4 7.2'),
  ],
  ArcIcon.award: [
    _Shape.circle(12, 9.5, 5.5, fill: _Fill.active),
    _Shape.path('M8.8 14 L7.5 20.5 L12 18.3 L16.5 20.5 L15.2 14'),
  ],
  ArcIcon.chevron: [
    _Shape.path('M9.5 6 L15.5 12 L9.5 18'),
  ],
  ArcIcon.check: [
    _Shape.path('M5 12.5 L9.8 17 L19 7.5'),
  ],
  ArcIcon.users: [
    _Shape.circle(9, 8.5, 3.2, fill: _Fill.active),
    _Shape.path('M3.5 19.5 C4 16.2 6.3 14.3 9 14.3 C11.7 14.3 14 16.2 14.5 19.5 Z',
        fill: _Fill.active, stroke: false),
    _Shape.path('M3.5 19.5 C4 16.2 6.3 14.3 9 14.3 C11.7 14.3 14 16.2 14.5 19.5'),
    _Shape.path('M15.2 6.2 A2.7 2.7 0 1 1 15.6 11.6'),
    _Shape.path('M16.4 14.4 C18.6 14.6 20.2 16.4 20.6 19'),
  ],
  ArcIcon.money: [
    _Shape.path('M5 6.5 H19 Q21 6.5 21 8.5 V15.5 Q21 17.5 19 17.5 H5 Q3 17.5 3 15.5 V8.5 Q3 6.5 5 6.5 Z',
        fill: _Fill.active),
    _Shape.circle(12, 12, 2.6),
    _Shape.circle(6.6, 12, 0.8, fill: _Fill.solid),
    _Shape.circle(17.4, 12, 0.8, fill: _Fill.solid),
  ],
  ArcIcon.review: [
    _Shape.path('M7 5 H17 Q19 5 19 7 V19 Q19 21 17 21 H7 Q5 21 5 19 V7 Q5 5 7 5 Z',
        fill: _Fill.active),
    _Shape.path('M9.5 3.5 H14.5 Q15.3 3.5 15.3 4.3 V6.2 Q15.3 7 14.5 7 H9.5 Q8.7 7 8.7 6.2 V4.3 Q8.7 3.5 9.5 3.5 Z'),
    _Shape.path('M9 13.6 L11.2 15.8 L15.2 11.4'),
  ],
  ArcIcon.video: [
    _Shape.path('M5.5 7 H13.5 Q16 7 16 9.5 V14.5 Q16 17 13.5 17 H5.5 Q3 17 3 14.5 V9.5 Q3 7 5.5 7 Z',
        fill: _Fill.active),
    _Shape.path('M16 10.6 L20 8.2 Q21 7.7 21 8.8 V15.2 Q21 16.3 20 15.8 L16 13.4'),
  ],
  ArcIcon.warning: [
    _Shape.path('M10.6 5.2 Q12 3 13.4 5.2 L20.6 17.6 Q21.7 19.5 19.5 19.5 H4.5 Q2.3 19.5 3.4 17.6 Z',
        fill: _Fill.active),
    _Shape.path('M12 9.5 V13.4'),
    _Shape.circle(12, 16.4, 0.95, fill: _Fill.solid),
  ],
  ArcIcon.tag: [
    _Shape.path('M4 11.6 V5.5 Q4 4 5.5 4 H11.6 L20 12.4 Q21 13.4 20 14.4 L14.4 20 Q13.4 21 12.4 20 Z',
        fill: _Fill.active),
    _Shape.circle(8.4, 8.4, 1.5),
  ],
  ArcIcon.alert: [
    _Shape.circle(12, 12, 8.5, fill: _Fill.active),
    _Shape.path('M12 7.6 V12.6'),
    _Shape.circle(12, 15.9, 0.95, fill: _Fill.solid),
  ],
  ArcIcon.plus: [
    _Shape.path('M12 5 V19 M5 12 H19'),
  ],
  ArcIcon.image: [
    _Shape.path('M6 4.5 H18 Q19.5 4.5 19.5 6 V18 Q19.5 19.5 18 19.5 H6 Q4.5 19.5 4.5 18 V6 Q4.5 4.5 6 4.5 Z',
        fill: _Fill.active),
    _Shape.path('M4.8 16.5 L9.5 11.6 L13 15 L15.5 12.6 L19.3 16.3'),
    _Shape.circle(15, 8.6, 1.5),
  ],
  ArcIcon.qr: [
    _Shape.path('M5.5 4.5 H9 Q10 4.5 10 5.5 V9 Q10 10 9 10 H5.5 Q4.5 10 4.5 9 V5.5 Q4.5 4.5 5.5 4.5 Z',
        fill: _Fill.active),
    _Shape.path('M15 4.5 H18.5 Q19.5 4.5 19.5 5.5 V9 Q19.5 10 18.5 10 H15 Q14 10 14 9 V5.5 Q14 4.5 15 4.5 Z',
        fill: _Fill.active),
    _Shape.path('M5.5 14 H9 Q10 14 10 15 V18.5 Q10 19.5 9 19.5 H5.5 Q4.5 19.5 4.5 18.5 V15 Q4.5 14 5.5 14 Z',
        fill: _Fill.active),
    _Shape.path('M14 14 H16.2 V16.2 H14 Z M17.3 17.3 H19.5 V19.5 H17.3 Z', fill: _Fill.solid),
    _Shape.path('M18.4 14 V15.4 M14 18.4 V19.5'),
  ],
  ArcIcon.calendar: [
    _Shape.path('M6 5.5 H18 Q20 5.5 20 7.5 V18 Q20 20 18 20 H6 Q4 20 4 18 V7.5 Q4 5.5 6 5.5 Z',
        fill: _Fill.active),
    _Shape.path('M4 10 H20 M8.5 3.5 V7 M15.5 3.5 V7'),
  ],
  ArcIcon.back: [
    _Shape.path('M19 12 H5.5 M11 6.5 L5.5 12 L11 17.5'),
  ],
  ArcIcon.skipPrev: [
    _Shape.path('M6.5 6 V18'),
    _Shape.path('M18 6.6 Q18 5.5 17.1 6.1 L9.6 11.2 Q8.6 12 9.6 12.8 L17.1 17.9 Q18 18.5 18 17.4 Z',
        fill: _Fill.solid),
  ],
  ArcIcon.skipNext: [
    _Shape.path('M17.5 6 V18'),
    _Shape.path('M6 6.6 Q6 5.5 6.9 6.1 L14.4 11.2 Q15.4 12 14.4 12.8 L6.9 17.9 Q6 18.5 6 17.4 Z',
        fill: _Fill.solid),
  ],
  ArcIcon.rewind: [
    _Shape.path('M12 4.5 A7.5 7.5 0 1 1 4.5 12'),
    _Shape.path('M14.6 2.1 L12 4.5 L14.6 6.9'),
  ],
  ArcIcon.forward: [
    _Shape.path('M12 4.5 A7.5 7.5 0 1 0 19.5 12'),
    _Shape.path('M9.4 2.1 L12 4.5 L9.4 6.9'),
  ],
  ArcIcon.pause: [
    _Shape.path('M8 5.5 H9.8 Q10.8 5.5 10.8 6.5 V17.5 Q10.8 18.5 9.8 18.5 H8 Q7 18.5 7 17.5 V6.5 Q7 5.5 8 5.5 Z M14.2 5.5 H16 Q17 5.5 17 6.5 V17.5 Q17 18.5 16 18.5 H14.2 Q13.2 18.5 13.2 17.5 V6.5 Q13.2 5.5 14.2 5.5 Z',
        fill: _Fill.solid),
  ],
  ArcIcon.replay: [
    _Shape.path('M5 12 A7 7 0 1 0 7.2 6.9'),
    _Shape.path('M6.6 3.4 L7.2 7 L10.8 6.5'),
  ],
  ArcIcon.fullscreen: [
    _Shape.path(
        'M4.5 9 V5.5 Q4.5 4.5 5.5 4.5 H9 M15 4.5 H18.5 Q19.5 4.5 19.5 5.5 V9 M19.5 15 V18.5 Q19.5 19.5 18.5 19.5 H15 M9 19.5 H5.5 Q4.5 19.5 4.5 18.5 V15'),
  ],
  ArcIcon.fullscreenExit: [
    _Shape.path(
        'M9 4.5 V8 Q9 9 8 9 H4.5 M15 4.5 V8 Q15 9 16 9 H19.5 M19.5 15 H16 Q15 15 15 16 V19.5 M4.5 15 H8 Q9 15 9 16 V19.5'),
  ],
  ArcIcon.playlist: [
    _Shape.path('M4 7 H16 M4 12 H16 M4 17 H11'),
    _Shape.path('M15 14.4 L20.4 17.4 L15 20.4 Z', fill: _Fill.solid),
  ],
  ArcIcon.download: [
    _Shape.path('M12 4 V14.5 M7.5 10 L12 14.5 L16.5 10'),
    _Shape.path('M5 19.5 H19'),
  ],
  ArcIcon.copy: [
    _Shape.path('M9.5 8 H17 Q19.5 8 19.5 10.5 V18 Q19.5 20.5 17 20.5 H9.5 Q7 20.5 7 18 V10.5 Q7 8 9.5 8 Z',
        fill: _Fill.active),
    _Shape.path('M4.5 15.5 V6 Q4.5 3.5 7 3.5 H15'),
  ],
  ArcIcon.close: [
    _Shape.path('M6.5 6.5 L17.5 17.5 M17.5 6.5 L6.5 17.5'),
  ],
  ArcIcon.phone: [
    _Shape.path(
        'M8.5 3.5 H15.5 Q17.5 3.5 17.5 5.5 V18.5 Q17.5 20.5 15.5 20.5 H8.5 Q6.5 20.5 6.5 18.5 V5.5 Q6.5 3.5 8.5 3.5 Z',
        fill: _Fill.active),
    _Shape.path('M10.5 17.5 H13.5'),
  ],
};

class _ArcIconPainter extends CustomPainter {
  final ArcIcon icon;
  final Color color;
  final bool active;
  final double stroke;
  _ArcIconPainter(this.icon, this.color, this.active, this.stroke);

  static final _cache = <String, Path>{};

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    final soft = Paint()..color = color.withValues(alpha: 0.24);
    final solid = Paint()..color = color;

    for (final s in _icons[icon]!) {
      final path = s.d != null
          ? _cache.putIfAbsent(s.d!, () => _parse(s.d!))
          : (Path()..addOval(Rect.fromCircle(center: Offset(s.cx, s.cy), radius: s.r)));
      if (s.fill == _Fill.solid) canvas.drawPath(path, solid);
      if (s.fill == _Fill.active && active) canvas.drawPath(path, soft);
      if (s.stroke && s.fill != _Fill.solid) canvas.drawPath(path, line);
    }
    // The 10-second skip icons carry their number inside the arrow.
    if (icon == ArcIcon.rewind || icon == ArcIcon.forward) {
      final tp = TextPainter(
        text: TextSpan(
            text: '10',
            style: TextStyle(
                fontSize: 6.8,
                fontWeight: FontWeight.w800,
                color: color,
                height: 1)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(12 - tp.width / 2, 12.4 - tp.height / 2));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ArcIconPainter old) =>
      old.icon != icon ||
      old.color != color ||
      old.active != active ||
      old.stroke != stroke;
}

/// Minimal SVG path reader for the absolute commands the icons above use:
/// M L H V C Q A Z.
Path _parse(String d) {
  final tokens =
      RegExp(r'[MLHVCQAZ]|-?\d*\.?\d+').allMatches(d).map((m) => m.group(0)!).toList();
  final p = Path();
  var i = 0;
  var cmd = 'M';
  double x = 0, y = 0;
  double n() => double.parse(tokens[i++]);
  while (i < tokens.length) {
    final t = tokens[i];
    if (RegExp(r'^[A-Z]$').hasMatch(t)) {
      cmd = t;
      i++;
      if (cmd == 'Z') {
        p.close();
        continue;
      }
    }
    switch (cmd) {
      case 'M':
        x = n();
        y = n();
        p.moveTo(x, y);
        cmd = 'L';
        break;
      case 'L':
        x = n();
        y = n();
        p.lineTo(x, y);
        break;
      case 'H':
        x = n();
        p.lineTo(x, y);
        break;
      case 'V':
        y = n();
        p.lineTo(x, y);
        break;
      case 'C':
        final x1 = n(), y1 = n(), x2 = n(), y2 = n();
        x = n();
        y = n();
        p.cubicTo(x1, y1, x2, y2, x, y);
        break;
      case 'Q':
        final x1 = n(), y1 = n();
        x = n();
        y = n();
        p.quadraticBezierTo(x1, y1, x, y);
        break;
      case 'A':
        final rx = n(), ry = n();
        final rot = n();
        final large = n() != 0;
        final sweep = n() != 0;
        x = n();
        y = n();
        p.arcToPoint(Offset(x, y),
            radius: Radius.elliptical(rx, ry),
            rotation: rot,
            largeArc: large,
            clockwise: sweep);
        break;
      default:
        i++;
    }
  }
  return p;
}
