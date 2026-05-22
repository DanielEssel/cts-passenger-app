// lib/features/profile/presentation/screens/edit_profile_screen.dart

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_text_styles.dart';
import '../../../../widgets/common/shared_widgets.dart';
import '../../auth/providers/auth_providers.dart';
import 'profile_screen.dart'; // for _AvatarWidget + userStreamProvider

class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key});

  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  final _formKey    = GlobalKey<FormState>();
  final _firstCtrl  = TextEditingController();
  final _lastCtrl   = TextEditingController();
  final _emailCtrl  = TextEditingController();

  bool    _isSaving       = false;
  bool    _isUploadingPhoto = false;
  File?   _pickedImage;
  bool    _hasEmail       = false; // only show email field if doc has it
  bool    _loaded         = false;

  @override
  void dispose() {
    _firstCtrl.dispose();
    _lastCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  // ── Seed form from Firestore once ─────────────────────────────────────────

  void _seedFromUser(UserData user) {
    if (_loaded) return;
    _loaded = true;
    _firstCtrl.text = user.firstName ?? '';
    _lastCtrl.text  = user.lastName  ?? '';
    _emailCtrl.text = user.email     ?? '';
    _hasEmail = user.email != null && user.email!.isNotEmpty;
  }

  // ── Photo picker ──────────────────────────────────────────────────────────

  Future<void> _pickPhoto(ImageSource source) async {
    Navigator.pop(context); // close bottom sheet
    final picker = ImagePicker();
    final file   = await picker.pickImage(
      source: source,
      imageQuality: 75,
      maxWidth: 512,
      maxHeight: 512,
    );
    if (file == null || !mounted) return;
    setState(() => _pickedImage = File(file.path));
  }

  Future<String?> _uploadPhoto(String uid) async {
    if (_pickedImage == null) return null;
    setState(() => _isUploadingPhoto = true);
    try {
      final ref = FirebaseStorage.instance
          .ref()
          .child('profile_photos/$uid.jpg');
      await ref.putFile(
        _pickedImage!,
        SettableMetadata(contentType: 'image/jpeg'),
      );
      return await ref.getDownloadURL();
    } catch (e) {
      _showError('Photo upload failed: $e');
      return null;
    } finally {
      if (mounted) setState(() => _isUploadingPhoto = false);
    }
  }

  void _showPhotoPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Text('Change photo', style: AppTextStyles.heading4),
              const SizedBox(height: 16),
              _PhotoOption(
                icon: Icons.camera_alt_rounded,
                label: 'Take a photo',
                onTap: () => _pickPhoto(ImageSource.camera),
              ),
              const SizedBox(height: 10),
              _PhotoOption(
                icon: Icons.photo_library_rounded,
                label: 'Choose from gallery',
                onTap: () => _pickPhoto(ImageSource.gallery),
              ),
              if (_pickedImage != null || _currentPhotoURL != null) ...[
                const SizedBox(height: 10),
                _PhotoOption(
                  icon: Icons.delete_outline_rounded,
                  label: 'Remove photo',
                  color: AppColors.error,
                  onTap: () {
                    Navigator.pop(context);
                    setState(() => _pickedImage = null);
                    _removePhoto();
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String? _currentPhotoURL;

  Future<void> _removePhoto() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .update({'photoURL': FieldValue.delete()});
      await FirebaseAuth.instance.currentUser?.updatePhotoURL(null);
      // Delete from storage
      await FirebaseStorage.instance
          .ref()
          .child('profile_photos/$uid.jpg')
          .delete();
    } catch (_) {
      // File may not exist in storage — ignore
    }
  }

  // ── Save ──────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    setState(() => _isSaving = true);

    try {
      // Upload photo if changed
      final newPhotoURL = await _uploadPhoto(uid);

      final firstName   = _firstCtrl.text.trim();
      final lastName    = _lastCtrl.text.trim();
      final displayName = '$firstName $lastName'.trim();

      final updates = <String, dynamic>{
        'firstName':   firstName,
        'lastName':    lastName,
        'displayName': displayName,
        'updatedAt':   FieldValue.serverTimestamp(),
      };

      if (_hasEmail) {
        final email = _emailCtrl.text.trim();
        if (email.isNotEmpty) updates['email'] = email;
      }

      if (newPhotoURL != null) {
        updates['photoURL'] = newPhotoURL;
        await FirebaseAuth.instance.currentUser
            ?.updatePhotoURL(newPhotoURL);
      }

      await FirebaseAuth.instance.currentUser
          ?.updateDisplayName(displayName);

      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .update(updates);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(children: [
            Icon(Icons.check_circle_rounded,
                color: Colors.white, size: 18),
            SizedBox(width: 8),
            Text('Profile updated'),
          ]),
          backgroundColor: AppColors.success,
        ),
      );
      Navigator.pop(context);
    } catch (e) {
      _showError('Failed to save: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: AppColors.error),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final userAsync = ref.watch(userStreamProvider);

    return userAsync.when(
      loading: () => const Scaffold(
        backgroundColor: AppColors.background,
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        backgroundColor: AppColors.background,
        appBar: const CTSRideAppBar(title: 'Edit Profile'),
        body: Center(child: Text('Error: $e')),
      ),
      data: (user) {
        if (user != null) {
          _seedFromUser(user);
          _currentPhotoURL = user.photoURL;
        }

        final phone = user?.phoneNumber ??
            ref.read(userPhoneProvider) ?? '';

        return Scaffold(
          backgroundColor: AppColors.background,
          appBar: const CTSRideAppBar(title: 'Edit Profile'),
          body: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.all(20),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Avatar ──
                  Center(
                    child: Stack(
                      children: [
                        GestureDetector(
                          onTap: _showPhotoPicker,
                          child: _pickedImage != null
                              ? CircleAvatar(
                                  radius: 48,
                                  backgroundImage:
                                      FileImage(_pickedImage!),
                                )
                              : AvatarWidget(
                                  photoURL: user?.photoURL,
                                  displayName: user?.displayName ??
                                      '${_firstCtrl.text} ${_lastCtrl.text}',
                                  radius: 48,
                                ),
                        ),
                        if (_isUploadingPhoto)
                          Positioned.fill(
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.black45,
                                shape: BoxShape.circle,
                              ),
                              child: const Center(
                                child: CircularProgressIndicator(
                                    color: Colors.white, strokeWidth: 2),
                              ),
                            ),
                          ),
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: GestureDetector(
                            onTap: _showPhotoPicker,
                            child: Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: AppColors.primary,
                                shape: BoxShape.circle,
                                border: Border.all(
                                    color: AppColors.background,
                                    width: 2),
                              ),
                              child: const Icon(Icons.camera_alt_rounded,
                                  size: 15, color: Colors.white),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Center(
                    child: Text('Tap to change photo',
                        style: AppTextStyles.caption
                            .copyWith(color: AppColors.primary)),
                  ),

                  const SizedBox(height: 28),

                  // ── First name ──
                  _label('First name'),
                  const SizedBox(height: 8),
                  _buildField(
                    controller: _firstCtrl,
                    hint: 'First name',
                    icon: Icons.person_rounded,
                    validator: (v) => v == null || v.trim().isEmpty
                        ? 'First name is required'
                        : null,
                  ),
                  const SizedBox(height: 14),

                  // ── Last name ──
                  _label('Last name'),
                  const SizedBox(height: 8),
                  _buildField(
                    controller: _lastCtrl,
                    hint: 'Last name',
                    icon: Icons.person_outline_rounded,
                    validator: (v) => v == null || v.trim().isEmpty
                        ? 'Last name is required'
                        : null,
                  ),
                  const SizedBox(height: 14),

                  // ── Email — only shown if in Firestore doc ──
                  if (_hasEmail) ...[
                    _label('Email address'),
                    const SizedBox(height: 8),
                    _buildField(
                      controller: _emailCtrl,
                      hint: 'Email address',
                      icon: Icons.email_rounded,
                      keyboardType: TextInputType.emailAddress,
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) return null;
                        if (!v.contains('@') || !v.contains('.')) {
                          return 'Enter a valid email';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 14),
                  ],

                  // ── Phone — always read-only ──
                  _label('Phone number'),
                  const SizedBox(height: 8),
                  _buildField(
                    controller: TextEditingController(text: phone),
                    hint: 'Phone number',
                    icon: Icons.phone_rounded,
                    readOnly: true,
                    trailingWidget: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppColors.success.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text('Verified',
                          style: AppTextStyles.caption.copyWith(
                              color: AppColors.success,
                              fontWeight: FontWeight.w600)),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Phone number is linked to your account and cannot be changed here.',
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.textTertiary),
                  ),

                  const SizedBox(height: 32),

                  PrimaryButton(
                    label: 'Save changes',
                    isLoading: _isSaving || _isUploadingPhoto,
                    onTap: _save,
                  ),

                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _label(String text) =>
      Text(text, style: AppTextStyles.labelLarge);

  Widget _buildField({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
    bool readOnly = false,
    Widget? trailingWidget,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      readOnly: readOnly,
      validator: validator,
      style: AppTextStyles.bodyMedium,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle:
            AppTextStyles.bodySmall.copyWith(color: AppColors.textTertiary),
        prefixIcon: Icon(icon, color: AppColors.textSecondary, size: 18),
        suffixIcon: trailingWidget != null
            ? Padding(
                padding: const EdgeInsets.only(right: 10),
                child: trailingWidget,
              )
            : null,
        suffixIconConstraints:
            const BoxConstraints(minWidth: 0, minHeight: 0),
        filled: true,
        fillColor: readOnly ? AppColors.surfaceAlt : AppColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide:
              const BorderSide(color: AppColors.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.error, width: 1.5),
        ),
      ),
    );
  }
}

// ── Photo option tile ─────────────────────────────────────────────────────────

class _PhotoOption extends StatelessWidget {
  final IconData     icon;
  final String       label;
  final VoidCallback onTap;
  final Color        color;

  const _PhotoOption({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color = AppColors.textPrimary,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          decoration: BoxDecoration(
            color: AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 12),
              Text(label,
                  style:
                      AppTextStyles.bodyMedium.copyWith(color: color)),
            ],
          ),
        ),
      );
}