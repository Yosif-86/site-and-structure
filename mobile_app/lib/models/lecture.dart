class Lecture {
  final String id;
  final String courseId;
  final String title;
  final String? titleAr;
  final bool isFree;
  final int orderIndex;

  Lecture({
    required this.id,
    required this.courseId,
    required this.title,
    this.titleAr,
    required this.isFree,
    required this.orderIndex,
  });

  factory Lecture.fromJson(Map<String, dynamic> json) => Lecture(
        id: json['id'] as String,
        courseId: json['course_id'] as String,
        title: json['title'] as String? ?? '',
        titleAr: json['title_ar'] as String?,
        isFree: json['is_free'] as bool? ?? false,
        orderIndex: json['order_index'] as int? ?? 0,
      );

  String localizedTitle(bool ar) => (ar && titleAr != null && titleAr!.isNotEmpty) ? titleAr! : title;
}
