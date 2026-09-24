# Global Quick Capture — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (inline — the user works without coder-subagents). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Системный хоткей Ctrl+Alt+Space вызывает пилюлю захвата поверх любого приложения; Enter кладёт задачу в Rust-движок по эталонной таблице «дата×время»; окно приложения возвращается в прежнее состояние, фокус — в браузер.

**Architecture:** Морф единственного главного окна (hide → resize/transparent/on-top → show as pill → restore). Rust-парсер получает извлечение дат (новые поля в CParseResult ABI); резолв даты в конкретный день — чистая Dart-функция. Пилюля — существующий SmartDayInputWidget в «floating»-варианте без BackdropFilter.

**Tech Stack:** Flutter/win32 (window_manager 0.5.1, + hotkey_manager, + flutter_acrylic, + screen_retriever), Rust cdylib (`native/`), FFI `#[repr(C)]`.

## Global Constraints

- Проект НЕ git-репозиторий — шаги «commit» отсутствуют, вместо них проверки.
- После любого изменения Rust: `cargo build --release` в `native/` и копия `native/target/release/slate_core.dll` → корень проекта. Иначе Access Violation.
- Zero `.unwrap()` в Rust. Никакого JSON через FFI.
- Запуск только `flutter run --profile -d windows`.
- Курсор: только `basic`, у текстовых полей `text`.
- `Transform.scale` над живым текстом: `filterQuality` не-null во время анимации, null в покое.
- Комментарии в коде — лаконично и мало.
- UI-копирайтинг — английский (как «Type a task...»).

---

### Task 1: Rust — извлечение дат в nlp_parser + ABI

**Files:**
- Modify: `native/src/nlp_parser.rs`

**Interfaces:**
- Produces: `CParseResult` дополнен полями `date_kind: u8` (0 none / 1 offset / 2 weekday / 3 explicit), `date_a: i64`, `date_b: i64`, `date_c: i64` (offset дней | weekday 1–7 пн=1 | год(0=не указан), месяц, день). `ParsedInput.date: Option<DateToken>`.

Порядок пайплайна: priority → tags → **time** → **date** → cleanup. Время раньше даты, но `try_parse_hhmm_at` с разделителем `.` уступает дате по правилу: `XX.YY` где YY∈01..12 и XX∈01..31 → это дата, не время (`12.30`=время, `15.07`=дата, `14.00`=время). Двоеточие — всегда время.

- [ ] **Step 1: тесты (падают)** — добавить в `mod tests`:

