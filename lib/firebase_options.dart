// File generated manually from Firebase config files
// google-services.json + GoogleService-Info.plist

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyAAeDOAbGKbRI3G57kJXSw-V0feMCQ0LSY',
    appId: '1:899172571973:web:roof-profile-finder',
    messagingSenderId: '899172571973',
    projectId: 'roof-profile-finder-ef05e',
    storageBucket: 'roof-profile-finder-ef05e.firebasestorage.app',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyDd_MBdT62wOUAschJgB7PNeGvPACKImn8',
    appId: '1:899172571973:android:2e1b3e85221dcfe97dbc2c',
    messagingSenderId: '899172571973',
    projectId: 'roof-profile-finder-ef05e',
    storageBucket: 'roof-profile-finder-ef05e.firebasestorage.app',
    androidClientId: '899172571973-m520kbun1o8aup8f0f1brqdbcq0i9s3c.apps.googleusercontent.com',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyAAeDOAbGKbRI3G57kJXSw-V0feMCQ0LSY',
    appId: '1:899172571973:ios:c2e7fc0165ae98927dbc2c',
    messagingSenderId: '899172571973',
    projectId: 'roof-profile-finder-ef05e',
    storageBucket: 'roof-profile-finder-ef05e.firebasestorage.app',
    iosClientId: '899172571973-b5lc827jfa1fr5r01hiv1v69h9gmm0jv.apps.googleusercontent.com',
    iosBundleId: 'com.marksamazingapps.profilefinder',
  );
}
