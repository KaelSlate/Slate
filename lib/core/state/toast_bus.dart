import 'package:flutter/widgets.dart';

/// UI-agnostic toast bus: core publishes calm one-liners, the SlateToastLayer
/// widget (ui/widgets/slate_toast.dart) renders them. No Material SnackBar.
class ToastMessage {
  final String text;
  final String? detail;
  final IconData? icon;
  final VoidCallback? onTap;
  ToastMessage(this.text, {this.detail, this.icon, this.onTap});
}

class SlateToasts {
  SlateToasts._();
  static final SlateToasts instance = SlateToasts._();

  /// New instance per show() so an identical message still retriggers.
  final ValueNotifier<ToastMessage?> current = ValueNotifier(null);

  void show(String text,
      {String? detail, IconData? icon, VoidCallback? onTap}) {
    current.value =
        ToastMessage(text, detail: detail, icon: icon, onTap: onTap);
  }
}