```rust
#[test]
fn test_date_tomorrow_ru() {
    let r = parse_input("сдать отчёт завтра в 9");
    assert_eq!(r.date, Some(DateToken::Offset(1)));
    assert_eq!(r.start_time, Some(540));
    assert_eq!(r.clean_title, "сдать отчёт");
}
#[test]
fn test_date_aftertomorrow_and_today() {
    assert_eq!(parse_input("post послезавтра").date, Some(DateToken::Offset(2)));
    assert_eq!(parse_input("call today").date, Some(DateToken::Offset(0)));
    assert_eq!(parse_input("call tomorrow").date, Some(DateToken::Offset(1)));
}
#[test]
fn test_date_weekday_ru_full_and_short() {
    let r = parse_input("созвон в пятницу 15:00");
    assert_eq!(r.date, Some(DateToken::Weekday(5)));
    assert_eq!(r.start_time, Some(900));
    assert_eq!(r.clean_title, "созвон");
    assert_eq!(parse_input("зал пн").date, Some(DateToken::Weekday(1)));
    assert_eq!(parse_input("во вторник врач").date, Some(DateToken::Weekday(2)));
    assert_eq!(parse_input("в среду").date, Some(DateToken::Weekday(3)));
}
#[test]
fn test_date_weekday_en() {
    assert_eq!(parse_input("gym friday").date, Some(DateToken::Weekday(5)));
    assert_eq!(parse_input("gym fri").date, Some(DateToken::Weekday(5)));
    // «sat»/«sun» коротко — не парсим (слова), полные — да
    assert_eq!(parse_input("we sat down").date, None);
    assert_eq!(parse_input("brunch saturday").date, Some(DateToken::Weekday(6)));
}
#[test]
fn test_date_numeric_dotted() {
    assert_eq!(parse_input("рейс 15.07").date, Some(DateToken::Explicit(0, 7, 15)));
    assert_eq!(parse_input("рейс 15.07.2026").date, Some(DateToken::Explicit(2026, 7, 15)));
    // минуты >12 → это время, дата не найдена
    let r = parse_input("Lunch 12.30");
    assert_eq!(r.date, None);
    assert_eq!(r.start_time, Some(750));
    // день >23 не может быть часом → дата
    assert_eq!(parse_input("отпуск 25.07").date, Some(DateToken::Explicit(0, 7, 25)));
}
#[test]
fn test_date_month_name() {
    assert_eq!(parse_input("день рождения 15 июля").date, Some(DateToken::Explicit(0, 7, 15)));
    assert_eq!(parse_input("release jul 15").date, Some(DateToken::Explicit(0, 7, 15)));
    assert_eq!(parse_input("release 15 jul").date, Some(DateToken::Explicit(0, 7, 15)));
}
#[test]
fn test_date_word_boundaries() {
    assert_eq!(parse_input("завтрак с командой").date, None); // «завтрак» ≠ «завтра»
    assert_eq!(parse_input("отправить письмо").date, None);   // «пт» внутри слова
}
#[test]
fn test_date_combined_full() {
    let r = parse_input("в пятницу 15:00 демо !! #работа");
    assert_eq!(r.date, Some(DateToken::Weekday(5)));
    assert_eq!(r.start_time, Some(900));
    assert_eq!(r.priority, 2);
    assert_eq!(r.tags, vec!["работа"]);
    assert_eq!(r.clean_title, "демо");
}
```

- [ ] **Step 2:** `cargo test` в `native/` → новые тесты FAIL (нет `DateToken`).

- [ ] **Step 3: реализация.**

```rust
#[derive(Debug, PartialEq, Clone, Copy)]
enum DateToken {
    Offset(i64),            // дней от сегодня: 0,1,2
    Weekday(i64),           // 1=пн .. 7=вс, ближайшее вхождение (вкл. сегодня)
    Explicit(i64, i64, i64) // (год|0, месяц, день)
}
```

`extract_date(text: &mut String) -> Option<DateToken>` — под-паттерны по специфичности:
1. `DD.MM.YYYY` / `DD.MM` / `DD.M` (правило месяца выше; границы слов с двух сторон).
2. `<число> <месяц-имя>` и `<месяц-имя> <число>` — RU родительный (января..декабря) + EN full/3-letter.
3. Слова: сегодня/today(0), завтра/tomorrow(1), послезавтра(2) — только как отдельные слова (проверка границ: до и после — пробел/край; «завтрак» не матчится).
4. Дни недели: RU full (понедельник, вторник, среда/среду, четверг, пятница/пятницу, суббота/субботу, воскресенье) + short (пн вт ср чт пт сб вс), EN full + short (mon tue wed thu fri; sat/sun только полные), с опциональным предлогом `в `/`во `/`on ` (предлог удаляется вместе с токеном).

Изменение времени-парсера: в `try_parse_hhmm_at`, если разделитель `.` и `mm ∈ 1..=12` и `hh ∈ 1..=31` → `None`.

В `parse_input`: `let (start_time, end_time) = extract_time(&mut text); let date = extract_date(&mut text);` + поле `date` в `ParsedInput`.

C-ABI: в `CParseResult` после `tag_count` добавить `pub date_kind: u8, pub date_a: i64, pub date_b: i64, pub date_c: i64`; заполнять в `ffi_parse_input` (None → kind 0, все -1); в null-ветке тоже. `ffi_free_parse_result` не меняется (нет новых аллокаций).

