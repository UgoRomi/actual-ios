export * from "@actual/source/server/cloud-storage.ts";

import { getPrefs } from "@actual/prefs";
import { upload } from "@actual/source/server/cloud-storage.ts";
import { addDays, currentDay } from "@actual/source/shared/months.ts";

// The upstream load hook starts a background upload and suppresses its errors.
// Native sync is explicit, so loading a local file must never start that work.
export async function possiblyUpload() {}

export async function uploadSnapshotIfDue() {
  const { cloudFileId, groupId, lastUploaded } = getPrefs();
  if (!cloudFileId || !groupId) return;
  // Match the pinned engine's seven-day snapshot interval, but await failures.
  if (!lastUploaded || currentDay() >= addDays(lastUploaded, 7)) await upload();
}
