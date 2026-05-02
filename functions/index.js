const functions = require('firebase-functions/v2');
const admin = require('firebase-admin');
const nodemailer = require('nodemailer');

admin.initializeApp();

// ═══════════════════════════════════════════════════════════════
// Email transporter using Gmail + App Password from .env
// ═══════════════════════════════════════════════════════════════
const transporter = nodemailer.createTransport({
  service: 'gmail',
  auth: {
    user: 'marksjones73@gmail.com',
    pass: process.env.EMAIL_PASSWORD,
  },
});

// ═══════════════════════════════════════════════════════════════
// Notify admin when a new image correction is submitted
// ═══════════════════════════════════════════════════════════════
exports.onCorrectionSubmitted = functions.firestore.onDocumentCreated(
  { document: 'image_corrections/{correctionId}', region: 'europe-west2' },
  async (event) => {
    const data = event.data?.data();
    if (!data) return;

    const correctionId = event.params.correctionId;
    const type        = data.type === 'sheet_photo' ? 'New Sheet Photo' : 'Correction Report';
    const profileName = data.profileName ?? data.originalName ?? 'Unknown';
    const manufacturer = data.manufacturer ?? data.originalMfr ?? 'Unknown';
    const submittedBy = data.submittedBy ?? 'anonymous';
    const notes       = data.notes ?? data.correctedName ?? '';
    const photoUrl    = data.photoUrl ?? null;
    const correctedName = data.correctedName ?? '';
    const correctedMfr  = data.correctedMfr ?? '';

    const photoSection = photoUrl
      ? `<p><strong>Photo:</strong> <a href="${photoUrl}">Click to view submitted photo</a></p>`
      : '<p><strong>Photo:</strong> None submitted</p>';

    const correctionSection = data.type === 'correction' ? `
      <p><strong>Corrected name:</strong> ${correctedName}</p>
      <p><strong>Corrected manufacturer:</strong> ${correctedMfr}</p>
    ` : '';

    const mailOptions = {
      from: 'Roof Profile Finder <marksjones73@gmail.com>',
      to: 'marksjones73@gmail.com',
      subject: `[Roof App] ${type}: ${profileName}`,
      html: `
        <div style="font-family: Arial, sans-serif; max-width: 600px; padding: 20px;">
          <h2 style="color: #1565C0;">Roof Profile Finder — ${type}</h2>
          <hr/>
          <p><strong>Profile:</strong> ${profileName}</p>
          <p><strong>Manufacturer:</strong> ${manufacturer}</p>
          <p><strong>Submitted by:</strong> ${submittedBy}</p>
          <p><strong>Notes:</strong> ${notes || 'None'}</p>
          ${correctionSection}
          ${photoSection}
          <hr/>
          <p style="color: #666; font-size: 12px;">
            Correction ID: ${correctionId}<br/>
            Review in your app admin screen (tap title 5 times, PIN: 7950) 
            under "Pending Corrections"
          </p>
        </div>
      `,
    };

    try {
      await transporter.sendMail(mailOptions);
      console.log(`Email sent for correction: ${correctionId}`);
    } catch (err) {
      console.error('Email send failed:', err);
    }
  }
);

// ═══════════════════════════════════════════════════════════════
// Notify admin when a new profile is uploaded via admin screen
// ═══════════════════════════════════════════════════════════════
exports.sendNewProfileNotification = functions.firestore.onDocumentCreated(
  { document: 'notifications/{notificationId}', region: 'europe-west2' },
  async (event) => {
    const data = event.data?.data();
    if (!data) return;

    const title = data.title ?? 'New Roof Profile Added!';
    const body  = data.body  ?? 'A new profile has been added to the app.';

    const usersSnap = await admin.firestore().collection('users').get();
    const tokens = [];
    usersSnap.forEach(doc => {
      const token = doc.data().fcmToken;
      if (token) tokens.push(token);
    });

    if (tokens.length === 0) {
      console.log('No FCM tokens found.');
      return;
    }

    const batchSize = 500;
    for (let i = 0; i < tokens.length; i += batchSize) {
      const batch = tokens.slice(i, i + batchSize);
      const message = {
        notification: { title, body },
        android: { notification: { icon: 'ic_launcher', color: '#1565C0', sound: 'default' } },
        apns: { payload: { aps: { sound: 'default', badge: 1 } } },
        tokens: batch,
      };
      const response = await admin.messaging().sendEachForMulticast(message);
      console.log(`Sent: ${response.successCount}, Failed: ${response.failureCount}`);

      const toDelete = [];
      response.responses.forEach((r, idx) => {
        if (!r.success &&
          (r.error?.code === 'messaging/invalid-registration-token' ||
           r.error?.code === 'messaging/registration-token-not-registered')) {
          toDelete.push(batch[idx]);
        }
      });

      if (toDelete.length > 0) {
        const deleteSnap = await admin.firestore().collection('users')
          .where('fcmToken', 'in', toDelete).get();
        await Promise.all(deleteSnap.docs.map(doc =>
          doc.ref.update({ fcmToken: admin.firestore.FieldValue.delete() })
        ));
      }
    }
  }
);

// ═══════════════════════════════════════════════════════════════
// Approve a correction — marks as approved in Firestore
// ═══════════════════════════════════════════════════════════════
exports.approveCorrection = functions.https.onCall(
  { region: 'europe-west2' },
  async (request) => {
    if (!request.auth) throw new functions.https.HttpsError('unauthenticated', 'Must be logged in');
    const { correctionId } = request.data;
    if (!correctionId) throw new functions.https.HttpsError('invalid-argument', 'correctionId required');

    await admin.firestore().collection('image_corrections').doc(correctionId).update({
      status: 'approved',
      reviewedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return { success: true };
  }
);

// ═══════════════════════════════════════════════════════════════
// Reject a correction — marks as rejected and deletes photo
// ═══════════════════════════════════════════════════════════════
exports.rejectCorrection = functions.https.onCall(
  { region: 'europe-west2' },
  async (request) => {
    if (!request.auth) throw new functions.https.HttpsError('unauthenticated', 'Must be logged in');
    const { correctionId } = request.data;
    if (!correctionId) throw new functions.https.HttpsError('invalid-argument', 'correctionId required');

    const doc = await admin.firestore().collection('image_corrections').doc(correctionId).get();
    const data = doc.data();

    if (data?.photoUrl) {
      try {
        const photoRef = admin.storage().bucket().file(
          decodeURIComponent(data.photoUrl.split('/o/')[1].split('?')[0])
        );
        await photoRef.delete();
      } catch (e) {
        console.log('Photo delete failed (may already be gone):', e.message);
      }
    }

    await admin.firestore().collection('image_corrections').doc(correctionId).update({
      status: 'rejected',
      reviewedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return { success: true };
  }
);
