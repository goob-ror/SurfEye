import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:surfeye_app/theme/app_theme.dart';

class BottomNav extends StatelessWidget {
  const BottomNav({super.key, this.dark = false});

  final bool dark;

  static const _items = [
    _NavItem(icon: Icons.home_rounded, label: 'Beranda', path: '/'),
    _NavItem(icon: Icons.camera_alt_rounded, label: 'Kamera', path: '/camera'),
    _NavItem(icon: Icons.assignment_rounded, label: 'Hasil', path: '/results'),
  ];

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).uri.toString();
    final bg = dark
        ? NatureColors.foreground.withValues(alpha: 0.9)
        : NatureColors.card.withValues(alpha: 0.9);

    return Container(
      decoration: BoxDecoration(
        color: bg,
        border: Border(
          top: BorderSide(
            color: (dark ? Colors.white : NatureColors.border).withValues(alpha: 0.15),
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: _items
                .map((item) => _NavButton(
                      item: item,
                      isActive: location == item.path,
                      dark: dark,
                    ))
                .toList(),
          ),
        ),
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final String label;
  final String path;
  const _NavItem({required this.icon, required this.label, required this.path});
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.item,
    required this.isActive,
    required this.dark,
  });

  final _NavItem item;
  final bool isActive;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final activeColor = NatureColors.accent;
    final inactiveColor =
        dark ? Colors.white.withValues(alpha: 0.5) : NatureColors.mutedForeground;

    return GestureDetector(
      onTap: () => context.go(item.path),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Active indicator bar
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              height: 3,
              width: isActive ? 28 : 0,
              margin: const EdgeInsets.only(bottom: 4),
              decoration: BoxDecoration(
                gradient: isActive ? NatureColors.natureGradient : null,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Icon(
              item.icon,
              size: 22,
              color: isActive ? activeColor : inactiveColor,
            ),
            const SizedBox(height: 2),
            Text(
              item.label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: isActive ? activeColor : inactiveColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
