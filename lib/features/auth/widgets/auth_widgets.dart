

import 'dart:ui';
import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';

// =============================================================================
// Country model
// =============================================================================

class Country {
  final String name;
  final String code; // ISO 3166-1 alpha-2
  final String dial; // e.g. "+233"
  final String flag; // emoji

  const Country({
    required this.name,
    required this.code,
    required this.dial,
    required this.flag,
  });
}

// =============================================================================
// Africa-first country list
// West Africa first (primary market), then rest of Africa, then diaspora.
// =============================================================================

const List<Country> kAfricaCountries = [
  // West Africa
  Country(name: 'Ghana',           code: 'GH', dial: '+233', flag: '🇬🇭'),
  Country(name: 'Nigeria',         code: 'NG', dial: '+234', flag: '🇳🇬'),
  Country(name: 'Côte d\'Ivoire',  code: 'CI', dial: '+225', flag: '🇨🇮'),
  Country(name: 'Senegal',         code: 'SN', dial: '+221', flag: '🇸🇳'),
  Country(name: 'Mali',            code: 'ML', dial: '+223', flag: '🇲🇱'),
  Country(name: 'Burkina Faso',    code: 'BF', dial: '+226', flag: '🇧🇫'),
  Country(name: 'Togo',            code: 'TG', dial: '+228', flag: '🇹🇬'),
  Country(name: 'Benin',           code: 'BJ', dial: '+229', flag: '🇧🇯'),
  Country(name: 'Guinea',          code: 'GN', dial: '+224', flag: '🇬🇳'),
  Country(name: 'Sierra Leone',    code: 'SL', dial: '+232', flag: '🇸🇱'),
  Country(name: 'Liberia',         code: 'LR', dial: '+231', flag: '🇱🇷'),
  Country(name: 'Gambia',          code: 'GM', dial: '+220', flag: '🇬🇲'),
  Country(name: 'Cape Verde',      code: 'CV', dial: '+238', flag: '🇨🇻'),
  // East Africa
  Country(name: 'Kenya',           code: 'KE', dial: '+254', flag: '🇰🇪'),
  Country(name: 'Tanzania',        code: 'TZ', dial: '+255', flag: '🇹🇿'),
  Country(name: 'Uganda',          code: 'UG', dial: '+256', flag: '🇺🇬'),
  Country(name: 'Ethiopia',        code: 'ET', dial: '+251', flag: '🇪🇹'),
  Country(name: 'Rwanda',          code: 'RW', dial: '+250', flag: '🇷🇼'),
  Country(name: 'Burundi',         code: 'BI', dial: '+257', flag: '🇧🇮'),
  // Southern Africa
  Country(name: 'South Africa',    code: 'ZA', dial: '+27',  flag: '🇿🇦'),
  Country(name: 'Zimbabwe',        code: 'ZW', dial: '+263', flag: '🇿🇼'),
  Country(name: 'Zambia',          code: 'ZM', dial: '+260', flag: '🇿🇲'),
  Country(name: 'Botswana',        code: 'BW', dial: '+267', flag: '🇧🇼'),
  Country(name: 'Mozambique',      code: 'MZ', dial: '+258', flag: '🇲🇿'),
  Country(name: 'Malawi',          code: 'MW', dial: '+265', flag: '🇲🇼'),
  Country(name: 'Namibia',         code: 'NA', dial: '+264', flag: '🇳🇦'),
  // North Africa
  Country(name: 'Egypt',           code: 'EG', dial: '+20',  flag: '🇪🇬'),
  Country(name: 'Morocco',         code: 'MA', dial: '+212', flag: '🇲🇦'),
  Country(name: 'Tunisia',         code: 'TN', dial: '+216', flag: '🇹🇳'),
  Country(name: 'Algeria',         code: 'DZ', dial: '+213', flag: '🇩🇿'),
  // Central Africa
  Country(name: 'Cameroon',        code: 'CM', dial: '+237', flag: '🇨🇲'),
  Country(name: 'DR Congo',        code: 'CD', dial: '+243', flag: '🇨🇩'),
  Country(name: 'Congo',           code: 'CG', dial: '+242', flag: '🇨🇬'),
  // Diaspora
  Country(name: 'United Kingdom',  code: 'GB', dial: '+44',  flag: '🇬🇧'),
  Country(name: 'United States',   code: 'US', dial: '+1',   flag: '🇺🇸'),
  Country(name: 'Canada',          code: 'CA', dial: '+1',   flag: '🇨🇦'),
  Country(name: 'Germany',         code: 'DE', dial: '+49',  flag: '🇩🇪'),
  Country(name: 'France',          code: 'FR', dial: '+33',  flag: '🇫🇷'),
];

