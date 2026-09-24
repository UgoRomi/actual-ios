export * from "@actual/source/server/budgetfiles/backups.ts";

// Actual's desktop backup service copies the budget every 15 minutes and keeps
// up to ten copies. Actual's web and mobile apps do not run it, and this app
// offers no way to restore them, so it would only consume storage.
export function startBackupService() {}
