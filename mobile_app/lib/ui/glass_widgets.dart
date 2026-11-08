import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

class AppColors {
  static const Color bg = Color(0xFF050507);
  static const Color crimson = Color(0xFFFF2D55);
  static const Color crimsonDeep = Color(0xFF9F1239);
  static const Color glassFill = Color.fromRGBO(20, 20, 26, 0.56);
  static const Color glassStrong = Color.fromRGBO(24, 24, 32, 0.78);
  static const Color glassBorder = Color.fromRGBO(255, 255, 255, 0.09);
  static const Color crimsonSoft = Color.fromRGBO(255, 45, 85, 0.16);
  static const Color crimsonBorder = Color.fromRGBO(255, 45, 85, 0.40);
  static const Color textPrimary = Color(0xFFF5F5F7);
  static const Color textSecondary = Color.fromRGBO(235, 235, 245, 0.56);
  static const Color textMuted = Color.fromRGBO(235, 235, 245, 0.34);
}

class AmbientCrimsonBackground extends StatelessWidget {
  final Widget child;

  const AmbientCrimsonBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(
          child: ColoredBox(color: AppColors.bg),
        ),
        Positioned(
          top: -90,
          left: -70,
          child: Container(
            width: 290,
            height: 290,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  Color.fromRGBO(225, 29, 72, 0.24),
                  Color.fromRGBO(225, 29, 72, 0.0),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          bottom: 40,
          right: -80,
          child: Container(
            width: 310,
            height: 310,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  Color.fromRGBO(159, 18, 57, 0.20),
                  Color.fromRGBO(159, 18, 57, 0.0),
                ],
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final Color? borderColor;

  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.borderRadius = 24,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.fromRGBO(32, 30, 40, 0.62),
                AppColors.glassFill,
                Color.fromRGBO(14, 14, 20, 0.66),
              ],
            ),
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(
              color: borderColor ?? const Color.fromRGBO(255, 255, 255, 0.11),
              width: 1,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color.fromRGBO(0, 0, 0, 0.45),
                blurRadius: 28,
                offset: Offset(0, 12),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

class GlassButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool primary;
  final bool active;
  final IconData? icon;
  final EdgeInsetsGeometry padding;

  const GlassButton({
    super.key,
    required this.label,
    required this.onTap,
    this.primary = false,
    this.active = false,
    this.icon,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
  });

  @override
  Widget build(BuildContext context) {
    final BoxDecoration decoration;
    if (primary) {
      decoration = BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.crimson, AppColors.crimsonDeep],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color.fromRGBO(255, 130, 155, 0.45),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color.fromRGBO(255, 45, 85, 0.34),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      );
    } else if (active) {
      decoration = BoxDecoration(
        color: AppColors.crimsonSoft,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.crimsonBorder),
      );
    } else {
      decoration = BoxDecoration(
        color: const Color.fromRGBO(255, 255, 255, 0.045),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.glassBorder),
      );
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        splashColor: AppColors.crimsonSoft,
        highlightColor: AppColors.crimsonSoft,
        child: Container(
          padding: padding,
          decoration: decoration,
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 16,
                  color: active && !primary
                      ? const Color(0xFFFF8FA3)
                      : AppColors.textPrimary,
                ),
                if (label.isNotEmpty) const SizedBox(width: 6),
              ],
              if (label.isNotEmpty)
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: active && !primary
                          ? const Color(0xFFFF8FA3)
                          : AppColors.textPrimary,
                      fontSize: 13,
                      fontWeight:
                          primary || active ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class CrimsonMicOrb extends StatefulWidget {
  final bool isListening;
  final bool isBusy;
  final VoidCallback onTap;

  const CrimsonMicOrb({
    super.key,
    required this.isListening,
    required this.isBusy,
    required this.onTap,
  });

  @override
  State<CrimsonMicOrb> createState() => _CrimsonMicOrbState();
}

