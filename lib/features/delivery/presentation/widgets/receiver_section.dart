// lib/features/delivery/presentation/widgets/receiver_section.dart
//
// Receiver contact inputs (phone + name) with inline validation.
// Stateless: the parent screen owns the controllers, the error strings,
// and the setState calls. This widget only renders and reports changes.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/widgets/cts_ui.dart';

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
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CtsTextField(
          controller: phoneController,
          label: 'Receiver phone number',
          hint: 'e.g. 024 123 4567',
          helperText: 'The rider calls this number at drop-off.',
          icon: Icons.phone_rounded,
          keyboardType: TextInputType.phone,
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.telephoneNumber],
          maxLength: 13, // room for a +233 paste before normalization
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[\d+]')),
          ],
          errorText: phoneError,
          onChanged: onPhoneChanged,
        ),
        const SizedBox(height: 14),
        CtsTextField(
          controller: nameController,
          label: 'Receiver name',
          optional: true,
          hint: 'Who is receiving the parcel?',
          icon: Icons.person_rounded,
          textInputAction: TextInputAction.next,
          textCapitalization: TextCapitalization.words,
          autofillHints: const [AutofillHints.name],
          maxLength: 50,
          errorText: nameError,
          onChanged: onNameChanged,
        ),
      ],
    );
  }
}
