#!/usr/bin/env python3
"""
Secret scan over EVERY git object in this repository, not just the working tree.

Why not gitleaks: this repo goes public, and the submission checklist calls for a secret scan that
anyone can reproduce. This needs nothing but python3 and git, so a reviewer can run it on a clean
clone with no install step. Run gitleaks too if you have it; the two are complementary.

Why all git objects rather than the working tree: a credential that was committed and then deleted
is still in the history that gets pushed. Deleting the file fixes nothing. `--selftest` proves the
scanner catches exactly that case.

Rule families follow gitleaks' default set for the categories that can plausibly appear here.
Allowlist entries are exact literals with a stated reason, never broad patterns, so a real leak
cannot hide behind one.

Usage:
  python3 scripts/secret-scan.py .            scan this repo, exit 1 on findings
  python3 scripts/secret-scan.py --selftest   prove the scanner works, then scan
"""
import re
import subprocess
import sys
from collections import defaultdict

_ARGS = [a for a in sys.argv[1:] if not a.startswith("-")]
REPO = _ARGS[0] if _ARGS else "."

# Exact literals that are public by construction. Each needs a reason.
ALLOWLIST = {
    "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80":
        "Anvil published dev account #0 private key, local fork only",
    "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d":
        "Anvil published dev account #1 private key, local fork only",
}