class _CrimsonMicOrbState extends State<CrimsonMicOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    if (widget.isListening) {
      _pulseController.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant CrimsonMicOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isListening && !_pulseController.isAnimating) {
      _pulseController.repeat(reverse: true);
    } else if (!widget.isListening && _pulseController.isAnimating) {
      _pulseController.stop();
      _pulseController.value = 0;
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _pulseController,
        builder: (context, _) {
          final scale = widget.isListening
              ? 1.0 + (_pulseController.value * 0.08)
              : 1.0;
          final glowRadius = widget.isListening
              ? 28.0 + (_pulseController.value * 22.0)
              : 24.0;
          return SizedBox(
            width: 118,
            height: 118,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (widget.isListening)
                  Container(
                    width: 102 + (_pulseController.value * 16),
                    height: 102 + (_pulseController.value * 16),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppColors.crimson
                            .withOpacity(0.55 - (_pulseController.value * 0.4)),
                        width: 1.6,
                      ),
                    ),
                  ),
                Transform.scale(
                  scale: scale,
                  child: Container(
                    width: 94,
                    height: 94,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const RadialGradient(
                        center: Alignment(-0.3, -0.35),
                        radius: 0.95,
                        colors: [
                          Color(0xFFFF5C7C),
                          AppColors.crimson,
                          Color(0xFF881337),
                        ],
                      ),
                      border: Border.all(
                        color: const Color.fromRGBO(255, 255, 255, 0.30),
                        width: 1.2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.crimson.withOpacity(
                              widget.isListening ? 0.62 : 0.38),
                          blurRadius: glowRadius,
                          spreadRadius: widget.isListening ? 4 : 0,
                        ),
                      ],
                    ),
                    child: Center(
                      child: widget.isBusy
                          ? const CupertinoActivityIndicator(
                              color: Colors.white,
                              radius: 13,
                            )
                          : Icon(
                              widget.isListening
                                  ? CupertinoIcons.waveform
                                  : CupertinoIcons.mic_fill,
                              color: Colors.white,
                              size: 34,
                            ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class IosLiquidGlassDock extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onChanged;

  const IosLiquidGlassDock({
    super.key,
    required this.currentIndex,
    required this.onChanged,
  });

  static const _items = [
    (CupertinoIcons.mic_fill, 'Qwen AI'),
    (CupertinoIcons.rectangle_dock, 'Тачпад'),
    (CupertinoIcons.play_fill, 'Медиа'),
    (CupertinoIcons.desktopcomputer, 'ПК'),
  ];

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(32),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: Container(
          height: 66,
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: const Color.fromRGBO(16, 16, 22, 0.76),
            borderRadius: BorderRadius.circular(32),
            border: Border.all(
              color: const Color.fromRGBO(255, 255, 255, 0.12),
            ),
            boxShadow: const [
              BoxShadow(
                color: Color.fromRGBO(0, 0, 0, 0.65),
                blurRadius: 30,
                offset: Offset(0, 12),
              ),
            ],
          ),
          child: Row(
            children: List.generate(_items.length, (i) {
              final selected = i == currentIndex;
              final item = _items[i];
              return Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onChanged(i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: selected
                          ? const Color.fromRGBO(255, 45, 85, 0.20)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(27),
                      border: selected
                          ? Border.all(
                              color: const Color.fromRGBO(255, 45, 85, 0.42),
                            )
                          : null,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          item.$1,
                          size: 20,
                          color: selected
                              ? AppColors.crimson
                              : AppColors.textSecondary,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          item.$2,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: selected
                                ? Colors.white
                                : AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class DynamicIslandToast extends StatelessWidget {
  final String? message;

  const DynamicIslandToast({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final visible = message != null && message!.isNotEmpty;
    return IgnorePointer(
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        offset: visible ? Offset.zero : const Offset(0, -1.6),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: visible ? 1.0 : 0.0,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: const Color.fromRGBO(14, 14, 18, 0.88),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: AppColors.crimsonBorder),
                  boxShadow: const [
                    BoxShadow(
                      color: Color.fromRGBO(0, 0, 0, 0.58),
                      blurRadius: 24,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                        color: AppColors.crimson,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        message ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
