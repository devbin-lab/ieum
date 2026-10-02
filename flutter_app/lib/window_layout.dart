import 'dart:math';
import 'dart:ui';

const minimumWindowSize = Size(480, 420);

/// Screen APIs report logical pixels, so this also covers Windows display scaling.
Size initialWindowSize(Size workArea) => Size(
  min(1480, max(1, workArea.width - 32)),
  min(980, max(1, workArea.height - 32)),
);
