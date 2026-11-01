// lib/features/auth/widgets/otp_code_field.dart
//
// The 6-digit code as boxes backed by ONE text field. Six separate
// one-character fields could not take a pasted code, a keyboard SMS
// suggestion (AutofillHints.oneTimeCode) or backspace across boxes.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/theme/cts_theme.dart';

class OtpCodeField extends StatefulWidget {
  const OtpCodeField({
    super.key,
    required this.controller,
    required this.onCompleted,
    this.focusNode,
    this.length = 6,
    this.enabled = true,
    this.hasError = false,
    this.autofocus = true,
  });

  final TextEditingController controller;

  /// Called once each time the code reaches [length] digits.
  final ValueChanged<String> onCompleted;
  final FocusNode? focusNode;
  final int length;
  final bool enabled;
  final bool hasError;
  final bool autofocus;

  @override
  State<OtpCodeField> createState() => _OtpCodeFieldState();
}

class _OtpCodeFieldState extends State<OtpCodeField> {
  late final FocusNode _focus = widget.focusNode ?? FocusNode();
  String? _completed;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
    _focus.addListener(_onFocus);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    _focus.removeListener(_onFocus);
    if (widget.focusNode == null) _focus.dispose();
    super.dispose();
  }

  void _onFocus() => setState(() {});

  void _onChanged() {
    setState(() {});
    final code = widget.controller.text;
    if (code.length < widget.length) {
      _completed = null;
    } else if (code != _completed) {
      _completed = code;
      widget.onCompleted(code);
    }
  }

  @override
  Widget build(BuildContext context) {
    final code = widget.controller.text;
    final active = _focus.hasFocus && widget.enabled
        ? code.length.clamp(0, widget.length - 1)
        : -1;

    return Semantics(
      label: 'Verification code, ${widget.length} digits',
      child: Stack(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              widget.length,
              (i) => Flexible(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 52),
                    child: _Box(
                      digit: i < code.length ? code[i] : '',
                      active: i == active,
                      hasError: widget.hasError,
                      enabled: widget.enabled,
                    ),
                  ),
                ),
              ),
            ),
          ),
          // The real input, invisible, over the boxes: taps focus it and a
          // long press offers Paste.
          Positioned.fill(
            child: TextField(
              controller: widget.controller,
              focusNode: _focus,
              enabled: widget.enabled,
              autofocus: widget.autofocus,
              autofillHints: const [AutofillHints.oneTimeCode],
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              inputFormatters: [
                // Pasting "Your code is 123456" keeps the digits only.
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(widget.length),
              ],
              showCursor: false,
              enableSuggestions: false,
              autocorrect: false,
              style: const TextStyle(color: Colors.transparent, fontSize: 1),
              cursorColor: Colors.transparent,
              decoration: const InputDecoration(
                border: InputBorder.none,
                counterText: '',
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Box extends StatelessWidget {
  const _Box({
    required this.digit,
    required this.active,
    required this.hasError,
    required this.enabled,
  });

  final String digit;
  final bool active;
  final bool hasError;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final Color border;
    final double width;
    if (hasError) {
      border = AppColors.error;
      width = 1.5;
    } else if (active) {
      border = CtsTheme.primary;
      width = 2;
    } else {
      border = enabled ? CtsTheme.border : CtsTheme.borderLight;
      width = 1.2;
    }
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      height: 60,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: CtsTheme.surface,
        borderRadius: BorderRadius.circular(CtsTheme.radiusMd),
        border: Border.all(color: border, width: width),
      ),
      child: Text(
        digit,
        style: CtsText.title2.copyWith(
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
