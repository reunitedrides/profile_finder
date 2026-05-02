const functions = require('firebase-functions/v2');
const admin = require('firebase-admin');

admin.initializeApp();

// ================================================================
// Cloud Function: sendNewProfileNotification
// Triggers when admin adds a doc to 'notifications' collection
// Fans out to all registered user FCM tokens
// ================================================================

exports.sendNewProfileNotification = functions.firestore.onDocumentCreated(
  { document: 'notifications/{notificationId}', region: 'europe-west2' },
  async (event) => {
    const data = event.data?.data();
    if (!data) return;

    const title = data.title ?? 'New Roof Profile Added!';
    const body  = data.body  ?? 'A new profile has been added to the app.';

    // Get all user FCM tokens from Firestore
    const usersSnap = await admin.firestore().collection('users').get();

    const tokens = [];
    usersSnap.forEach(doc => {
      const token = doc.data().fcmToken;
      if (token) tokens.push(token);
    });

    if (tokens.length === 0) {
      console.log('No FCM tokens found - no notifications sent.');
      return;
    }

    console.log(`Sending notification to ${tokens.length} devices...`);

    // Send in batches of 500 (FCM limit)
    const batchSize = 500;
    for (let i = 0; i < tokens.length; i += batchSize) {
      const batch = tokens.slice(i, i + batchSize);
      const message = {
        notification: { title, body },
        android: {
          notification: {
            icon: 'ic_launcher',
            color: '#1565C0',
            sound: 'default',
          },
        },
        apns: {
          payload: {
            aps: {
              sound: 'default',
              badge: 1,
            },
          },
        },
        tokens: batch,
      };

      const response = await admin.messaging().sendEachForMulticast(message);
      console.log(`Batch ${i / batchSize + 1}: ${response.successCount} sent, ${response.failureCount} failed`);

      // Clean up invalid tokens
      const toDelete = [];
      response.responses.forEach((r, idx) => {
        if (!r.success &&
            (r.error?.code === 'messaging/invalid-registration-token' ||
             r.error?.code === 'messaging/registration-token-not-registered')) {
          toDelete.push(batch[idx]);
        }
      });

      // Remove stale tokens from Firestore
      if (toDelete.length > 0) {
        const deleteSnap = await admin.firestore().collection('users')
          .where('fcmToken', 'in', toDelete).get();
        const deletePromises = deleteSnap.docs.map(doc =>
          doc.ref.update({ fcmToken: admin.firestore.FieldValue.delete() })
        );
        await Promise.all(deletePromises);
        console.log(`Cleaned up ${toDelete.length} stale tokens`);
      }
    }
  }
);
