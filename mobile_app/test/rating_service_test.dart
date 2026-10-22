import 'package:flutter_test/flutter_test.dart';
import 'package:site_and_structure/services/rating_service.dart';

void main() {
  group('RatingService.dueStage', () {
    test('10 lectures: first ask at the 3rd, second at the 8th', () {
      expect(RatingService.dueStage(0, 10), 0);
      expect(RatingService.dueStage(2, 10), 0);
      expect(RatingService.dueStage(3, 10), 1);
      expect(RatingService.dueStage(7, 10), 1);
      expect(RatingService.dueStage(8, 10), 2);
      expect(RatingService.dueStage(10, 10), 2);
    });

    test('4 lectures: 1st lecture is 25%, 3rd is 75%', () {
      expect(RatingService.dueStage(1, 4), 1);
      expect(RatingService.dueStage(2, 4), 1);
      expect(RatingService.dueStage(3, 4), 2);
    });

    test('small courses never ask before a lecture is finished', () {
      expect(RatingService.dueStage(0, 1), 0);
      expect(RatingService.dueStage(1, 1), 2);
      expect(RatingService.dueStage(0, 2), 0);
      expect(RatingService.dueStage(1, 2), 1);
      expect(RatingService.dueStage(2, 2), 2);
    });

    test('no lectures, nothing to ask', () {
      expect(RatingService.dueStage(0, 0), 0);
      expect(RatingService.dueStage(3, 0), 0);
    });
  });
}
