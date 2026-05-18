import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../widgets/common/shared_widgets.dart';
import 'delivery_vehicle_screen.dart';

class DeliveryScreen extends StatefulWidget {
  const DeliveryScreen({super.key});

  @override
  State<DeliveryScreen> createState() => _DeliveryScreenState();
}

class _DeliveryScreenState extends State<DeliveryScreen> {
  // Controllers
  final TextEditingController _pickupController = TextEditingController();
  final TextEditingController _dropoffController = TextEditingController();
  final TextEditingController _receiverPhoneCtrl = TextEditingController();
  final TextEditingController _receiverNameCtrl = TextEditingController();
  final TextEditingController _noteController = TextEditingController();

  // Selections
  int _selectedParcelType = 0;
  int _selectedWeightTier = -1; // must be chosen before proceeding
  bool _isFragile = false;
  bool _requiresHelpers = false;
  String? _photoPath; // set after image picker (placeholder)

  // ── Data ────────────────────────────────────────────────────────────────
  final List<Map<String, dynamic>> _parcelTypes = [
    {'icon': Icons.description_rounded, 'label': 'Documents'},
    {'icon': Icons.inventory_2_rounded, 'label': 'Package'},
    {'icon': Icons.fastfood_rounded, 'label': 'Food'},
    {'icon': Icons.devices_rounded, 'label': 'Electronics'},
    {'icon': Icons.chair_rounded, 'label': 'Furniture'},
    {'icon': Icons.construction_rounded, 'label': 'Materials'},
  ];

  // Weight tiers — drive vehicle matching + pricing
  final List<Map<String, dynamic>> _weightTiers = [
    {
      'label': 'Small',
      'range': '0 – 5 kg',
      'example': 'Documents, food, small parcels',
      'vehicles': ['Okada'],
      'icon': Icons.two_wheeler_rounded,
    },
    {
      'label': 'Medium',
      'range': '5 – 20 kg',
      'example': 'Groceries, boxes, electronics',
      'vehicles': ['Okada', 'Aboboya'],
      'icon': Icons.inventory_2_rounded,
    },
    {
      'label': 'Large',
      'range': '20 – 100 kg',
      'example': 'Market goods, appliances',
      'vehicles': ['Aboboya'],
      'icon': Icons.shopping_cart_rounded,
    },
    {
      'label': 'Bulk',
      'range': '100 kg+',
      'example': 'Furniture, construction materials',
      'vehicles': ['Mini Truck'],
      'icon': Icons.local_shipping_rounded,
    },
  ];

  bool get _canProceed =>
      _dropoffController.text.isNotEmpty && _selectedWeightTier >= 0;

