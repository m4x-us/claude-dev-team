#!/usr/bin/env python3
"""
worker-pool.py — Dynamic worker name pool for the autocode suite.

Subcommands:
  init              Create pool with all 24 names available
  claim <module> [n]  Claim n worker names for a module (default: 4)
  release <module>  Release a module's names back to the pool
  lookup <name>     Print which module owns this name, or "unowned"
  status            Print formatted pool status table

Options:
  --pool-dir PATH   Override pool directory (default: .autocode/modules/)
                    Used for testing to avoid polluting the live pool.
"""
import sys
import os
import json
import fcntl
import tempfile
import argparse
from datetime import datetime, timezone

POOL_NAMES = [
    "Adam",    "Barry",   "Charles", "David",
    "Eric",    "Frank",   "Gary",    "Henry",
    "Ivan",    "Jake",    "Kenny",   "Larry",
    "Mike",    "Nathan",  "Oscar",   "Peter",
    "Quentin", "Ryan",    "Steve",   "Trevor",
    "Ulrich",  "Victor",  "Walter",  "Xavier",
]

POOL_FILENAME = ".worker-pool.json"


def get_pool_path(pool_dir):
    return os.path.join(pool_dir, POOL_FILENAME)


def get_workers_path(pool_dir, module):
    return os.path.join(pool_dir, module, ".workers")


