# Storage compatibility

On September 21, 2026, Ali Ajam confirmed that neither published 0.1.0 mobile
SDK has customer installations. The release owner therefore approved retiring
the unused preview import path without a customer adoption window.

This candidate creates an independent ELU-owned installation. It does not
import identity, consent, properties, groups, flags, or queued records from the
previous 0.1.0 runtime, and it does not open, rewrite, or delete that runtime's
files. Applications should call `Elu.identify` after restoring their own login
state and apply their current consent choice through the public consent APIs.

Supported owned SQLite schemas 1 through 16 and 25 through 32 upgrade to schemas
33 through 40.
Schemas 9 through 16 already contain installation capture-session history; the
25–32 family additionally stores bounded native diagnostics continuity and
receipt deduplication. Upgrades from older families start diagnostics coverage
closed and do not import older OS intervals. The 33–40 family adds a bounded,
stream-bound singleton for independent device identity and profile processing. Reopen, transaction recovery,
identity, consent, offline queue, flags, and replay records remain preserved.
Old SQLite and imported owned JSON stores cannot prove complete first-session
history. They remain eligible for ordinary analytics and all-device replay,
but do not qualify when remote policy restricts replay to new devices. New
installations record their first successfully committed capture session even
when replay is disabled; identify, reset, and consent changes never clear it. The existing owned JSON state importer remains supported
within that same site-scoped storage namespace; its source is read-only.

A fresh installation uses its initial anonymous ID as its independent device ID.
When upgrading a supported store without device metadata, its current anonymous
ID becomes the device ID. No historical device ID can be recovered after an
older reset. Anonymous historical person-processing intent is likewise unknown:
flag evaluation properties, queued payloads, and customer `$epp` values are not
proof. Upgrades initialize the sticky processing marker to false; an existing
identified user or group still enables processing under `.identifiedOnly`.
Subsequent accepted person mutations/events persist the decision atomically.
Ordinary reset preserves the device ID; explicit device reset rotates it in the
same transaction as the new anonymous identity. Neither form resets consent,
queued records, stream sequence/acknowledgement integrity, or installation
capture-session history.

Unpublished transition SQLite schemas 17 through 24, which carried preview
import receipts, are unsupported. They fail closed before writable database
opening and preserve the database, WAL, and SHM bytes. Other unknown schema
versions and malformed stores likewise never authorize destructive recovery.
Reset is an analytics identity operation, not permission to erase an
unsupported database.

The original public source API baseline, release tag/archive digests, and
historical evidence definitions are retained for provenance. They do not make
the retired preview continuity runner a current release gate. Current gates
cover clean installation, supported owned-store upgrades, unsupported-store
refusal, no-touch behavior, and the full SDK Lab delivery and rendering checks.
