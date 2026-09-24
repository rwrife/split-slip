# Your data in Split Slip

Split Slip stores receipt drafts, participant nicknames, item amounts, assignments, finalized splits, and optional reference photos locally on your device. It has no account, server, analytics, advertising, bank connection, or payment processing.

Photos are optional. The system Photos picker provides only the image you select. Split Slip decodes and re-encodes that image, applies its orientation, removes metadata, and stores a bounded private JPEG. It does not request broad photo-library, camera, contacts, location, or microphone access.

Sharing is your choice. A preview lets you choose everyone or one participant, and text or CSV. Shared summaries contain names, items, and amounts, but no reference photos or internal receipt identifiers. Nothing is sent automatically. The app or person you choose in the system share sheet controls their copy afterward.

A private backup folder contains receipt JSON, a version manifest, and optional sanitized photos. It is not encrypted separately by Split Slip. Keep the entire folder private. A Files provider may upload exported files to its cloud service. Local app data may also be included in iCloud or computer device backups according to your system settings.

Restore validates a backup before offering to replace the local library. It keeps a private copy of the previous library under **Your data**, where you can export that recovery copy. Interrupted restores are recovered on launch before receipts open. Restore replaces rather than merges; workspace selection and photo viewport preferences reset after a successful restore.

Deleting a receipt removes its owned photo and clears local recovery backups, which may contain that receipt. **Delete all local data** removes receipts, owned reference photos, workspace preferences, and local recovery backups. Deletion cannot recall copies you exported or erase OS device backups.

Split Slip is an arithmetic organizer. It does not move money, prove payment, determine tax obligations, or verify that you entered a receipt correctly. Review your inputs and shared totals.
