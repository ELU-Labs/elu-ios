# Storage compatibility

On September 21, 2026, Ali Ajam confirmed that neither published 0.1.0 mobile
SDK has customer installations. The release owner therefore approved retiring
the unused preview import path without a customer adoption window.

This candidate creates an independent ELU-owned installation. It does not
import identity, consent, properties, groups, flags, or queued records from the
previous 0.1.0 runtime, and it does not open, rewrite, or delete that runtime's
files. Applications should call `Elu.identify` after restoring their own login
state and apply their current consent choice through the public consent APIs.

Supported owned SQLite schemas 1 through 8 retain their existing reopen,
transaction recovery, identity, consent, offline queue, flag, and replay schema
upgrade behavior. The existing owned JSON state importer remains supported
within that same site-scoped storage namespace; its source is read-only.

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
