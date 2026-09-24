export * from "@actual/source/server/cloud-storage.ts";

import { getPrefs } from "@actual/prefs";
import { upload } from "@actual/source/server/cloud-storage.ts";
import { addDays, currentDay } from "@actual/source/shared/months.ts";

// The upstream load hook starts a background upload and suppresses its errors.
// Native owns launch/edit sync and awaits errors, so loading a local file
// must never start an untracked upload.
export async function possiblyUpload() {}

export async function uploadSnapshotIfDue() {
  const { cloudFileId, groupId, lastUploaded } = getPrefs();
  if (!cloudFileId || !groupId) return;
  // Match the pinned engine's seven-day snapshot interval. Await the upload so
  // it stays within tracked sync, but, like upstream, never fail sync over it:
  // changes already synced, and lastUploaded only advances on success, so the
  // next due sync retries.
  if (!lastUploaded || currentDay() >= addDays(lastUploaded, 7)) {
    try {
      await upload();
    } catch (error) {
      // Upstream throws FileUploadError as a plain object.
      const detail = error instanceof Error ? error.message : JSON.stringify(error);
      console.warn("Budget snapshot upload failed; will retry on a later sync.", detail);
    }
  }
}