  @override
  void dispose() {
    _pickupController.dispose();
    _dropoffController.dispose();
    _receiverPhoneCtrl.dispose();
    _receiverNameCtrl.dispose();
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: const CTSRideAppBar(title: 'Send a Parcel'),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Step 1 & 2 : Route ─────────────────────────────────────
            _buildRouteCard(),
            const SizedBox(height: 14),

            // ── Step 3 : Parcel type ───────────────────────────────────
            _buildSectionCard(
              step: 3,
              title: 'What are you sending?',
              child: _buildParcelTypes(),
            ),
            const SizedBox(height: 14),

            // ── Step 4 : Weight tier ───────────────────────────────────
            _buildSectionCard(
              step: 4,
              title: 'Approximate weight',
              subtitle: 'This determines which vehicles can take your delivery',
              child: _buildWeightTiers(),
            ),
            const SizedBox(height: 14),

            // ── Step 5 : Photo ─────────────────────────────────────────
            _buildSectionCard(
              step: 5,
              title: 'Photo of items',
              subtitle: 'Helps drivers prepare and verify at pickup',
              child: _buildPhotoUpload(),
            ),
            const SizedBox(height: 14),

            // ── Step 6 : Receiver ──────────────────────────────────────
            _buildSectionCard(
              step: 6,
              title: "Receiver's contact",
              child: _buildReceiverFields(),
            ),
            const SizedBox(height: 14),

            // ── Step 7 : Extra options ─────────────────────────────────
            _buildSectionCard(
              step: 7,
              title: 'Extra options',
              child: _buildExtraOptions(),
            ),
            const SizedBox(height: 14),

            // ── Step 8 : Notes ─────────────────────────────────────────
            _buildSectionCard(
              step: 8,
              title: 'Delivery notes',
              child: _inputField(
                controller: _noteController,
                hint: 'Any special instructions for the rider…',
                icon: Icons.notes_rounded,
                maxLines: 3,
              ),
            ),
            const SizedBox(height: 24),

            // ── CTA ───────────────────────────────────────────────────
            PrimaryButton(
              label: _canProceed
                  ? 'See available vehicles →'
                  : 'Complete required fields',
              onTap: _canProceed ? _goToVehicleScreen : null,
              color: _canProceed ? null : AppColors.textTertiary,
            ),
            const SizedBox(height: 8),
            if (!_canProceed)
              Center(
                child: Text(
                  'Set drop-off location and weight to continue',
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textSecondary),
                  textAlign: TextAlign.center,
                ),
              ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  // ─── Route Card ────────────────────────────────────────────────────────────
  Widget _buildRouteCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Step 1 — pickup
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _StepNumber(number: '1'),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Pickup location',
                        style: AppTextStyles.labelLarge),
                    const SizedBox(height: 8),
                    // Current location chip
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceAlt,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.my_location_rounded,
                              color: AppColors.success, size: 16),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Osu, Accra (current location)',
                              style: AppTextStyles.bodySmall
                                  .copyWith(color: AppColors.textPrimary),
                            ),
                          ),
                          Text('Change',
                              style: AppTextStyles.caption.copyWith(
                                  color: AppColors.primary,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          // Connector
          Padding(
            padding: const EdgeInsets.only(left: 13, top: 6, bottom: 6),
            child:
                Container(width: 2, height: 20, color: AppColors.borderLight),
          ),

          // Step 2 — drop-off
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _StepNumber(number: '2'),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Drop-off address',
                        style: AppTextStyles.labelLarge),
                    const SizedBox(height: 8),
                    _inputField(
                      controller: _dropoffController,
                      hint: 'Search destination…',
                      icon: Icons.location_on_rounded,
                      onChanged: (_) => setState(() {}),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ─── Parcel Types ───────────────────────────────────────────────────────────
  Widget _buildParcelTypes() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: List.generate(_parcelTypes.length, (i) {
        final p = _parcelTypes[i];
        final isSelected = _selectedParcelType == i;
        return GestureDetector(
          onTap: () => setState(() => _selectedParcelType = i),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: isSelected
                  ? AppColors.primary.withValues(alpha: 0.1)
                  : AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isSelected ? AppColors.primary : AppColors.border,
                width: isSelected ? 1.5 : 0.5,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(p['icon'],
                    size: 15,
                    color: isSelected
                        ? AppColors.primary
                        : AppColors.textSecondary),
                const SizedBox(width: 6),
                Text(
                  p['label'],
                  style: AppTextStyles.labelMedium.copyWith(
                    color: isSelected
                        ? AppColors.primary
                        : AppColors.textSecondary,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }

  // ─── Weight Tiers ───────────────────────────────────────────────────────────
  Widget _buildWeightTiers() {
    return Column(
      children: List.generate(_weightTiers.length, (i) {
        final t = _weightTiers[i];
        final isSelected = _selectedWeightTier == i;
        return GestureDetector(
          onTap: () => setState(() => _selectedWeightTier = i),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isSelected
                  ? AppColors.primary.withValues(alpha: 0.07)
                  : AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isSelected ? AppColors.primary : AppColors.border,
                width: isSelected ? 1.5 : 0.5,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? AppColors.primary.withValues(alpha: 0.12)
                        : AppColors.surface,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(t['icon'],
                      color: isSelected
                          ? AppColors.primary
                          : AppColors.textSecondary,
                      size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(t['label'],
                              style: AppTextStyles.labelLarge.copyWith(
                                  color: isSelected
                                      ? AppColors.primary
                                      : AppColors.textPrimary)),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? AppColors.primary.withValues(alpha: 0.1)
                                  : AppColors.border,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(t['range'],
                                style: AppTextStyles.caption.copyWith(
                                    color: isSelected
                                        ? AppColors.primary
                                        : AppColors.textSecondary,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(t['example'], style: AppTextStyles.caption),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: (t['vehicles'] as List<String>)
                      .map((v) => Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Text(v,
                                style: AppTextStyles.caption.copyWith(
                                    color: isSelected
                                        ? AppColors.primary
                                        : AppColors.textTertiary,
                                    fontSize: 10)),
                          ))
                      .toList(),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }

  // ─── Photo Upload ───────────────────────────────────────────────────────────
  Widget _buildPhotoUpload() {
    return Column(
      children: [
        GestureDetector(
          onTap: _pickPhoto,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: double.infinity,
            height: 120,
            decoration: BoxDecoration(
              color: _photoPath != null
                  ? AppColors.primary.withValues(alpha: 0.06)
                  : AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color:
                    _photoPath != null ? AppColors.primary : AppColors.border,
                width: _photoPath != null ? 1.5 : 0.5,
                style:
                    _photoPath != null ? BorderStyle.solid : BorderStyle.solid,
              ),
            ),
            child: _photoPath != null
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.check_circle_rounded,
                          color: AppColors.success, size: 32),
                      const SizedBox(height: 6),
                      Text('Photo added',
                          style: AppTextStyles.labelMedium
                              .copyWith(color: AppColors.success)),
                      const Text('Tap to change', style: AppTextStyles.caption),
                    ],
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.add_a_photo_rounded,
                          color: AppColors.textTertiary, size: 30),
                      const SizedBox(height: 8),
                      Text('Add photo of items',
                          style: AppTextStyles.labelMedium
                              .copyWith(color: AppColors.textSecondary)),
                      const SizedBox(height: 2),
                      const Text('Helps drivers verify at pickup',
                          style: AppTextStyles.caption),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 8),
        const Row(
          children: [
            Icon(Icons.info_outline_rounded,
                size: 13, color: AppColors.textTertiary),
            SizedBox(width: 4),
            Expanded(
              child: Text(
                'Photo is shown to the driver for reference. It does not affect the fare.',
                style: AppTextStyles.caption,
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ─── Receiver Fields ────────────────────────────────────────────────────────
  Widget _buildReceiverFields() {
    return Column(
      children: [
        _inputField(
          controller: _receiverPhoneCtrl,
          hint: '+233 — Phone number',
          icon: Icons.phone_rounded,
          keyboardType: TextInputType.phone,
        ),
        const SizedBox(height: 10),
        _inputField(
          controller: _receiverNameCtrl,
          hint: "Receiver's name (optional)",
          icon: Icons.person_rounded,
        ),
      ],
    );
  }

  // ─── Extra Options ──────────────────────────────────────────────────────────
  Widget _buildExtraOptions() {
    return Column(
      children: [
        _ToggleRow(
          icon: Icons.broken_image_rounded,
          label: 'Fragile item',
          subtitle: '+GHS 5.00 handling fee',
          value: _isFragile,
          onChanged: (v) => setState(() => _isFragile = v),
        ),
        const SizedBox(height: 10),
        _ToggleRow(
          icon: Icons.people_rounded,
          label: 'Requires loading helpers',
          subtitle: '+GHS 10.00 (Aboboya / Mini Truck only)',
          value: _requiresHelpers,
          onChanged: (v) => setState(() => _requiresHelpers = v),
        ),
      ],
    );
  }

  // ─── Helpers ────────────────────────────────────────────────────────────────
  Widget _buildSectionCard({
    required int step,
    required String title,
    String? subtitle,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StepNumber(number: '$step'),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTextStyles.labelLarge),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle, style: AppTextStyles.caption),
                ],
                const SizedBox(height: 10),
                child,
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _inputField({
    TextEditingController? controller,
    required String hint,
    required IconData icon,
    TextInputType? keyboardType,
    int maxLines = 1,
    ValueChanged<String>? onChanged,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        maxLines: maxLines,
        onChanged: onChanged,
        style: AppTextStyles.bodyMedium,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: AppTextStyles.bodySmall.copyWith(
              color: AppColors.textTertiary, fontStyle: FontStyle.italic),
          prefixIcon: Icon(icon, color: AppColors.textSecondary, size: 18),
          border: InputBorder.none,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        ),
      ),
    );
  }

  void _pickPhoto() {
    // Wire to image_picker in production:
    // final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    // if (picked != null) setState(() => _photoPath = picked.path);
    setState(() => _photoPath = 'mock_photo.jpg');
  }

  void _goToVehicleScreen() {
    final tier = _weightTiers[_selectedWeightTier];
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DeliveryVehicleScreen(
          pickup: 'Osu, Accra',
          dropoff: _dropoffController.text,
          weightTier: tier['label'],
          weightRange: tier['range'],
          eligibleVehicles: tier['vehicles'],
          parcelType: _parcelTypes[_selectedParcelType]['label'],
          isFragile: _isFragile,
          requiresHelpers: _requiresHelpers,
          hasPhoto: _photoPath != null,
          receiverPhone: _receiverPhoneCtrl.text,
          notes: _noteController.text,
        ),
      ),
    );
  }
}

// ─── Step Number ──────────────────────────────────────────────────────────────
class _StepNumber extends StatelessWidget {
  final String number;
  const _StepNumber({required this.number});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26,
      height: 26,
      decoration: const BoxDecoration(
        color: AppColors.primary,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          number,
          style: AppTextStyles.caption.copyWith(
            color: AppColors.background,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

// ─── Toggle Row ───────────────────────────────────────────────────────────────
class _ToggleRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ToggleRow({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: value
            ? AppColors.primary.withValues(alpha: 0.06)
            : AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: value ? AppColors.primary : AppColors.border,
          width: value ? 1.5 : 0.5,
        ),
      ),
      child: Row(
        children: [
          Icon(icon,
              size: 18,
              color: value ? AppColors.primary : AppColors.textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: AppTextStyles.labelMedium.copyWith(
                        color:
                            value ? AppColors.primary : AppColors.textPrimary)),
                Text(subtitle, style: AppTextStyles.caption),
              ],
            ),
          ),
          Switch.adaptive(
            value: value,
            onChanged: onChanged,
            activeColor: AppColors.primary,
          ),
        ],
      ),
    );
  }
}
