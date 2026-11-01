// Auth logs keep an error's type and Firebase code, never its message: a
// Firestore message can carry a document path with the user's UID.

import 'package:cts_transport_app/core/logging/auth_log.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Firebase errors keep plugin and code only', () {
    final error = FirebaseException(
      plugin: 'cloud_firestore',
      code: 'not-found',
      message: 'No document to update: projects/p/databases/(default)/'
          'documents/users/uid-SECRET-123',
    );
    expect(describeError(error), 'cloud_firestore/not-found');
    expect(describeError(error), isNot(contains('uid-SECRET-123')));
  });

  test('other errors keep their type only', () {
    expect(describeError(StateError('phone +233244123456')), 'StateError');
  });
}