RULES = [
    # --- private keys ---
    ("pem-private-key", r"-----BEGIN [A-Z ]*PRIVATE KEY( BLOCK)?-----"),
    # 64 hex alone matches tx hashes, event topics and keccak digests, which is why gitleaks does
    # not ship such a rule. Require key-ish context on the same line so it stays high signal.
    ("evm-private-key-literal", r"\b0x[0-9a-fA-F]{64}\b", "key-context"),
    # --- credentials embedded in URLs ---
    ("basic-auth-url", r"[a-zA-Z][a-zA-Z0-9+.-]*://[^/\s:@]+:[^/\s:@]+@"),
    ("postgres-uri", r"postgres(ql)?://[^\s\"']+"),
    ("mysql-uri", r"mysql://[^\s\"']+"),
    ("mongodb-uri", r"mongodb(\+srv)?://[^\s\"']+"),
    ("redis-uri", r"redis://[^\s\"']+"),
    ("neon-host", r"[a-z0-9-]+\.neon\.tech"),
    # --- cloud providers ---
    ("aws-access-key-id", r"\b(A3T[A-Z0-9]|AKIA|ASIA|ABIA|ACCA)[A-Z0-9]{16}\b"),
    ("aws-secret-assignment", r"(?i)aws[_-]?secret[_-]?access[_-]?key\S{0,20}[:=]\s*['\"][A-Za-z0-9/+=]{40}"),
    ("gcp-service-account", r"\"type\"\s*:\s*\"service_account\""),
    ("gcp-api-key", r"\bAIza[0-9A-Za-z\-_]{35}\b"),
    ("azure-storage-key", r"(?i)AccountKey\s*=\s*[A-Za-z0-9+/=]{60,}"),
    # --- provider tokens ---
    ("github-token", r"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}\b"),
    ("github-fine-grained-pat", r"\bgithub_pat_[A-Za-z0-9_]{22,}\b"),
    ("slack-token", r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"),
    ("slack-webhook", r"https://hooks\.slack\.com/services/[A-Za-z0-9/]+"),
    ("stripe-secret", r"\b(sk|rk)_live_[A-Za-z0-9]{16,}\b"),
    ("openai-key", r"\bsk-[A-Za-z0-9]{20,}T3BlbkFJ[A-Za-z0-9]{20,}\b"),
    ("anthropic-key", r"\bsk-ant-[A-Za-z0-9\-_]{20,}\b"),
    ("npm-token", r"\bnpm_[A-Za-z0-9]{36}\b"),
    ("vercel-token", r"(?i)vercel[_-]?token\S{0,20}[:=]\s*['\"][A-Za-z0-9]{20,}"),
    ("alchemy-or-infura-url-key", r"https://[a-z0-9-]+\.(alchemy|infura)\.io/v[0-9]/[A-Za-z0-9_-]{20,}"),
    ("jwt", r"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"),
    # --- generic ---
    ("generic-secret-assignment",
     r"(?i)\b(api[_-]?key|apikey|secret|passwd|password|credential|private[_-]?key|access[_-]?token|auth[_-]?token)\b"
     r"\s*[:=]\s*['\"][^'\"\s${}]{8,}['\"]"),
]

KEY_CONTEXT_RX = re.compile(
    r"(?i)(private[_-]?key|privkey|\bsecret\b|mnemonic|\bseed\b|signer|wallet[_-]?key|deployer[_-]?key)"
)

COMPILED = []
for _rule in RULES:
    _name, _pat = _rule[0], _rule[1]
    _ctx = _rule[2] if len(_rule) > 2 else None
    COMPILED.append((_name, re.compile(_pat), _ctx))

# Paths we do not own or that carry hashes by design.
SKIP_PATH = re.compile(r"(^|/)(pnpm-lock\.yaml|package-lock\.json|yarn\.lock)$|^contracts/lib/")


def sh(args, **kw):
    return subprocess.run(args, cwd=REPO, capture_output=True, text=True, **kw).stdout


def object_paths():
    """Every path ever recorded in any reachable commit, mapped from blob sha."""
    out = defaultdict(set)
    revs = sh(["git", "rev-list", "--all"]).split()
    for rev in revs:
        for line in sh(["git", "ls-tree", "-r", rev]).splitlines():
            try:
                meta, path = line.split("\t", 1)
                sha = meta.split()[2]
            except (ValueError, IndexError):
                continue
            out[sha].add(path)
    return out


PLANTED = {
    "evm-private-key-literal": 'const DEPLOYER_PRIVATE_KEY = "0x4c0883a69102937d6231471b5dbb6204fe512961708279f2e3a1b2c4d5e6f708";',
    "postgres-uri": 'DATABASE_URL = "postgresql://user:npg_AbCdEf123456@ep-x-1.us-east-2.aws.neon.tech/db"',
    "github-token": 'const t = "ghp_AbCdEf0123456789AbCdEf0123456789AbCd";',
    "aws-access-key-id": 'const a = "AKIAIOSFODNN7EXAMPLE";',
    "anthropic-key": 'const k = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz012345";',
    "generic-secret-assignment": 'const password = "hunter2hunter2";',
}


def selftest():
    """Plant known-fake secrets in a throwaway repo, delete them, and require detection.

    Deleting before scanning is the point: it proves history is scanned, not the working tree.
    """
    import tempfile
    global REPO
    tmp = tempfile.mkdtemp(prefix="secret-scan-selftest-")
    for cmd in (["git", "init", "-q", "."], ["git", "config", "user.email", "t@t"],
                ["git", "config", "user.name", "t"]):
        subprocess.run(cmd, cwd=tmp, capture_output=True)
    with open(f"{tmp}/planted.ts", "w") as fh:
        fh.write("\n".join(PLANTED.values()) + "\n")
    subprocess.run(["git", "add", "planted.ts"], cwd=tmp, capture_output=True)
    subprocess.run(["git", "commit", "-qm", "planted"], cwd=tmp, capture_output=True)
    subprocess.run(["git", "rm", "-q", "planted.ts"], cwd=tmp, capture_output=True)
    subprocess.run(["git", "commit", "-qm", "deleted, but history remembers"], cwd=tmp,
                   capture_output=True)

    saved, REPO = REPO, tmp
    found = {name for name, _, _, _, _ in scan()}
    REPO = saved

    missing = set(PLANTED) - found
    if missing:
        print(f"SELFTEST FAILED: these rules did not fire: {sorted(missing)}")
        return False
    print(f"SELFTEST PASSED: all {len(PLANTED)} planted secrets detected from history "
          f"after the file was deleted")
    print()
    return True


def scan():
    paths = object_paths()
    blobs = [
        line.split()[0]
        for line in sh(["git", "cat-file", "--batch-all-objects", "--batch-check"]).splitlines()
        if len(line.split()) >= 2 and line.split()[1] == "blob"
    ]

    findings = []
    allowlisted = defaultdict(int)
    scanned = 0

    for sha in blobs:
        known = paths.get(sha, set())
        if known and all(SKIP_PATH.search(p) for p in known):
            continue
        raw = subprocess.run(
            ["git", "cat-file", "blob", sha], cwd=REPO, capture_output=True
        ).stdout
        if b"\x00" in raw[:8000] or len(raw) > 2_000_000:
            continue  # binary or oversized
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            continue
        scanned += 1
        for name, rx, ctx in COMPILED:
            for m in rx.finditer(text):
                hit = m.group(0)
                if hit in ALLOWLIST:
                    allowlisted[hit] += 1
                    continue
                if ctx == "key-context":
                    line_start = text.rfind("\n", 0, m.start()) + 1
                    line_end = text.find("\n", m.end())
                    line = text[line_start: line_end if line_end != -1 else len(text)]
                    if not KEY_CONTEXT_RX.search(line):
                        continue
                line_no = text.count("\n", 0, m.start()) + 1
                findings.append((name, sorted(known)[:2] or ["<unreferenced blob>"], line_no, hit, sha))

    scan.stats = (scanned, allowlisted)
    return findings


def main():
    if "--selftest" in sys.argv:
        if not selftest():
            return 2

    findings = scan()
    scanned, allowlisted = scan.stats

    print(f"scanned {scanned} text blobs across all git objects")
    print(f"rules: {len(COMPILED)}")
    print()

    if allowlisted:
        print("ALLOWLISTED (public by construction):")
        for lit, n in allowlisted.items():
            print(f"  {n:3d}x  {lit[:26]}...  {ALLOWLIST[lit]}")
        print()

    # Group findings so a repeated literal across many blobs reads as one item.
    grouped = defaultdict(list)
    for name, p, line_no, hit, sha in findings:
        grouped[(name, hit)].append((p[0], line_no, sha[:8]))

    if not grouped:
        print("NO FINDINGS")
        return 0

    print(f"FINDINGS: {len(grouped)} distinct")
    for (name, hit) in sorted(grouped):
        occ = grouped[(name, hit)]
        print(f"\n  [{name}] {hit[:90]}")
        print(f"    {len(occ)} occurrence(s), e.g. {occ[0][0]}:{occ[0][1]} (blob {occ[0][2]})")
    return 1


if __name__ == "__main__":
    sys.exit(main())
