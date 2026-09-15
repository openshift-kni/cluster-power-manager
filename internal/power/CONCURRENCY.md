# Power package concurrency guidance

Each host owns one mutex that serializes changes to its pools, CPU membership,
and pool power profiles. Pools acquire that mutex through `host.getHostMutex()`.

The locking entry points are `MoveCpus`, `MoveCPUIDs`, `SetCPUIDs`,
`SetPowerProfile`, exclusive pool `Remove`, and `AddExclusivePool`.

For operations covered by this mutex, the locking rules are:

1. A locking entry point acquires the host mutex exactly once and holds it
   for the complete operation.
2. Internal mutation helpers assume the host mutex is already held and never
   acquire it themselves. This includes `setCpus`, `moveCpus`, `setPool`,
   `doSetPool`, and `consolidate`.
3. A locking entry point must not call another locking entry point while holding
   the mutex. It calls the corresponding internal helper instead. For example,
   `Remove` calls `setCpus`, not `SetCPUIDs`.
4. The mutex remains held while a multi-CPU operation updates membership and
   applies power profiles so another mutation cannot observe or modify a
   partially updated pool.

Acquiring the mutex twice in the same goroutine deadlocks because Go mutexes are
not reentrant. Keeping acquisition at exported boundaries makes the lock owner
clear and keeps internal call chains from accidentally acquiring it again.

These rules serialize host-scoped pool mutations. Read-side synchronization is
outside the scope of this guidance.
