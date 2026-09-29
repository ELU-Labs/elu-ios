# Storage compatibility

On September 21, 2026, Ali Ajam confirmed that neither published 0.1.0 mobile
SDK has customer installations. The release owner therefore approved retiring
the unused preview import path without a customer adoption window.

This candidate creates an independent ELU-owned installation. It does not
import identity, consent, properties, groups, flags, or queued records from the
previous 0.1.0 runtime, and it does not open, rewrite, or delete that runtime's
files. Applications should call `Elu.identify` after restoring their own login
state and apply their current consent choice through the public consent APIs.

Supported owned SQLite schemas 1 through 16 and 25 through 40 upgrade to schemas
41 through 48.
Schemas 9 through 16 already contain installation capture-session history; the
25–32 family additionally stores bounded native diagnostics continuity and
receipt deduplication. Upgrades from older families start diagnostics coverage
closed and do not import older OS intervals. The 33–40 family adds a bounded,
stream-bound singleton for independent device identity and profile processing. The 41–48
family additionally stores the anonymous visitor's exposure ledger in a separate
stream-bound singleton (at most 4,096 SHA-256 entries and 300,000 encoded bytes).
Older stores start with an empty exposure ledger: queue fragments and a retained
flag cache cannot reconstruct prior accepted reports. This may permit one new
report for a previously seen value after upgrade. Subsequent event/ledger writes
and reset/ledger clearing are atomic; ordinary ACK, consent and identify preserve
history. Saturation suppresses new exposure events until reset, not flag reads.
These logical metadata bounds are not a bound on allocated SQLite/WAL bytes.
 Reopen, transaction recovery,
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

`.persistent` remains the default. `.memory` starts a fresh `:memory:` SQLite
database using the same schema 41–48 and ordinary queue transactions, with
memory-only journals and SQLite temporary storage. It never opens or imports
an existing analytics database or its sidecars. Closing that owner or ending
the process drops its analytics identity, queues, cache, first-session history,
exposure ledger and diagnostic continuity. Historical OS intervals consequently
cannot be attributed across memory-mode restarts. Switching back to persistent
mode keeps the old database and its admitted analytics backlog, subject to the
consent barrier below.

Both modes hold one canonical installation lease. The only additional durable
state in memory mode is an explicit consent-only record; it contains no IDs,
timestamps or analytics payloads. Its atomic pending/settled protocol brackets
the ordinary queue consent transaction. Pending or partial records deny on
startup, and failed/ambiguous writes quarantine the original live lease.
A consent-only `persistentReconciled` bit is cleared by memory entry/choices.
On return to persistent mode, the existing opt-out privacy transaction also runs
when the final consent Boolean matches: clear session, purge queued replay,
close diagnostic continuity, and invalidate cached flag/request context. Existing
event backlog, device/person metadata, first-session history and exposure ledger
remain exactly as ordinary opt-out specifies. Only a settled SQL barrier marks
this bit reconciled; a failed or ambiguous application remains denied. This
prevents memory opt-out followed by opt-in from reviving dormant replay/OS
coverage without modifying the old analytics files during memory use.
Unsupported or malformed consent records fail closed. An explicit choice made
before setup is still only in process memory until the runtime opens.

Older stores lack an explicit-choice bit. A saved denial may be retained as
denial, but `optedOut == false` cannot be promoted into explicit consent. Thus
memory mode with any prior owned analytics store and no explicit record starts
denied without reading the old database and saves that pending denial for either
mode; a public consent call is needed.
New installations retain their existing default behavior. Pending-file cleanup
only handles the bounded consent file under the original lease. Failure to
persist every attempted restrictive write cannot provide a process-death
durability guarantee; the current owner nevertheless remains denied.

The original public source API baseline, release tag/archive digests, and
historical evidence definitions are retained for provenance. They do not make
the retired preview continuity runner a current release gate. Current gates
cover clean installation, supported owned-store upgrades, unsupported-store
refusal, no-touch behavior, and the full SDK Lab delivery and rendering checks.
