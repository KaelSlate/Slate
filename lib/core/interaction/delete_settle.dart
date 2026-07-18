import 'package:flutter/foundation.dart';

/// After a delete, the rows below glide up for ~260ms (the collapse). A click
/// meant for the old spot lands on a MOVING card and would toggle-strike it —
/// the spam-delete misclick. Toggle taps are ignored while cards settle;
/// delete-icon taps stay live so rapid sweeping keeps working.
class DeleteSettle {
  DeleteSettle._();

  static DateTime? _lastDeleteAt;
  static const _window = Duration(milliseconds: 320);

  /// Ids whose card is playing its collapse but whose data hasn't dropped yet.
  ///
  /// A card animates for 260ms BEFORE calling onDelete, so for those 260ms the
  /// list still counts it: the cap stays full, «+N more» keeps drawing, and it
  /// slides up into the slot the collapsing row is vacating. Then the data drops
  /// and the label is cut out while the promoted card pops in — label, then
  /// card, same slot. Publishing the id at the START of the gesture lets lists
  /// treat the row as already gone for CAPACITY while still rendering its
  /// collapse, so the next card is promoted and glides up during that same
  /// motion.
  static final ValueNotifier<Set<String>> deleting =
      ValueNotifier<Set<String>>(const {});

  static void markDeleting(String id) =>
      deleting.value = {...deleting.value, id};

  static void unmarkDeleting(String id) {
    if (!deleting.value.contains(id)) return;
    deleting.value = <String>{...deleting.value}..remove(id);
  }

  static void stamp() => _lastDeleteAt = DateTime.now();

  static bool get settling =>
      _lastDeleteAt != null &&
      DateTime.now().difference(_lastDeleteAt!) < _window;
}
