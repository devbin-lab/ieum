import 'package:flutter/material.dart';

import 'models.dart';

/// The board, calendar, agenda and timeline share one status palette.
String workStatusKey(WorkTask task, ProjectManifest? project) {
  if (const {
    'todo',
    'doing',
    'review',
    'done',
    'hold',
    'drop',
  }.contains(task.status)) {
    return task.status;
  }
  if (task.status == 'rework') return 'todo';
  final category = workflowBoardCategory(task, project);
  return category == 'inProgress' ? 'doing' : category;
}

const _customStatusColors = [
  Color(0xff58798a),
  Color(0xff8a6e9d),
  Color(0xff9a713d),
  Color(0xff4e8078),
];
const _customStatusSurfaces = [
  Color(0xffedf3f5),
  Color(0xfff3eff7),
  Color(0xfff8f1e8),
  Color(0xffedf5f3),
];
int _stagePaletteIndex(String id) =>
    id.codeUnits.fold<int>(0, (sum, value) => sum + value) %
    _customStatusColors.length;
Color statusColor(String id, {Brightness brightness = Brightness.light}) {
  if (brightness == Brightness.dark) {
    return {
          'todo': const Color(0xffacb2c0),
          'doing': const Color(0xff7cafff),
          'review': const Color(0xfff2ae68),
          'rework': const Color(0xffe591a4),
          'done': const Color(0xff82c69b),
          'hold': const Color(0xffb4a3ef),
          'drop': const Color(0xffd0d5dd),
        }[id] ??
        Color.lerp(
          _customStatusColors[_stagePaletteIndex(id)],
          Colors.white,
          .4,
        )!;
  }
  return {
        'todo': const Color(0xff6e687b),
        'doing': const Color(0xff2f6fda),
        'review': const Color(0xffd47a1f),
        'rework': const Color(0xffa0445a),
        'done': const Color(0xff417458),
        'hold': const Color(0xff7963d5),
        'drop': const Color(0xff202124),
      }[id] ??
      _customStatusColors[_stagePaletteIndex(id)];
}

Color stageSurfaceColor(String id, {Brightness brightness = Brightness.light}) {
  if (brightness == Brightness.dark) {
    return {
          'todo': const Color(0xff2a2e37),
          'doing': const Color(0xff24354f),
          'review': const Color(0xff443125),
          'rework': const Color(0xff442932),
          'done': const Color(0xff263b30),
          'hold': const Color(0xff352d49),
          'drop': const Color(0xff353a43),
        }[id] ??
        Color.lerp(
          const Color(0xff242730),
          _customStatusColors[_stagePaletteIndex(id)],
          .23,
        )!;
  }
  return {
        'todo': const Color(0xfff1f3f5),
        'doing': const Color(0xffedf4ff),
        'review': const Color(0xfffff1e5),
        'rework': const Color(0xfffff0f2),
        'done': const Color(0xffedf6ef),
        'hold': const Color(0xfff2edff),
        'drop': const Color(0xffdde1e6),
      }[id] ??
      _customStatusSurfaces[_stagePaletteIndex(id)];
}