- [ ] **Step 4:** `cargo test` → все PASS (старые тоже: `test_dot_time` остаётся временем).
- [ ] **Step 5:** `cargo build --release`; copy `native/target/release/slate_core.dll` → `slate_core.dll`.

---

### Task 2: Dart — мост FFI + резолвер назначения

**Files:**
- Modify: `lib/core/engine/slate_core_bridge.dart`
- Create: `lib/core/engine/capture_destination.dart`
- Test: `test/capture_destination_test.dart`

**Interfaces:**
- Consumes: ABI Task 1.
- Produces: `ParseResult{dateKind, dateA, dateB, dateC, bool hasDate}`; `CaptureDestination resolveCapture(ParseResult r, DateTime now, {DateTime? viewedDay})`, `class CaptureDestination { bool toInbox; DateTime? day; int? startTime; int? endTime; String label; }`.

- [ ] **Step 1:** зеркало ABI: в `CParseResult` (Dart) после `tag_count`: `@Uint8() external int date_kind; @Int64() external int date_a; @Int64() external int date_b; @Int64() external int date_c;`. `ParseResult` + поля/`hasDate`, прокинуть в `parseInput()`. В `SmartInputController._tokenTint` условие подсветки временной фразы `_result.hasTime` → `(_result.hasTime || _result.hasDate)`.

- [ ] **Step 2: тесты резолвера (падают)** — `test/capture_destination_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slate/core/engine/capture_destination.dart';
import 'package:slate/core/engine/slate_core_bridge.dart';

void main() {
  final now = DateTime(2026, 7, 3, 18, 0); // пятница, 18:00
  test('no date, no time -> inbox', () {
    final d = resolveCapture(const ParseResult(cleanTitle: 'x'), now);
    expect(d.toInbox, true);
    expect(d.label, 'Inbox');
  });
  test('time in future -> today', () {
    final d = resolveCapture(const ParseResult(cleanTitle: 'x', startTime: 19 * 60), now);
    expect(d.toInbox, false);
    expect(d.day, DateTime(2026, 7, 3));
    expect(d.startTime, 19 * 60);
    expect(d.label, 'Today 19:00');
  });
  test('time passed -> rolls to tomorrow', () {
    final d = resolveCapture(const ParseResult(cleanTitle: 'x', startTime: 9 * 60), now);
    expect(d.day, DateTime(2026, 7, 4));
    expect(d.label, 'Tomorrow 09:00');
  });
  test('viewedDay: no roll, no inbox', () {
    final v = DateTime(2026, 7, 3);
    final d = resolveCapture(const ParseResult(cleanTitle: 'x', startTime: 9 * 60), now, viewedDay: v);
    expect(d.day, v);
    final d2 = resolveCapture(const ParseResult(cleanTitle: 'x'), now, viewedDay: v);
    expect(d2.toInbox, false);
    expect(d2.day, v);
  });
  test('offset date without time -> that day unallocated', () {
    final d = resolveCapture(const ParseResult(cleanTitle: 'x', dateKind: 1, dateA: 1), now);
    expect(d.day, DateTime(2026, 7, 4));
    expect(d.startTime, null);
    expect(d.label, 'Tomorrow');
  });
  test('weekday resolves to nearest, today included', () {
    final d = resolveCapture(const ParseResult(cleanTitle: 'x', dateKind: 2, dateA: 5), now);
    expect(d.day, DateTime(2026, 7, 3)); // сегодня пятница
    final d2 = resolveCapture(const ParseResult(cleanTitle: 'x', dateKind: 2, dateA: 1), now);
    expect(d2.day, DateTime(2026, 7, 6));
    expect(d2.label, 'Mon · Jul 6');
  });
  test('explicit date, year inferred forward', () {
    final d = resolveCapture(const ParseResult(cleanTitle: 'x', dateKind: 3, dateB: 7, dateC: 15), now);
    expect(d.day, DateTime(2026, 7, 15));
    final past = resolveCapture(const ParseResult(cleanTitle: 'x', dateKind: 3, dateB: 1, dateC: 10), now);
    expect(past.day, DateTime(2027, 1, 10)); // январь уже прошёл -> следующий год
  });
  test('date + time -> both', () {
    final d = resolveCapture(
        const ParseResult(cleanTitle: 'x', dateKind: 2, dateA: 1, startTime: 600, endTime: 660), now);
    expect(d.day, DateTime(2026, 7, 6));
    expect(d.startTime, 600);
    expect(d.label, 'Mon · Jul 6 10:00');
  });
}
```

