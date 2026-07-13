/// After a delete, the rows below glide up for ~260ms (the collapse). A click
/// meant for the old spot lands on a MOVING card and would toggle-strike it —
/// the spam-delete misclick. Toggle taps are ignored while cards settle;
/// delete-icon taps stay live so rapid sweeping keeps working.
class DeleteSettle {
  DeleteSettle._();

  static DateTime? _lastDeleteAt;
  static const _window = Duration(milliseconds: 320);

  static void stamp() => _lastDeleteAt = DateTime.now();

  static bool get settling =>
      _lastDeleteAt != null &&
      DateTime.now().difference(_lastDeleteAt!) < _window;
}
