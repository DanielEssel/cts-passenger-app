// lib/features/profile/presentation/screens/saved_places_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../ride/models/place_result.dart';
import '../../ride/repositories/place_repository.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_text_styles.dart';
import '../../../../widgets/common/shared_widgets.dart';
import '../../auth/providers/auth_providers.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Model
// ─────────────────────────────────────────────────────────────────────────────

class SavedPlace {
  final String? id;
  final String label;
  final String address;
  final String? placeId;
  final double? lat;
  final double? lng;
  final String iconKey; // stored as string for Firestore
  final DateTime? createdAt;

  const SavedPlace({
    this.id,
    required this.label,
    required this.address,
    this.placeId,
    this.lat,
    this.lng,
    required this.iconKey,
    this.createdAt,
  });

  // Fix SavedPlace.fromFirestore — add null safety everywhere
  factory SavedPlace.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>? ?? {};
    return SavedPlace(
      id: doc.id,
      label: (d['label'] as String?) ?? '',
      address: (d['address'] as String?) ?? '',
      placeId: d['placeId'] as String?,
      lat: (d['lat'] as num?)?.toDouble(),
      lng: (d['lng'] as num?)?.toDouble(),
      iconKey: (d['iconKey'] as String?) ?? 'place',
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toFirestore() => {
        'label': label,
        'address': address,
        'placeId': placeId,
        'lat': lat,
        'lng': lng,
        'iconKey': iconKey,
        'createdAt': FieldValue.serverTimestamp(),
      };

  SavedPlace copyWith({
    String? label,
    String? address,
    String? placeId,
    double? lat,
    double? lng,
    String? iconKey,
  }) =>
      SavedPlace(
        id: id,
        label: label ?? this.label,
        address: address ?? this.address,
        placeId: placeId ?? this.placeId,
        lat: lat ?? this.lat,
        lng: lng ?? this.lng,
        iconKey: iconKey ?? this.iconKey,
        createdAt: createdAt,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Provider — real-time stream from Firestore
// ─────────────────────────────────────────────────────────────────────────────

final savedPlacesStreamProvider =
    StreamProvider.autoDispose<List<SavedPlace>>((ref) {
  final uid = ref.watch(userIdProvider);
  if (uid == null) return Stream.value([]);

  return FirebaseFirestore.instance
      .collection('users')
      .doc(uid)
      .collection('saved_places')
      .orderBy('createdAt', descending: false)
      .snapshots()
      .map((snap) => snap.docs.map(SavedPlace.fromFirestore).toList());
});

// ─────────────────────────────────────────────────────────────────────────────
// Icon map
// ─────────────────────────────────────────────────────────────────────────────

const _iconMap = <String, IconData>{
  'home': Icons.home_rounded,
  'work': Icons.business_rounded,
  'gym': Icons.fitness_center_rounded,
  'hospital': Icons.local_hospital_rounded,
  'school': Icons.school_rounded,
  'food': Icons.restaurant_rounded,
  'place': Icons.place_rounded,
};

IconData _iconFor(String key) => _iconMap[key] ?? Icons.place_rounded;

// ─────────────────────────────────────────────────────────────────────────────
// Screen
// ─────────────────────────────────────────────────────────────────────────────

class SavedPlacesScreen extends ConsumerWidget {
  const SavedPlacesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final placesAsync = ref.watch(savedPlacesStreamProvider);

    return Scaffold(
        backgroundColor: AppColors.background,
        appBar: CTSTransportAppBar(
          title: 'Saved Places',
          actions: [
            TextButton.icon(
              onPressed: () => _showAddEditSheet(context, ref),
              icon: const Icon(Icons.add_rounded,
                  color: AppColors.primary, size: 18),
              label: Text('Add',
                  style: AppTextStyles.labelMedium
                      .copyWith(color: AppColors.primary)),
            ),
          ],
        ),
        body: placesAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => _ErrorState(
            message: e.toString(),
            onRetry: () => ref.invalidate(savedPlacesStreamProvider),
          ),
          data: (places) => places.isEmpty
              ? _EmptyState(onAdd: () => _showAddEditSheet(context, ref))
              : ListView.separated(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  itemCount: places.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) => _PlaceTile(
                    place: places[i],
                    onEdit: () =>
                        _showAddEditSheet(context, ref, existing: places[i]),
                    onDelete: () {
                      debugPrint('Deleting place ID: ${places[i].id}');
                      _deletePlace(context, ref, places[i]);
                    },
                  ),
                ),
        ));
  }

  // ── Add / Edit sheet ────────────────────────────────────────────────────

