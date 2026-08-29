class Enrollment {
  final String id;
  final String courseSlug;
  final String status; // 'active' | 'pending'
  final DateTime createdAt;

  Enrollment({
    required this.id,
    required this.courseSlug,
    required this.status,
    required this.createdAt,
  });

  bool get isActive => status == 'active';

  factory Enrollment.fromJson(Map<String, dynamic> json) => Enrollment(
        id: json['id'] as String,
        courseSlug: json['course_slug'] as String,
        status: json['status'] as String? ?? 'pending',
        createdAt: DateTime.parse(json['created_at'] as String),
      );
}