(`ParseResult` получает `dateKind/dateA/dateB/dateC` как const-параметры с дефолтами 0/-1/-1/-1.)

- [ ] **Step 3:** `flutter test` → FAIL (нет файла).
- [ ] **Step 4: реализация** `lib/core/engine/capture_destination.dart`:

```dart
import 'slate_core_bridge.dart';

class CaptureDestination {
  final bool toInbox;
  final DateTime? day; // local midnight
  final int? startTime;
  final int? endTime;
  final String label;
  const CaptureDestination({required this.toInbox, this.day, this.startTime, this.endTime, required this.label});
}

const _months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
const _wds = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];

CaptureDestination resolveCapture(ParseResult r, DateTime now, {DateTime? viewedDay}) {
  final today = DateTime(now.year, now.month, now.day);
  DateTime? day;
  switch (r.dateKind) {
    case 1: day = today.add(Duration(days: r.dateA)); break;
    case 2: day = today.add(Duration(days: (r.dateA - now.weekday) % 7)); break;
    case 3:
      final y = r.dateB > 0 && r.dateC > 0 ? (r.dateA > 0 ? r.dateA : now.year) : null;
      if (y != null) {
        var d = DateTime(y, r.dateB, r.dateC);
        if (r.dateA <= 0 && d.isBefore(today)) d = DateTime(y + 1, r.dateB, r.dateC);
        day = d;
      }
      break;
  }
  if (day == null && viewedDay != null) day = DateTime(viewedDay.year, viewedDay.month, viewedDay.day);
  if (day == null) {
    if (!r.hasTime) return const CaptureDestination(toInbox: true, label: 'Inbox');
    day = today;
    // время уже прошло -> завтра (только в глобальном захвате: viewedDay == null)
    if (r.startTime! <= now.hour * 60 + now.minute) day = today.add(const Duration(days: 1));
  }
  return CaptureDestination(
    toInbox: false,
    day: day,
    startTime: r.startTime,
    endTime: r.endTime,
    label: _label(day, today, r),
  );
}

String _label(DateTime day, DateTime today, ParseResult r) {
  final String d;
  if (day == today) {
    d = 'Today';
  } else if (day == today.add(const Duration(days: 1))) {
    d = 'Tomorrow';
  } else {
    d = '${_wds[day.weekday - 1]} · ${_months[day.month - 1]} ${day.day}';
  }
  return r.hasTime ? '$d ${r.startTimeFormatted}' : d;
}
```

Крайний случай `(r.dateA - now.weekday) % 7`: Dart `%` всегда ≥0 — ок.

- [ ] **Step 5:** `flutter test` → PASS. `flutter analyze` чисто.

---

### Task 3: внутренняя пилюля уважает дату + лейбл назначения в виджете

**Files:**
- Modify: `lib/ui/widgets/smart_day_input.dart`, `lib/ui/views/day_flow_view.dart:403-420`, `lib/core/state/task_state.dart`

**Interfaces:**
- Produces: `SmartDayInputWidget({bool floating = false, String Function(ParseResult)? destinationLabel, ...})`; `TaskState.createCaptured(String cleanTitle, ParseResult result, CaptureDestination dest)`.