def atomic_write_pool(pool_path, data):
    dir_ = os.path.dirname(pool_path)
    os.makedirs(dir_, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=dir_, suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as tmp:
            json.dump(data, tmp, indent=2)
            tmp.write("\n")
        os.replace(tmp_path, pool_path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def load_pool_locked(pool_path):
    """Open pool file, acquire exclusive lock, return (fh, data). Caller must close fh."""
    fh = open(pool_path, "r")
    fcntl.flock(fh, fcntl.LOCK_EX)
    try:
        data = json.load(fh)
    except json.JSONDecodeError as e:
        fh.close()
        print(
            f"Pool file corrupt at {pool_path}. Delete and re-init.",
            file=sys.stderr,
        )
        sys.exit(1)
    return fh, data


def write_workers_file(pool_dir, module, names):
    """Write .workers file (lowercase names, one per line)."""
    workers_path = get_workers_path(pool_dir, module)
    os.makedirs(os.path.dirname(workers_path), exist_ok=True)
    with open(workers_path, "w") as f:
        for name in names:
            f.write(name.lower() + "\n")


def cmd_init(args):
    pool_path = get_pool_path(args.pool_dir)
    if os.path.exists(pool_path):
        print("Pool already initialized. Use 'status' to view.", file=sys.stderr)
        sys.exit(0)
    os.makedirs(args.pool_dir, exist_ok=True)
    data = {"pool": list(POOL_NAMES), "claims": {}}
    atomic_write_pool(pool_path, data)
    print(f"Worker pool initialized: {len(POOL_NAMES)} workers available (Adam, Barry, ..., Xavier)")


def cmd_claim(args):
    pool_path = get_pool_path(args.pool_dir)
    if not os.path.exists(pool_path):
        print(f"Pool not initialized. Run: python3 {sys.argv[0]} init", file=sys.stderr)
        sys.exit(1)

    module = args.module.strip().lower()
    n = args.n if args.n and args.n > 0 else 4
    n = max(1, min(24, n))

    fh, data = load_pool_locked(pool_path)
    try:
        # Idempotency: if module already claimed, return existing workers unchanged
        if module in data["claims"]:
            existing = data["claims"][module]["workers"]
            write_workers_file(args.pool_dir, module, existing)
            for name in existing:
                print(name.lower())
            print(
                f"# (reusing existing claim for '{module}' — already has {len(existing)} workers)",
                file=sys.stderr,
            )
            return

        available = data["pool"]

        if len(available) == 0:
            print("# POOL EXHAUSTED — no workers available. Run /scope clear in another session.")
            sys.exit(1)

        if len(available) < n:
            actual_n = len(available)
            print(f"# WARNING: only {actual_n} workers available — claiming {actual_n} instead of {n}")
            n = actual_n

        claimed = available[:n]
        data["pool"] = available[n:]
        data["claims"][module] = {
            "workers": claimed,
            "claimed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        }

        write_workers_file(args.pool_dir, module, claimed)
        atomic_write_pool(pool_path, data)

        for name in claimed:
            print(name.lower())
    finally:
        fh.close()


def cmd_release(args):
    pool_path = get_pool_path(args.pool_dir)
    if not os.path.exists(pool_path):
        print("No pool file found — nothing to release.", file=sys.stderr)
        sys.exit(0)

    module = args.module.strip().lower()

    fh, data = load_pool_locked(pool_path)
    try:
        if module not in data["claims"]:
            print(f"Module '{module}' has no active claim.", file=sys.stderr)
            return

        recovered = data["claims"][module]["workers"]
        del data["claims"][module]

        # Deduplicate: only append names not already in pool
        existing_pool_set = set(data["pool"])
        to_append = [n for n in recovered if n not in existing_pool_set]
        data["pool"].extend(to_append)

        atomic_write_pool(pool_path, data)
    finally:
        fh.close()

    # Delete .workers file (silently ignore if missing)
    workers_path = get_workers_path(args.pool_dir, module)
    try:
        os.remove(workers_path)
    except FileNotFoundError:
        pass

    names_str = ", ".join(recovered)
    print(f"Released {len(recovered)} workers from '{module}': {names_str}")


def cmd_lookup(args):
    pool_path = get_pool_path(args.pool_dir)
    try:
        if not os.path.exists(pool_path):
            print("unowned")
            return

        with open(pool_path, "r") as f:
            data = json.load(f)

        normalized = args.name.strip().title()
        for module, claim in data.get("claims", {}).items():
            if normalized in claim.get("workers", []):
                print(module.lower())
                return

        print("unowned")
    except Exception:
        # lookup must NEVER raise — always return "unowned" on any error
        print("unowned")


def cmd_status(args):
    pool_path = get_pool_path(args.pool_dir)
    if not os.path.exists(pool_path):
        print("No worker pool found. Run: python3 ~/.claude/scripts/worker-pool.py init")
        return

    try:
        with open(pool_path, "r") as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        print(f"Pool file unreadable: {e}")
        return

    claims = data.get("claims", {})
    available = data.get("pool", [])
    total_claimed = sum(len(c["workers"]) for c in claims.values())
    total_available = len(available)
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    bar = "━" * 51
    print(f"Worker Pool — {today}")
    print(bar)

    if claims:
        print(f"{'Module':<14} {'Workers':<30} Since")
        print(bar)
        for module, claim in sorted(claims.items()):
            workers_str = ", ".join(claim["workers"])
            since = claim.get("claimed_at", "—")[:16].replace("T", " ")
            print(f"{module:<14} {workers_str:<30} {since}")
    else:
        print("(no active claims)")

    print(bar)

    # Print available names in wrapped rows of 8
    avail_label = f"Available ({total_available}):"
    if available:
        names_per_row = 8
        rows = [available[i:i+names_per_row] for i in range(0, len(available), names_per_row)]
        first_row = ", ".join(rows[0])
        print(f"{avail_label} {first_row}")
        for row in rows[1:]:
            print(f"{'':>{len(avail_label)+1}}{', '.join(row)}")
    else:
        print(f"{avail_label} (none)")

    print(bar)
    print(f"Total: {len(POOL_NAMES)}  |  Claimed: {total_claimed}  |  Available: {total_available}")


def main():
    parser = argparse.ArgumentParser(
        description="Dynamic worker name pool for the autocode suite.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--pool-dir",
        default=".autocode/modules",
        help="Override pool directory (default: .autocode/modules/). Use for testing.",
    )

    subparsers = parser.add_subparsers(dest="subcommand")
    subparsers.required = True

    subparsers.add_parser("init", help="Create pool with all 24 names available")

    p_claim = subparsers.add_parser("claim", help="Claim n names for a module")
    p_claim.add_argument("module", help="Module name (e.g. email, scheduling)")
    p_claim.add_argument("n", nargs="?", type=int, default=4, help="Number of names to claim (default: 4)")

    p_release = subparsers.add_parser("release", help="Release a module's names back to pool")
    p_release.add_argument("module", help="Module name")

    p_lookup = subparsers.add_parser("lookup", help="Find which module owns a worker name")
    p_lookup.add_argument("name", help="Worker name to look up (e.g. adam)")

    subparsers.add_parser("status", help="Print pool status table")

    args = parser.parse_args()

    dispatch = {
        "init": cmd_init,
        "claim": cmd_claim,
        "release": cmd_release,
        "lookup": cmd_lookup,
        "status": cmd_status,
    }
    dispatch[args.subcommand](args)


if __name__ == "__main__":
    main()