// =============================================================================
// Locale → Country detection
// =============================================================================

/// Returns the best matching [Country] from the device locale chain.
/// Falls back to Ghana (primary market) if no match is found.
Country detectCountryFromLocale() {
  final locales = PlatformDispatcher.instance.locales;
  for (final locale in locales) {
    final code = locale.countryCode?.toUpperCase() ?? '';
    final match = kAfricaCountries.where((c) => c.code == code).firstOrNull;
    if (match != null) return match;
  }
  return kAfricaCountries.first; // Ghana
}

// =============================================================================
// Shared input decoration — single source of truth
// =============================================================================

InputDecoration authInputDecoration({
  required String hint,
  IconData? prefixIcon,
}) {
  return InputDecoration(
    hintText: hint,
    hintStyle: AppTextStyles.bodyMedium.copyWith(
      color: AppColors.textTertiary,
      fontWeight: FontWeight.w400,
    ),
    prefixIcon: prefixIcon != null
        ? Container(
            margin: const EdgeInsets.only(left: 14, right: 10),
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: AppColors.primaryDim,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(prefixIcon, color: AppColors.primary, size: 16),
          )
        : null,
    prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
    filled: true,
    fillColor: AppColors.surface,
    contentPadding:
        const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: AppColors.border, width: 0.5),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: AppColors.border, width: 0.5),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
    ),
    errorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: AppColors.error, width: 1),
    ),
    focusedErrorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: AppColors.error, width: 1.5),
    ),
  );
}

// =============================================================================
// AuthGlow
// =============================================================================

class AuthGlow extends StatelessWidget {
  final Color color;
  final double size;
  final double opacity;

  const AuthGlow({
    super.key,
    required this.color,
    required this.size,
    required this.opacity,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            color.withValues(alpha: opacity),
            color.withValues(alpha: 0),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// AuthBackButton
// =============================================================================

class AuthBackButton extends StatelessWidget {
  const AuthBackButton({super.key});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.pop(context),
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: const Icon(
          Icons.arrow_back_ios_new_rounded,
          color: AppColors.textPrimary,
          size: 16,
        ),
      ),
    );
  }
}

// =============================================================================
// AuthLogo
// =============================================================================

