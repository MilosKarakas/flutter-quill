// Entry point that only uses the editor API that existed before the image,
// video, and block-style work, so it also builds against an older checkout.
// See ../../README.md, "Comparing against a baseline".
import 'package:flutter/material.dart';

import 'common.dart';

void main() {
  exposeCommon();
  final readOnly = Uri.base.queryParameters['readOnly'] == '1';
  runApp(HarnessApp(config: defaultConfig(readOnly: readOnly)));
}
