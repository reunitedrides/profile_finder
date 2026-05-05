const { onDocumentCreated } = require('firebase-functions/v2/firestore');
const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { defineSecret } = require('firebase-functions/params');
const admin = require('firebase-admin');
const nodemailer = require('nodemailer');

admin.initializeApp();

const EMAIL_PASSWORD = defineSecret('EMAIL_PASSWORD');
const ADMIN_EMAIL = 'marksjones73@gmail.com';

// ── Email when correction/photo submitted ─────────────────────
exports.onCorrectionSubmitted = onDocumentCreated(
  { document: 'image_corrections/{id}', region: 'europe-west2', secrets: [EMAIL_PASSWORD] },
  async (event) => {
    const data = event.data?.data();
    if (!data) return null;

    const id     = event.params.id;
    const type   = data.type === 'sheet_photo' ? 'New Photo Submission' : 'Correction Report';
    const name   = data.profileName ?? data.originalName ?? 'Unknown';
    const mfr    = data.manufacturer ?? data.originalMfr ?? '';
    const by     = data.submittedBy ?? 'anonymous';
    const notes  = data.notes ?? data.correctedName ?? '';
    const photoUrl = data.photoUrl ?? null;

    const photoHtml = photoUrl
      ? `<p><strong>Photo:</strong> <a href="${photoUrl}" style="color:#1565C0">Click to view photo</a></p>
         <img src="${photoUrl}" style="max-width:400px;border-radius:8px;margin-top:8px;" />`
      : '<p><strong>Photo:</strong> None submitted</p>';

    const correctionHtml = data.type === 'correction' ? `
      <p><strong>Corrected name:</strong> ${data.correctedName ?? '-'}</p>
      <p><strong>Corrected manufacturer:</strong> ${data.correctedMfr ?? '-'}</p>` : '';

    const transporter = nodemailer.createTransport({
      service: 'gmail',
      auth: {
        user: ADMIN_EMAIL,
        pass: EMAIL_PASSWORD.value(),
      },
    });

    try {
      await transporter.sendMail({
        from: `Roof Profile App <${ADMIN_EMAIL}>`,
        to: ADMIN_EMAIL,
        subject: `[Roof App] ${type}: ${name}`,
        html: `
          <div style="font-family:Arial,sans-serif;max-width:600px;padding:20px;">
            <h2 style="color:#1565C0;margin-bottom:4px;">Roof Profile Finder</h2>
            <h3 style="color:#333;margin-top:0;">${type}</h3>
            <hr style="border:1px solid #eee;"/>
            <p><strong>Profile:</strong> ${name}</p>
            <p><strong>Manufacturer:</strong> ${mfr}</p>
            <p><strong>Submitted by:</strong> ${by}</p>
            <p><strong>Notes:</strong> ${notes || 'None'}</p>
            ${correctionHtml}
            ${photoHtml}
            <hr style="border:1px solid #eee;margin-top:20px;"/>
            <p style="color:#888;font-size:12px;">
              ID: ${id}<br/>
              Review in app: tap title 5x → PIN 7950 → Corrections tab
            </p>
          </div>`,
      });
      console.log(`Email sent for ${id}`);
    } catch (err) {
      console.error('Email failed:', err.message);
    }
    return null;
  }
);

