# ADR 0007: Migrate PVC backup from Volsync to Kopiur

## Context

Stateful app data (PVCs) is backed up with **Volsync** today: a reusable Kustomize Component
(`kubernetes/components/volsync`) that, per app, stamps out a restic `ReplicationSource` (snapshot
copy method, scheduled), a `ReplicationDestination` (`manual: restore-once` for first-boot restore),
an `ExternalSecret` for restic/S3 credentials, and a templated PVC whose `dataSourceRef` points at
the ReplicationDestination. Apps opt in via `components: [.../volsync]` + `postBuild.substitute`
(`APP`, `VOLSYNC_CLAIM`, `VOLSYNC_CAPACITY`, …). Targets land in per-app restic repos
(`${APP}-volsync-minio`) on the in-cluster MinIO S3.
Three apps use it: `download/rdt-client`, `media/plex`, `vaultwarden`.

This works, but has friction:

- **Per-app sprawl.** Every backed-up app carries its own ReplicationSource/Destination +
  ExternalSecret + PVC datasource wiring, repeated via the Component. Backup config is scattered
  across app directories.
- **Per-app repositories and schedules** mean no central view of backup state, maintenance, or
  retention; pruning/maintenance is per-repo.
- The restore-on-first-boot `dataSourceRef` dance couples backup into the PVC lifecycle in a way
  that is fiddly to reason about.

**Kopiur** (`kopiur.home-operations.com/v1alpha1`) is a cluster backup **operator** with a single
`ClusterRepository` CR: a central, Kopia-backed repository with cluster-wide maintenance schedules,
governance retention, and a `allowedNamespaces` scope, i.e. the "one repository, operator-managed,
central policy" model that Volsync's per-app components lack.

## Decision

Adopt **Kopiur** as the PVC backup mechanism and **migrate off Volsync incrementally**. Both
operators run side by side during the transition.

Current state (in flight):

- The Kopiur operator and its `ClusterRepository` (`expanse`) are deployed in `kopiur-system`:
  Kopia → the in-cluster MinIO (bucket `kopia`), central
  execution, quick maintenance hourly + full daily, 30-day governance blob retention, mover pods
  labeled `egress.policy.home.arpa/minio: "true"`, `allowedNamespaces.all: true`.
- **No application has cut over yet**, all three stateful apps remain on Volsync. The Kopiur
  infrastructure is in place and ready for gradual per-app adoption.

Migration approach: move apps one at a time; for each, establish the Kopiur backup, verify a
restore, then remove the Volsync Component wiring from that app. Volsync stays deployed until the
last app is migrated, then its namespace/component are retired.

## Rationale

- Volsync's per-app model scatters backup across every app directory (a
  ReplicationSource/Destination + ExternalSecret + PVC datasource each) and gives no central view of
  backup state, maintenance, or retention. A single operator-managed `ClusterRepository` centralizes
  all of that and removes the per-app plumbing.
- Kopia brings content-addressable dedup and epoch-based maintenance over restic's per-repo model.
- Running both backup systems during the migration is the only safe cutover: a backup that has not
  been test-restored is not a backup, so each app is restore-verified before its Volsync path is
  retired. This is also why this ADR is _in progress_, not _accepted_.

## Consequences

- **Central backup model:** one `ClusterRepository`, one place for maintenance/retention/governance,
  and a cluster-wide view of backup state, versus Volsync's per-app repositories and schedules.
- **Less per-app boilerplate:** app directories stop carrying ReplicationSource/Destination +
  datasource plumbing; backup becomes an operator concern, not a per-app Component.
- Kopia (vs restic) brings content-addressable dedup, caching, and epoch-based maintenance.
- **Two backup systems during the migration.** Until cutover completes, both Volsync and Kopiur are
  deployed; operators must know which app is protected by which, and avoid gaps/double-coverage.
- **Restore parity must be proven per app** before retiring the Volsync path, a backup that has
  not been test-restored is not a backup.
- Kopiur is **young** (`v1alpha1`); the API may change and the operational track record is short.
  This is the reason the ADR is _Proposed/In progress_, not _Accepted_.
- Both back up to the **same MinIO** instance; the backup target's own durability/availability is a
  shared dependency for either tool (out of scope here, but worth stating).
- The opt-in surface changes from a Kustomize Component (`components: [.../volsync]` + substitutions)
  to the operator's namespace/label model; the per-namespace wiring in
  [ADR 0002](0002-repository-layout.md) is unaffected.

## Alternatives considered

- **Stay on Volsync:** proven and already wired, but keeps the per-app sprawl and per-repo
  maintenance that motivated the change.
- **CNPG-style per-app ObjectStore for everything:** good for Postgres (and already used there via
  the `cnpg` Component), but it is a database-backup model, not a general PVC-snapshot one.
- **Velero:** cluster-wide and mature, but oriented at whole-namespace/cluster backup + object
  snapshots rather than the per-volume restic/kopia model these apps use, and heavier than needed
  for a handful of PVCs.
