import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../core/theme/app_theme.dart';
import '../widgets/graphite_stroke.dart';
import '../widgets/paper_grain.dart';

/// TEMPORARY — Warm Foundation Preview.
///
/// Not part of the product. Shows the v2.1 warm palette, the Fraunces welcome
/// face, the living graphite stroke (draw-on + breathe + check), and the paper
/// grain — so the foundation can be judged in real pixels before it's wired in.
/// Delete this file (and the kPreviewMode branch in main.dart) when done.
class PreviewFirstRun extends StatefulWidget {
  const PreviewFirstRun({super.key});

  @override
  State<PreviewFirstRun> createState() => _PreviewFirstRunState();
}

class _PreviewFirstRunState extends State<PreviewFirstRun> {
  int _runId = 0; // bump to replay all draw-ons
  bool _grain = true;

  void _replay() => setState(() => _runId++);

  @override
  Widget build(BuildContext context) {
    final body = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 80, horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── The welcome moment (the real choreography) ────────────────
              KeyedSubtree(
                key: ValueKey('welcome_$_runId'),
                child: _WelcomeMoment(),
              ),

              const SizedBox(height: 90),

              // ── The console invite (breathing honey stroke) ───────────────
              _block(
                label: 'CONSOLE INVITE',
                child: Column(
                  children: [
                    Text(
                      "Just say what's on your mind. I'll find a place for it.",
                      style: AppTheme.bodyLarge.copyWith(
                        color: AppTheme.textSecondary,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 10),
                    GraphiteStroke(
                      key: ValueKey('invite_$_runId'),
                      width: 320,
                      height: 16,
                      seed: 23,
                      delay: const Duration(milliseconds: 400),
                      breathe: true,
                      color: AppTheme.graphiteInk,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 70),

              // ── The confirm moment (stroke curls into a check) ────────────
              _block(
                label: 'CONFIRM',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GraphiteStroke(
                      key: ValueKey('check_$_runId'),
                      width: 34,
                      height: 34,
                      mode: GraphiteStrokeMode.check,
                      strokeWidth: 2.6,
                      color: AppTheme.honey,
                      delay: const Duration(milliseconds: 200),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'There — tucked into Thursday, 2pm.',
                      style: AppTheme.bodyLarge.copyWith(fontSize: 15),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 80),

              // ── Palette: cold (old) vs warm (new) ─────────────────────────
              _block(
                label: 'PALETTE — COLD (old)  →  WARM (new)',
                child: Column(
                  children: [
                    _swatchRow('background', const Color(0xFF131316), AppTheme.background),
                    _swatchRow('surface', const Color(0xFF1A1A1F), AppTheme.surface),
                    _swatchRow('surfaceLight', const Color(0xFF242426), AppTheme.surfaceLight),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _accentChip('honey', AppTheme.honey),
                        _accentChip('honeyDeep', AppTheme.honeyDeep),
                        _accentChip('graphiteInk', AppTheme.graphiteInk),
                        _accentChip('old alarm', AppTheme.ghostOrange),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return Scaffold(
      backgroundColor: AppTheme.background,
      floatingActionButton: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.extended(
            heroTag: 'grain',
            backgroundColor: AppTheme.surfaceLight,
            onPressed: () => setState(() => _grain = !_grain),
            icon: Icon(_grain ? Icons.grain : Icons.grain_outlined,
                color: AppTheme.honey, size: 18),
            label: Text(_grain ? 'Grain ON' : 'Grain OFF',
                style: AppTheme.bodyMedium.copyWith(color: AppTheme.textPrimary)),
          ),
          const SizedBox(width: 12),
          FloatingActionButton.extended(
            heroTag: 'replay',
            backgroundColor: AppTheme.honey,
            onPressed: _replay,
            icon: const Icon(Icons.refresh, color: Color(0xFF15110D), size: 18),
            label: Text('Replay',
                style: AppTheme.bodyMedium.copyWith(
                    color: const Color(0xFF15110D), fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: _grain ? PaperGrain(child: body) : body,
    );
  }

  Widget _block({required String label, required Widget child}) {
    return Column(
      children: [
        Text(label,
            style: AppTheme.labelUppercase.copyWith(color: AppTheme.textMuted)),
        const SizedBox(height: 18),
        child,
      ],
    );
  }

  Widget _swatchRow(String name, Color cold, Color warm) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 120,
            child: Text(name,
                style: AppTheme.bodyMedium.copyWith(color: AppTheme.textTertiary)),
          ),
          _swatch(cold, _hex(cold)),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 10),
            child: Icon(Icons.arrow_forward, size: 14, color: Colors.white24),
          ),
          _swatch(warm, _hex(warm)),
        ],
      ),
    );
  }

  Widget _swatch(Color c, String label) {
    return Column(
      children: [
        Container(
          width: 84,
          height: 40,
          decoration: BoxDecoration(
            color: c,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white.withOpacity(0.12), width: 0.5),
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: AppTheme.mono.copyWith(fontSize: 10)),
      ],
    );
  }

  Widget _accentChip(String name, Color c) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: c,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withOpacity(0.12), width: 0.5),
            ),
          ),
          const SizedBox(height: 6),
          Text(name, style: AppTheme.mono.copyWith(fontSize: 9)),
          Text(_hex(c), style: AppTheme.mono.copyWith(fontSize: 8, color: AppTheme.textMuted)),
        ],
      ),
    );
  }

  String _hex(Color c) =>
      '#${(c.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

// ─────────────────────────────────────────────────────────────────────────────
// The welcome moment, choreographed like the real first run.
// ─────────────────────────────────────────────────────────────────────────────
class _WelcomeMoment extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text('Good afternoon, Kozachok', style: AppTheme.welcomeSerif)
            .animate()
            .fadeIn(duration: 600.ms, curve: Curves.easeOut)
            .slideY(begin: 0.12, duration: 700.ms, curve: Curves.easeOutCubic),
        const SizedBox(height: 10),
        Text(
          "Whenever you're ready — there's no rush.",
          style: AppTheme.welcomeSerifSub,
        )
            .animate()
            .fadeIn(delay: 700.ms, duration: 600.ms, curve: Curves.easeOut),
        const SizedBox(height: 14),
        GraphiteStroke(
          width: 280,
          height: 18,
          seed: 7,
          delay: const Duration(milliseconds: 1200),
          color: AppTheme.graphiteInk,
        ),
      ],
    );
  }
}