  void _showAddEditSheet(
    BuildContext context,
    WidgetRef ref, {
    SavedPlace? existing,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetCtx) => _AddEditSheet(
        existing: existing,
        onSaved: (place) async {
          Navigator.pop(sheetCtx);
          await _savePlace(context, ref, place, existing);
        },
      ),
    );
  }

  // ── Firestore writes ────────────────────────────────────────────────────

  Future<void> _savePlace(
    BuildContext context,
    WidgetRef ref,
    SavedPlace place,
    SavedPlace? existing,
  ) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final col = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('saved_places');

    try {
      if (existing?.id != null) {
        await col.doc(existing!.id).update({
          'label': place.label,
          'address': place.address,
          'placeId': place.placeId,
          'lat': place.lat,
          'lng': place.lng,
          'iconKey': place.iconKey,
        });
      } else {
        await col.add(place.toFirestore());
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Failed to save: $e'),
          backgroundColor: AppColors.error,
        ));
      }
    }
  }

  Future<void> _deletePlace(
    BuildContext context,
    WidgetRef ref,
    SavedPlace place,
  ) async {
    // Guard — must have an ID to delete
    if (place.id == null || place.id!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot delete this place — missing ID'),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Remove place?', style: AppTextStyles.heading3),
        content: Text(
          'Remove "${place.label}" from your saved places?',
          style: AppTextStyles.bodySmall,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: Text('Cancel',
                style: AppTextStyles.bodySmall
                    .copyWith(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: Text('Remove',
                style:
                    AppTextStyles.bodySmall.copyWith(color: AppColors.error)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('saved_places')
          .doc(place.id!)
          .delete();

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Row(children: [
              Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
              SizedBox(width: 8),
              Text('Place removed'),
            ]),
            backgroundColor: AppColors.success,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Failed to delete: $e'),
          backgroundColor: AppColors.error,
        ));
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Add / Edit sheet — StatefulWidget manages Places autocomplete
// ─────────────────────────────────────────────────────────────────────────────

class _AddEditSheet extends ConsumerStatefulWidget {
  final SavedPlace? existing;
  final void Function(SavedPlace) onSaved;

  const _AddEditSheet({
    required this.onSaved,
    this.existing,
  });

  @override
  ConsumerState<_AddEditSheet> createState() => _AddEditSheetState();
}

class _AddEditSheetState extends ConsumerState<_AddEditSheet> {
  final _labelCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _addressFocus = FocusNode();

  String _selectedIconKey = 'place';
  String? _selectedPlaceId;
  double? _selectedLat;
  double? _selectedLng;
  bool _isSaving = false;

  // Places search state
  List<PlaceResult> _suggestions = [];
  bool _searching = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _labelCtrl.text = e.label;
      _addressCtrl.text = e.address;
      _selectedIconKey = e.iconKey;
      _selectedPlaceId = e.placeId;
      _selectedLat = e.lat;
      _selectedLng = e.lng;
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _labelCtrl.dispose();
    _addressCtrl.dispose();
    _addressFocus.dispose();
    super.dispose();
  }

  void _onAddressChanged(String value) {
    // Typing invalidates a previously-selected place until they pick again.
    _selectedPlaceId = null;
    _selectedLat = null;
    _selectedLng = null;

    _debounce?.cancel();
    if (value.trim().length < 3) {
      setState(() => _suggestions = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      setState(() => _searching = true);
      final repo = ref.read(placeRepositoryProvider);
      final results = await repo.search(value.trim());
      if (!mounted) return;
      setState(() {
        _suggestions = results;
        _searching = false;
      });
    });
  }

  void _selectSuggestion(PlaceResult place) {
    _addressCtrl.text = place.address.isNotEmpty
        ? '${place.name}, ${place.address}'
        : place.name;
    _selectedPlaceId =
        null; // New API doesn't round-trip placeId here; coords are what matter
    _selectedLat = place.location.latitude;
    _selectedLng = place.location.longitude;
    setState(() => _suggestions = []);
    _addressFocus.unfocus();
  }

  void _submit() {
    if (_labelCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a label'),
          backgroundColor: AppColors.warning,
        ),
      );
      return;
    }
    if (_addressCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select an address'),
          backgroundColor: AppColors.warning,
        ),
      );
      return;
    }

    setState(() => _isSaving = true);

    widget.onSaved(SavedPlace(
      id: widget.existing?.id,
      label: _labelCtrl.text.trim(),
      address: _addressCtrl.text.trim(),
      placeId: _selectedPlaceId,
      lat: _selectedLat,
      lng: _selectedLng,
      iconKey: _selectedIconKey,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
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
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(isEdit ? 'Edit place' : 'Add place',
                style: AppTextStyles.heading3),
            const SizedBox(height: 4),
            Text(
              isEdit
                  ? 'Update your saved location'
                  : 'Save a location for quick access',
              style: AppTextStyles.caption
                  .copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 20),

            // ── Icon picker ──
            const Text('Icon', style: AppTextStyles.labelLarge),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: _iconMap.entries.map((e) {
                  final isSelected = _selectedIconKey == e.key;
                  return GestureDetector(
                    onTap: () => setState(() => _selectedIconKey = e.key),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      margin: const EdgeInsets.only(right: 8),
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: isSelected
                            ? AppColors.primary
                            : AppColors.surfaceAlt,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color:
                              isSelected ? AppColors.primary : AppColors.border,
                        ),
                      ),
                      child: Icon(
                        e.value,
                        color:
                            isSelected ? Colors.white : AppColors.textSecondary,
                        size: 22,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 16),

            // ── Label ──
            const Text('Label', style: AppTextStyles.labelLarge),
            const SizedBox(height: 8),
            _Field(
              controller: _labelCtrl,
              hint: 'e.g. Home, Office, Gym',
              icon: Icons.label_rounded,
            ),
            const SizedBox(height: 16),

            // ── Address with Google Places autocomplete ──
            // ── Address with Places search (same repo as the rest of the app) ──
            const Text('Address', style: AppTextStyles.labelLarge),
            const SizedBox(height: 8),
            _Field(
              controller: _addressCtrl,
              hint: 'Search for an address',
              icon: Icons.search_rounded,
              focusNode: _addressFocus,
              onChanged: _onAddressChanged,
            ),
            if (_searching) ...[
              const SizedBox(height: 8),
              const Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ],
            if (_suggestions.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.border),
                ),
                child: Column(
                  children: _suggestions.take(5).map((p) {
                    return InkWell(
                      onTap: () => _selectSuggestion(p),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        child: Row(
                          children: [
                            const Icon(Icons.location_on_rounded,
                                size: 16, color: AppColors.textSecondary),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(p.name,
                                      style: AppTextStyles.bodyMedium,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                  if (p.address.isNotEmpty)
                                    Text(p.address,
                                        style: AppTextStyles.caption.copyWith(
                                            color: AppColors.textTertiary),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],

            const SizedBox(height: 24),

            PrimaryButton(
              label: isEdit ? 'Update place' : 'Save place',
              isLoading: _isSaving,
              onTap: _submit,
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
// ─────────────────────────────────────────────────────────────────────────────
// Place tile
// ─────────────────────────────────────────────────────────────────────────────

class _PlaceTile extends StatelessWidget {
  final SavedPlace place;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _PlaceTile({
    required this.place,
    required this.onEdit,
    required this.onDelete,
  });

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
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(_iconFor(place.iconKey),
                color: AppColors.primary, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(place.label, style: AppTextStyles.labelLarge),
                const SizedBox(height: 2),
                Text(
                  place.address,
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded,
                color: AppColors.textTertiary, size: 18),
            color: AppColors.surface,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            onSelected: (v) {
              if (v == 'edit') onEdit();
              if (v == 'delete') onDelete();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'edit',
                child: Row(children: [
                  const Icon(Icons.edit_rounded,
                      size: 16, color: AppColors.textSecondary),
                  const SizedBox(width: 10),
                  Text('Edit', style: AppTextStyles.bodyMedium),
                ]),
              ),
              PopupMenuItem(
                value: 'delete',
                child: Row(children: [
                  const Icon(Icons.delete_outline_rounded,
                      size: 16, color: AppColors.error),
                  const SizedBox(width: 10),
                  Text('Remove',
                      style: AppTextStyles.bodyMedium
                          .copyWith(color: AppColors.error)),
                ]),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Empty / Error states
// ─────────────────────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyState({required this.onAdd});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Icon(Icons.location_off_rounded,
                    size: 34, color: AppColors.textTertiary),
              ),
              const SizedBox(height: 16),
              const Text('No saved places', style: AppTextStyles.heading4),
              const SizedBox(height: 6),
              const Text(
                'Save your home, office or frequent destinations for faster booking',
                style: AppTextStyles.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              GestureDetector(
                onTap: onAdd,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 28, vertical: 13),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text('Add a place', style: AppTextStyles.button),
                ),
              ),
            ],
          ),
        ),
      );
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.cloud_off_rounded,
                  size: 40, color: AppColors.textTertiary),
              const SizedBox(height: 12),
              const Text('Could not load saved places',
                  style: AppTextStyles.heading4),
              const SizedBox(height: 6),
              Text(message,
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textSecondary),
                  textAlign: TextAlign.center),
              const SizedBox(height: 20),
              GestureDetector(
                onTap: onRetry,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text('Retry', style: AppTextStyles.button),
                ),
              ),
            ],
          ),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared field widget
// ─────────────────────────────────────────────────────────────────────────────

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData? icon;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;

  const _Field({
    required this.controller,
    required this.hint,
    this.icon,
    this.focusNode,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.border),
        ),
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          onChanged: onChanged,
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
