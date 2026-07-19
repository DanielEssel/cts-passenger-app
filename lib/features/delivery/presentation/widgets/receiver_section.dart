// lib/features/delivery/presentation/widgets/receiver_section.dart
//
// Receiver contact inputs (phone + name) with inline validation.
// Stateless: the parent screen owns the controllers, the error strings,
// and the setState calls. This widget only renders and reports changes.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/constants/app_colors.dart';

class ReceiverSection extends StatelessWidget {
  final TextEditingController phoneController;
  final TextEditingController nameController;
  final String? phoneError;
  final String? nameError;
  final ValueChanged<String> onPhoneChanged;
  final ValueChanged<String> onNameChanged;

  const ReceiverSection({
    super.key,
    required this.phoneController,
    required this.nameController,
    required this.phoneError,
    required this.nameError,
    required this.onPhoneChanged,
    required this.onNameChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _DeliveryInputField(
          controller: phoneController,
          hint: '024XXXXXXX — Receiver phone number',
          icon: Icons.phone_rounded,
          keyboardType: TextInputType.phone,
          maxLength: 13, // room for a +233 paste before normalization
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[\d+]')),
          ],
          errorText: phoneError,
          onChanged: onPhoneChanged,
        ),
        const SizedBox(height: 10),
        _DeliveryInputField(
          controller: nameController,
          hint: "Receiver's name (optional)",
          icon: Icons.person_rounded,
          maxLength: 50,
          errorText: nameError,
          onChanged: onNameChanged,
        ),
      ],
    );
  }
}

/// Shared input with inline error support. Kept private to this file so the
/// receiver section is self-contained; the screen keeps its own `_inputField`
/// for the note field so nothing else changes.
class _DeliveryInputField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final TextInputType? keyboardType;
  final int? maxLength;
  final List<TextInputFormatter>? inputFormatters;
  final String? errorText;
  final ValueChanged<String>? onChanged;

  const _DeliveryInputField({
    required this.controller,
    required this.hint,
    required this.icon,
    this.keyboardType,
    this.maxLength,
    this.inputFormatters,
    this.errorText,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(
            color: AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: errorText != null ? AppColors.error : AppColors.border,
              width: errorText != null ? 1.2 : 1,
            ),
          ),
          child: TextField(
            controller: controller,
            keyboardType: keyboardType,
            maxLength: maxLength,
            inputFormatters: inputFormatters,
            onChanged: onChanged,
            style: const TextStyle(
                fontSize: 13, color: AppColors.textPrimary),
            decoration: InputDecoration(
              hintText: hint,
              counterText: '', // hide the default maxLength counter
              hintStyle: const TextStyle(
                fontSize: 13,
                color: AppColors.textTertiary,
                fontStyle: FontStyle.italic,
              ),
              prefixIcon:
                  Icon(icon, color: AppColors.textSecondary, size: 18),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 12),
            ),
          ),
        ),
        if (errorText != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 4),
            child: Text(
              errorText!,
              style: const TextStyle(fontSize: 11, color: AppColors.error),
            ),
          ),
      ],
    );
  }
}