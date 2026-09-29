import 'package:flutter/material.dart';

import 'app_update_service.dart';

class UpdateRequiredDialog {
  const UpdateRequiredDialog._();

  static Future<void> show(
    BuildContext context,
    AppUpdateInfo info,
  ) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(info.title),
          content: Text(info.message),
          actions: [
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () async {
                  await AppUpdateService.openStore(info.storeUrl);
                },
                child: const Text('Update Now'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
