import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../widgets/common/shared_widgets.dart';

class SavedPlacesScreen extends StatefulWidget {
  const SavedPlacesScreen({super.key});
  @override
  State<SavedPlacesScreen> createState() => _SavedPlacesScreenState();
}

class _SavedPlacesScreenState extends State<SavedPlacesScreen> {
  final List<_Place> _places = [
    _Place(
        label: 'Home',
        address: '456 Residential Ave, East Legon',
        icon: Icons.home_rounded,
        isPinned: true),
    _Place(
        label: 'Office',
        address: '123 Business St, Cantonments',
        icon: Icons.business_rounded,
        isPinned: true),
    _Place(
        label: 'Gym',
        address: '789 Fitness Rd, Labone',
        icon: Icons.fitness_center_rounded,
        isPinned: false),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: CTSRideAppBar(
        title: 'Saved Places',
        actions: [
          TextButton.icon(
            onPressed: () => _showAddPlaceSheet(),
            icon: const Icon(Icons.add_rounded,
                color: AppColors.primary, size: 18),
            label: Text('Add',
                style: AppTextStyles.labelMedium
                    .copyWith(color: AppColors.primary)),
          ),
        ],
      ),
      body: _places.isEmpty
          ? _buildEmpty()
          : ListView.separated(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.all(16),
              itemCount: _places.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, i) => _PlaceTile(
                place: _places[i],
                onEdit: () =>
                    _showAddPlaceSheet(existing: _places[i], index: i),
                onDelete: () => setState(() => _places.removeAt(i)),
              ),
            ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.location_off_rounded,
              size: 52, color: AppColors.textTertiary),
          const SizedBox(height: 12),
          const Text('No saved places', style: AppTextStyles.heading4),
          const SizedBox(height: 6),
          const Text('Add home, office or frequent destinations',
              style: AppTextStyles.bodySmall),
          const SizedBox(height: 20),
          GestureDetector(
            onTap: () => _showAddPlaceSheet(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text('Add a place', style: AppTextStyles.button),
            ),
          ),
        ],
      ),
    );
  }

  void _showAddPlaceSheet({_Place? existing, int? index}) {
    final labelCtrl = TextEditingController(text: existing?.label ?? '');
    final addressCtrl = TextEditingController(text: existing?.address ?? '');
    IconData selectedIcon = existing?.icon ?? Icons.place_rounded;

    final icons = [
      Icons.home_rounded,
      Icons.business_rounded,
      Icons.fitness_center_rounded,
      Icons.local_hospital_rounded,
      Icons.school_rounded,
      Icons.restaurant_rounded,
      Icons.place_rounded,
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setLocal) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                        color: AppColors.border,
                        borderRadius: BorderRadius.circular(2))),
              ),
              const SizedBox(height: 16),
              Text(existing == null ? 'Add place' : 'Edit place',
                  style: AppTextStyles.heading3),
              const SizedBox(height: 16),
              // Icon picker
              const Text('Icon', style: AppTextStyles.labelLarge),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: icons.map((ic) {
                    final sel = selectedIcon == ic;
                    return GestureDetector(
                      onTap: () => setLocal(() => selectedIcon = ic),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        margin: const EdgeInsets.only(right: 8),
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: sel ? AppColors.primary : AppColors.surfaceAlt,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color:
                                  sel ? AppColors.primary : AppColors.border),
                        ),
                        child: Icon(ic,
                            color: sel
                                ? AppColors.background
                                : AppColors.textSecondary,
                            size: 20),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 14),
              const Text('Label', style: AppTextStyles.labelLarge),
              const SizedBox(height: 8),
              _SheetField(controller: labelCtrl, hint: 'e.g. Home, Office'),
              const SizedBox(height: 14),
              const Text('Address', style: AppTextStyles.labelLarge),
              const SizedBox(height: 8),
              _SheetField(
                  controller: addressCtrl,
                  hint: 'Search or paste address',
                  icon: Icons.search_rounded),
              const SizedBox(height: 20),
              PrimaryButton(
                label: existing == null ? 'Save place' : 'Update place',
                onTap: () {
                  if (labelCtrl.text.isEmpty || addressCtrl.text.isEmpty) {
                    return;
                  }
                  setState(() {
                    final p = _Place(
                      label: labelCtrl.text,
                      address: addressCtrl.text,
                      icon: selectedIcon,
                      isPinned: existing?.isPinned ?? false,
                    );
                    if (index != null) {
                      _places[index] = p;
                    } else {
                      _places.add(p);
                    }
                  });
                  Navigator.pop(context);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Place {
  String label;
  String address;
  IconData icon;
  bool isPinned;
  _Place(
      {required this.label,
      required this.address,
      required this.icon,
      required this.isPinned});
}

class _PlaceTile extends StatelessWidget {
  final _Place place;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const _PlaceTile(
      {required this.place, required this.onEdit, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(place.icon, color: AppColors.primary, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(place.label, style: AppTextStyles.labelLarge),
                    if (place.isPinned) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text('Pinned',
                            style: AppTextStyles.caption.copyWith(
                                color: AppColors.primary,
                                fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(place.address,
                    style: AppTextStyles.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded,
                color: AppColors.textTertiary, size: 18),
            onSelected: (v) {
              if (v == 'edit') onEdit();
              if (v == 'delete') onDelete();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'edit', child: Text('Edit')),
              const PopupMenuItem(
                  value: 'delete',
                  child:
                      Text('Delete', style: TextStyle(color: AppColors.error))),
            ],
          ),
        ],
      ),
    );
  }
}

class _SheetField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData? icon;
  const _SheetField({required this.controller, required this.hint, this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: TextField(
        controller: controller,
        style: AppTextStyles.bodyMedium,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle:
              AppTextStyles.bodySmall.copyWith(color: AppColors.textTertiary),
          prefixIcon: icon != null
              ? Icon(icon, size: 18, color: AppColors.textSecondary)
              : null,
          border: InputBorder.none,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
      ),
    );
  }
}