// ── Push notifications for new profiles ───────────────────────
exports.sendNewProfileNotification = onDocumentCreated(
  { document: 'notifications/{id}', region: 'europe-west2' },
  async (event) => {
    const data = event.data?.data();
    if (!data) return null;

    const title = data.title ?? 'New Roof Profile Added!';
    const body  = data.body  ?? 'A new profile has been added to the app.';

    const usersSnap = await admin.firestore().collection('users').get();
    const tokens = [];
    usersSnap.forEach(doc => {
      const t = doc.data().fcmToken;
      if (t) tokens.push(t);
    });

    if (!tokens.length) return null;

    for (let i = 0; i < tokens.length; i += 500) {
      const batch = tokens.slice(i, i + 500);
      const resp = await admin.messaging().sendEachForMulticast({
        notification: { title, body },
        android: { notification: { icon: 'ic_launcher', color: '#1565C0', sound: 'default' } },
        apns: { payload: { aps: { sound: 'default', badge: 1 } } },
        tokens: batch,
      });

      const stale = resp.responses
        .map((r, idx) => (!r.success &&
          (r.error?.code === 'messaging/invalid-registration-token' ||
           r.error?.code === 'messaging/registration-token-not-registered'))
          ? batch[idx] : null)
        .filter(Boolean);

      if (stale.length) {
        const snap = await admin.firestore().collection('users')
          .where('fcmToken', 'in', stale).get();
        await Promise.all(snap.docs.map(d =>
          d.ref.update({ fcmToken: admin.firestore.FieldValue.delete() })));
      }
    }
    return null;
  }
);

// ── Approve correction ─────────────────────────────────────────
exports.approveCorrection = onCall(
  { region: 'europe-west2' },
  async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'Must be logged in');
    const { correctionId } = request.data;

    const docRef = admin.firestore().collection('image_corrections').doc(correctionId);
    const doc = await docRef.get();
    if (!doc.exists) throw new HttpsError('not-found', 'Correction not found');
    const data = doc.data();

    // Mark as approved
    await docRef.update({
      status: 'approved',
      reviewedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    // For photo submissions (sheet or tile), persist photoUrl to profile_photos
    const isPhotoSubmission = data.type === 'sheet_photo' || data.type === 'tile_photo';
    if (isPhotoSubmission && data.photoUrl) {
      const profileName = (data.profileName ?? data.originalName ?? '').trim();
      const manufacturer = (data.manufacturer ?? data.originalMfr ?? '').trim();

      if (profileName) {
        const key = `${profileName}_${manufacturer}`
          .toLowerCase()
          .replace(/[^a-z0-9]+/g, '_')
          .replace(/^_+|_+$/g, '');

        await admin.firestore().collection('profile_photos').doc(key).set({
          profileName,
          manufacturer,
          photoUrl: data.photoUrl,
          category: data.type === 'tile_photo' ? 'tile' : 'sheet',
          approvedAt: admin.firestore.FieldValue.serverTimestamp(),
          correctionId,
          submittedBy: data.submittedBy ?? '',
          uid: data.uid ?? '',
        }, { merge: true });
      }
    }

    return { success: true };
  }
);

// ── Delete user photos on account deletion ─────────────────────
exports.deleteUserPhotos = onCall(
  { region: 'europe-west2' },
  async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'Must be logged in');
    const uid = request.auth.uid;

    // Delete from profile_photos collection
    const photoSnap = await admin.firestore().collection('profile_photos')
      .where('uid', '==', uid).get();
    for (const doc of photoSnap.docs) {
      const photoUrl = doc.data().photoUrl;
      if (photoUrl) {
        try {
          const path = decodeURIComponent(photoUrl.split('/o/')[1].split('?')[0]);
          await admin.storage().bucket().file(path).delete();
        } catch (e) {
          console.log('Storage delete skipped:', e.message);
        }
      }
      await doc.ref.delete();
    }

    return { deleted: photoSnap.size };
  }
);

// ── Reject correction ──────────────────────────────────────────
exports.rejectCorrection = onCall(
  { region: 'europe-west2' },
  async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'Must be logged in');
    const { correctionId } = request.data;
    const doc = await admin.firestore().collection('image_corrections').doc(correctionId).get();
    const photoUrl = doc.data()?.photoUrl;
    if (photoUrl) {
      try {
        const path = decodeURIComponent(photoUrl.split('/o/')[1].split('?')[0]);
        await admin.storage().bucket().file(path).delete();
      } catch (e) {
        console.log('Photo delete skipped:', e.message);
      }
    }
    await admin.firestore().collection('image_corrections').doc(correctionId).update({
      status: 'rejected',
      reviewedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return { success: true };
  }
);
