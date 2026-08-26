import 'package:flutter/material.dart';
import 'package:surfeye_app/theme/app_theme.dart';

class HydroButton extends StatelessWidget {
  const HydroButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.small = false,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final bool small;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: small ? 20 : 32,
          vertical: small ? 10 : 14,
        ),
        decoration: BoxDecoration(
          gradient: NatureColors.natureGradient,
          borderRadius: BorderRadius.circular(12),
          boxShadow: NatureColors.natureGlow,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: small ? 16 : 18, color: Colors.white),
              const SizedBox(width: 8),
            ],
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Outfit',
                fontSize: small ? 13 : 15,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
