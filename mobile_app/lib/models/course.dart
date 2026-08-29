class Course {
  final String id;
  final String slug;
  final String title;
  final String? titleAr;
  final String? description;
  final String? descriptionAr;
  final String? teacherName;
  final String? teacherNameAr;
  final bool isFree;
  final String? price;
  final String? tagLabel;
  final String? tagLabelAr;
  final String? tagColor;
  final String? badgeText;
  final Map<String, dynamic>? meta;
  final Map<String, dynamic>? metaAr;
  final String status;

  Course({
    required this.id,
    required this.slug,
    required this.title,
    this.titleAr,
    this.description,
    this.descriptionAr,
    this.teacherName,
    this.teacherNameAr,
    required this.isFree,
    this.price,
    this.tagLabel,
    this.tagLabelAr,
    this.tagColor,
    this.badgeText,
    this.meta,
    this.metaAr,
    required this.status,
  });

  factory Course.fromJson(Map<String, dynamic> json) => Course(
        id: json['id'] as String,
        slug: json['slug'] as String,
        title: json['title'] as String? ?? '',
        titleAr: json['title_ar'] as String?,
        description: json['description'] as String?,
        descriptionAr: json['description_ar'] as String?,
        teacherName: json['teacher_name'] as String?,
        teacherNameAr: json['teacher_name_ar'] as String?,
        isFree: json['is_free'] as bool? ?? false,
        price: json['price']?.toString(),
        tagLabel: json['tag_label'] as String?,
        tagLabelAr: json['tag_label_ar'] as String?,
        tagColor: json['tag_color'] as String?,
        badgeText: json['badge_text'] as String?,
        meta: json['meta'] as Map<String, dynamic>?,
        metaAr: json['meta_ar'] as Map<String, dynamic>?,
        status: json['status'] as String? ?? 'draft',
      );

  String localizedTitle(bool ar) => (ar && titleAr != null && titleAr!.isNotEmpty) ? titleAr! : title;
  String? localizedDescription(bool ar) =>
      (ar && descriptionAr != null && descriptionAr!.isNotEmpty) ? descriptionAr : description;
  String? localizedTeacherName(bool ar) =>
      (ar && teacherNameAr != null && teacherNameAr!.isNotEmpty) ? teacherNameAr : teacherName;
  String? localizedTagLabel(bool ar) =>
      (ar && tagLabelAr != null && tagLabelAr!.isNotEmpty) ? tagLabelAr : tagLabel;
  Map<String, dynamic>? localizedMeta(bool ar) => (ar && metaAr != null && metaAr!.isNotEmpty) ? metaAr : meta;
}