class AuthLogo extends StatelessWidget {
  const AuthLogo({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(
            Icons.directions_car_rounded,
            color: Colors.white,
            size: 22,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          'CTS',
          style: AppTextStyles.heading1.copyWith(
            color: AppColors.primary,
            fontWeight: FontWeight.w900,
            letterSpacing: 2,
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// AuthFieldLabel
// =============================================================================

class AuthFieldLabel extends StatelessWidget {
  final String text;
  const AuthFieldLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: AppTextStyles.overline.copyWith(
        color: AppColors.textTertiary,
        letterSpacing: 1.5,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

// =============================================================================
// AuthFormField
// =============================================================================

class AuthFormField extends StatelessWidget {
  final String label;
  final String hint;
  final TextEditingController controller;
  final String? Function(String?) validator;
  final bool enabled;
  final TextInputType keyboardType;
  final IconData? prefixIcon;
  final TextCapitalization textCapitalization;
  final bool obscureText;
  final Widget? suffixIcon;

  const AuthFormField({
    super.key,
    required this.label,
    required this.hint,
    required this.controller,
    required this.validator,
    required this.enabled,
    this.keyboardType = TextInputType.text,
    this.prefixIcon,
    this.textCapitalization = TextCapitalization.none,
    this.obscureText = false,
    this.suffixIcon,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: AppTextStyles.overline.copyWith(
            color: AppColors.textTertiary,
            letterSpacing: 1.4,
            fontWeight: FontWeight.w700,
            fontSize: 10,
          ),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          validator: validator,
          enabled: enabled,
          keyboardType: keyboardType,
          textCapitalization: textCapitalization,
          obscureText: obscureText,
          style: AppTextStyles.bodyMedium.copyWith(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w500,
          ),
          decoration: authInputDecoration(
            hint: hint,
            prefixIcon: prefixIcon,
          ).copyWith(suffixIcon: suffixIcon),
        ),
      ],
    );
  }
}

// =============================================================================
// AuthCtaButton
// =============================================================================

class AuthCtaButton extends StatelessWidget {
  final String label;
  final bool isLoading;
  final VoidCallback? onTap;

  const AuthCtaButton({
    super.key,
    required this.label,
    required this.isLoading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isLoading ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          color: isLoading
              ? AppColors.primary.withValues(alpha: 0.6)
              : AppColors.primary,
          borderRadius: BorderRadius.circular(16),
          boxShadow: isLoading
              ? null
              : [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.4),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
        ),
        child: Center(
          child: isLoading
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: Colors.white,
                  ),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: AppTextStyles.button.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(
                      Icons.arrow_forward_rounded,
                      color: Colors.white,
                      size: 18,
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

// =============================================================================
// PhoneInputField — country picker + E.164 number composition
// =============================================================================

class PhoneInputField extends StatefulWidget {
  final TextEditingController controller;
  final String? Function(String?) validator;
  final bool enabled;
  final ValueChanged<Country>? onCountryChanged;

  const PhoneInputField({
    super.key,
    required this.controller,
    required this.validator,
    required this.enabled,
    this.onCountryChanged,
  });

  @override
  State<PhoneInputField> createState() => PhoneInputFieldState();
}

class PhoneInputFieldState extends State<PhoneInputField> {
  late Country _selected;

  @override
  void initState() {
    super.initState();
    _selected = detectCountryFromLocale();
  }

  Country get selectedCountry => _selected;

  /// Returns a clean E.164 number: dial code + digits only from the field.
  ///
  /// ✅ Fixed: previously used a regex that could strip valid leading digits.
  /// Now simply removes all non-digit characters from the typed value,
  /// then prepends the dial code (without the '+' duplication issue).
  String get fullNumber {
    final digitsOnly =
        widget.controller.text.trim().replaceAll(RegExp(r'\D'), '');
    // Remove leading zeros common in local format (e.g. 0244... → 244...)
    final local = digitsOnly.startsWith('0')
        ? digitsOnly.substring(1)
        : digitsOnly;
    return '${_selected.dial}$local'; // e.g. +233244123456
  }

  void _openPicker() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CountryPickerSheet(
        selected: _selected,
        onSelected: (country) {
          setState(() => _selected = country);
          widget.onCountryChanged?.call(country);
          Navigator.pop(context);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.controller,
      validator: widget.validator,
      enabled: widget.enabled,
      keyboardType: TextInputType.phone,
      style: AppTextStyles.bodyLarge.copyWith(
        color: AppColors.textPrimary,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.8,
      ),
      decoration: InputDecoration(
        hintText: 'XX XXX XXXX',
        hintStyle: AppTextStyles.bodyLarge.copyWith(
          color: AppColors.textTertiary,
          fontWeight: FontWeight.w400,
        ),
        prefixIcon: GestureDetector(
          onTap: widget.enabled ? _openPicker : null,
          child: Container(
            margin: const EdgeInsets.only(left: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_selected.flag,
                    style: const TextStyle(fontSize: 20)),
                const SizedBox(width: 6),
                Text(
                  _selected.dial,
                  style: AppTextStyles.bodyMedium.copyWith(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(
                  Icons.keyboard_arrow_down_rounded,
                  color: AppColors.textTertiary,
                  size: 16,
                ),
                Container(
                  margin: const EdgeInsets.only(left: 10),
                  width: 1,
                  height: 22,
                  color: AppColors.border,
                ),
              ],
            ),
          ),
        ),
        prefixIconConstraints:
            const BoxConstraints(minWidth: 0, minHeight: 0),
        filled: true,
        fillColor: AppColors.surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 18,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide:
              const BorderSide(color: AppColors.border, width: 0.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide:
              const BorderSide(color: AppColors.border, width: 0.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide:
              const BorderSide(color: AppColors.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: AppColors.error, width: 1),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide:
              const BorderSide(color: AppColors.error, width: 1.5),
        ),
      ),
    );
  }
}

// =============================================================================
// Country picker bottom sheet
// =============================================================================

class _CountryPickerSheet extends StatefulWidget {
  final Country selected;
  final ValueChanged<Country> onSelected;

  const _CountryPickerSheet({
    required this.selected,
    required this.onSelected,
  });

  @override
  State<_CountryPickerSheet> createState() => _CountryPickerSheetState();
}

class _CountryPickerSheetState extends State<_CountryPickerSheet> {
  final _searchController = TextEditingController();
  List<Country> _filtered = kAfricaCountries;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onSearch(String query) {
    final q = query.toLowerCase();
    setState(() {
      _filtered = query.isEmpty
          ? kAfricaCountries
          : kAfricaCountries
              .where((c) =>
                  c.name.toLowerCase().contains(q) ||
                  c.dial.contains(q) ||
                  c.code.toLowerCase().contains(q))
              .toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      snap: true,
      snapSizes: const [0.5, 0.75, 0.95],
      expand: false,
      builder: (_, scrollController) => Container(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            // Handle
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 12, bottom: 16),
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Title
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Select Country',
                  style: AppTextStyles.heading3
                      .copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Search
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                controller: _searchController,
                onChanged: _onSearch,
                style: AppTextStyles.bodyMedium
                    .copyWith(color: AppColors.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Search country or dial code',
                  hintStyle: AppTextStyles.bodyMedium
                      .copyWith(color: AppColors.textTertiary),
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    color: AppColors.textTertiary,
                    size: 18,
                  ),
                  filled: true,
                  fillColor: AppColors.surfaceAlt,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(
                        color: AppColors.primary, width: 1.5),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // List
            Expanded(
              child: _filtered.isEmpty
                  ? Center(
                      child: Text(
                        'No results',
                        style: AppTextStyles.bodySmall
                            .copyWith(color: AppColors.textTertiary),
                      ),
                    )
                  : ListView.builder(
                      controller: scrollController,
                      itemCount: _filtered.length,
                      itemBuilder: (_, i) {
                        final country = _filtered[i];
                        final isSelected =
                            country.code == widget.selected.code;

                        return InkWell(
                          onTap: () => widget.onSelected(country),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            margin: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 2),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 14),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? AppColors.primaryDim
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                Text(country.flag,
                                    style:
                                        const TextStyle(fontSize: 24)),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Text(
                                    country.name,
                                    style:
                                        AppTextStyles.bodyMedium.copyWith(
                                      color: isSelected
                                          ? AppColors.primary
                                          : AppColors.textPrimary,
                                      fontWeight: isSelected
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                    ),
                                  ),
                                ),
                                Text(
                                  country.dial,
                                  style: AppTextStyles.bodyMedium.copyWith(
                                    color: isSelected
                                        ? AppColors.primary
                                        : AppColors.textTertiary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (isSelected) ...[
                                  const SizedBox(width: 10),
                                  Container(
                                    width: 20,
                                    height: 20,
                                    decoration: const BoxDecoration(
                                      color: AppColors.primary,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.check_rounded,
                                      color: Colors.white,
                                      size: 12,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            SizedBox(
                height: MediaQuery.of(context).padding.bottom + 12),
          ],
        ),
      ),
    );
  }
}