- [ ] **Step 1:** `TaskState.createCaptured` — единая точка: `dest.toInbox ? createInboxTask(cleanTitle) : createSmartTask(cleanTitle: ..., dayTs: dest.day!.millisecondsSinceEpoch, result: result копией с dest.startTime/endTime)`. Проще: инлайн — в `createCaptured` вызвать `core.createInboxTask`/`core.createTaskEx` напрямую по образцу существующих методов (insert + invalidate + tick + notify).
- [ ] **Step 2:** `day_flow_view.dart` onSubmit: `final dest = resolveCapture(result, DateTime.now(), viewedDay: _ribbonDate.value); widget.taskState?.createCaptured(cleanTitle, result, dest);`
- [ ] **Step 3:** в `SmartDayInputWidget` добавить `destinationLabel`; в строке инпута: `Row(children: [Expanded(TextField...), AnimatedSwitcher(200ms, child: Text(label, key: ValueKey(label)))])`. Лейбл виден: floating — всегда (кроме пустого текста), в-app — только когда `_lastResult.hasDate`. Стиль: `AppFonts.inter(fontSize: 12, w500, Colors.white.withOpacity(0.38), letterSpacing: -0.1)`.
- [ ] **Step 4:** `flutter analyze`; запуск, ручная проверка: `C` → «завтра в 9 зал» → лейбл «Tomorrow 09:00», Enter → задача на завтрашнем дне в 9:00; «зал» без даты → как раньше, текущий день.

---

### Task 4: floating-вариант пилюли + overlay-сцена

**Files:**
- Modify: `lib/ui/widgets/smart_day_input.dart`
- Create: `lib/ui/overlays/quick_capture_overlay.dart`

**Interfaces:**
- Consumes: `resolveCapture`, `TaskState.createCaptured`.
- Produces: `QuickCaptureOverlay({required VoidCallback onFinished})` — сам играет вход; выход играет и зовёт `onFinished` (контроллер прячет окно).

- [ ] **Step 1:** `SmartDayInputWidget(floating: true)`: вместо `BackdropFilter` — `DecoratedBox(color: AppTheme.background.withOpacity(0.93))` под тем же `LiquidGlassPainter`; внутренний `_appearController` сразу `value = 1.0` (входом управляет сцена); остальное (подсветка, каретка, submit-пульс) без изменений.
- [ ] **Step 2:** сцена `QuickCaptureOverlay`:

```
Material(transparent)
 └─ Stack
     ├─ Positioned.fill(GestureDetector(onTap: _dismiss))   // клик мимо
     └─ Positioned(bottom: 28, center, width: 600,
         AnimatedBuilder(_enter,
           Transform.translate(0, (1-t)*10,
             Transform(alignment: center,
               scaleX: 0.55+0.45*t, scaleY: 0.90+0.10*t,
               filterQuality: _enter.isAnimating ? FilterQuality.low : null,
               Opacity(min(1, t/0.35),
                 SmartDayInputWidget(floating: true, destinationLabel: ..., onSubmit: ..., onDismiss: _dismiss))))))
```

Вход: `SpringSimulation(stiffness 420, damping ratio 0.86)` 0→1. Выход: `animateBack(0.96->fade, 150ms, easeIn)` затем `onFinished()`. Esc уже глобально ведёт в `onDismiss`. Submit: `resolveCapture(result, DateTime.now())` (без viewedDay) → `createCaptured` → лёгкий пульс (уже в виджете) → `_dismiss(submitted: true)` через ~140 мс, чтобы пульс был виден.

- [ ] **Step 3:** `flutter analyze` чисто. (Вживую проверяется в Task 5.)

---

### Task 5: контроллер морфа окна + хоткей + wiring

**Files:**
- Create: `lib/core/engine/quick_capture_controller.dart`
- Modify: `lib/main.dart`, `pubspec.yaml`

**Interfaces:**
- Produces: `QuickCaptureController.instance` — `ValueNotifier<bool> overlayMode`, `Future<void> summon()`, `Future<void> finishAndRestore()`; регистрация хоткея `registerHotkey()`.

- [ ] **Step 1:** pubspec: `hotkey_manager: ^0.2.3`, `flutter_acrylic: ^1.1.4`, `screen_retriever: ^0.2.0`; `flutter pub get`.
- [ ] **Step 2:** контроллер — state machine:

```dart
class _PriorState { late Rect bounds; late bool minimized; late bool visible; late bool focused; }

summon():
  if (overlayMode.value) { requestDismiss(); return; }  // toggle
  if (_busy) return; _busy = true;
  prior = {getBounds, isMinimized, isVisible, isFocused};
  await windowManager.hide();
  await Window.setEffect(effect: WindowEffect.transparent);
  await windowManager.setBackgroundColor(Colors.transparent);
  await windowManager.setAlwaysOnTop(true);
  await windowManager.setSkipTaskbar(true);
  final target = await _pillRect(); // монитор с курсором: screenRetriever.getCursorScreenPoint + getAllDisplays
  await windowManager.setBounds(target);
  overlayMode.value = true;                    // root swap
  await WidgetsBinding.instance.endOfFrame;    // кадр отрисован в новом размере
  await windowManager.show();
  await windowManager.focus();
  _busy = false;

finishAndRestore():   // зовёт overlay после exit-анимации
  await windowManager.hide();                  // фокус сам вернётся в браузер
  overlayMode.value = false;
  await Window.setEffect(effect: WindowEffect.disabled, color: AppTheme.background);
  await windowManager.setBackgroundColor(AppTheme.background);
  await windowManager.setAlwaysOnTop(false);
  await windowManager.setSkipTaskbar(false);
  await windowManager.setBounds(prior.bounds);
  if (prior.minimized) { await windowManager.minimize(); }
  else if (prior.visible) {
    if (prior.focused) { await windowManager.show(); await windowManager.focus(); }
    else { await windowManager.show(inactive: true); }
  }
```

`_pillRect()`: дисплей, содержащий курсор (fallback primary): `x = vis.x + (vis.w - 720)/2; y = vis.y + vis.h - 190 - 24; size 720×190`. `onWindowBlur` (WindowListener) при overlayMode → requestDismiss(). `requestDismiss()` — прокидывается в overlay (ValueNotifier<int> dismissTick), чтобы выход всегда шёл с анимацией из одной точки.
- [ ] **Step 3:** `main.dart`: `await Window.initialize()` после `windowManager.ensureInitialized()`; после показа окна `await hotKeyManager.unregisterAll(); await hotKeyManager.register(HotKey(key: PhysicalKeyboardKey.space, modifiers: [HotKeyModifier.control, HotKeyModifier.alt], scope: HotKeyScope.system), keyDownHandler: (_) => QuickCaptureController.instance.summon());` — при отказе (exception/false) fallback `KeyS`, лог. Root: `home: ValueListenableBuilder(overlayMode, ... ? QuickCaptureOverlay(...) : MainScreen())`.
- [ ] **Step 4:** предохранители: повторный hotkey во время анимаций (_busy), warmup-слой не должен повторно прогреваться при возврате MainScreen — если прогрев гейтится флагом `StaircaseState.isWarmingUp`/статикой, проверить и при необходимости добавить `static bool _warmedOnce`.
- [ ] **Step 5:** `flutter analyze` чисто.

---

### Task 6: живая верификация

- [ ] `cargo test` (native) и `flutter test` — всё PASS.
- [ ] `flutter run --profile -d windows`; свернуть окно; Ctrl+Alt+Space из другого окна:
  - пилюля внизу-центр, вход «из середины», < ~100 мс;
  - скриншот PrintWindow PW_RENDERFULLCONTENT (окно живёт недолго — не перезапускать зря);
  - «завтра в 9 отчёт !!» → лейбл «Tomorrow 09:00» → Enter → окно исчезло, приложение осталось свернутым;
  - развернуть приложение → задача на завтра, 9:00, приоритет 2;
  - «мысль» без даты/времени → Inbox;
  - Esc и клик-мимо → исчезновение без создания;
  - хоткей при открытом приложении → морф и возврат фокусированным;
  - повторный хоткей при открытой пилюле → закрытие.
- [ ] Обновить `the_key_points_for_you`? НЕТ — файл юзера, не трогаем. Память Claude — обновить.
