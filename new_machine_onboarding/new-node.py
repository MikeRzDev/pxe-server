#!/usr/bin/env python3
"""new-node.py - provision Proxmox nodes: pick an address, generate and save the
root password, emit a validated answer file.

Three ways in:

    ./new-node.py                          interactive prompts
    ./new-node.py pve01 --ip auto          one-shot flags
    ./new-node.py --file nodes.yaml        declarative, one or many nodes

Produces, per node:

    secrets/<name>.env        the ROOT PASSWORD in clear + its hash   (0600)
    nodes/<name>.answer.toml  the answer file to bake into an ISO

Both directories are gitignored.

THE PASSWORD IS WRITTEN TO DISK BEFORE ANYTHING ELSE. A random 32-character
password that exists only as a hash is a password you have lost, along with the
node it installs. Nothing later can run until that file is on disk.

################################################################
# The ISO built from an answer file WIPES THE TARGET DISK.     #
################################################################
"""

import argparse
import ipaddress
import json
import os
import re
import secrets as pysecrets
import shutil
import string
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))   # new_machine_onboarding/
REPO = os.path.dirname(HERE)
# Per-node state lives beside this script, not at the repo root, so everything
# to do with onboarding a machine is in one directory. Both are gitignored.
SECRETS_DIR = os.path.join(HERE, "secrets")
NODES_DIR = os.path.join(HERE, "nodes")

PW_ALPHABET = string.ascii_letters + string.digits + "._+=@%#-"
PW_LENGTH = 32

DEFAULTS = {
    "domain": "lan",
    "gateway": "",
    "dns": "",
    "cidr_bits": 24,
    "timezone": "UTC",
    "country": "us",
    "keyboard": "en-us",
    "mailto": "",
    "filesystem": "ext4",
    "disk": "auto",
    "ip_range": "",
    "ssh_key": "",
    "product": "pve",
}

# Proxmox installer products this can write answer files for. The answer file
# schema ([global]/[network]/[disk-setup]) is shared across them - only the
# product name and the web UI port differ, so one generator covers both rather
# than a forked copy that has to be kept in sync.
PRODUCTS = {
    "pve": ("Proxmox VE", 8006),
    "pdm": ("Proxmox Datacenter Manager", 8443),
}


# --------------------------------------------------------------------------
# Minimal YAML reader.
#
# PyYAML is not in the stdlib and is absent from both a stock macOS python and
# a stock DietPi one; on Python 3.14 installing it needs a venv (PEP 668). A
# hard dependency would make this tool fail on exactly the machines it is for,
# so this parses the SUBSET the schema actually uses:
#
#   - two-space nested mappings
#   - lists of mappings introduced by "- "
#   - scalars: bare, 'single' or "double" quoted, ints, true/false, null
#   - "#" comments outside quotes
#
# Anchors, flow style ({a: 1}), multi-line scalars and multi-document files are
# NOT supported and raise instead of silently misparsing. Pass a .json file if
# you need anything richer - that goes through the stdlib json module.
# --------------------------------------------------------------------------
class YamlSubsetError(Exception):
    pass


def _strip_comment(line: str) -> str:
    out, quote = [], None
    for ch in line:
        if quote:
            out.append(ch)
            if ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
            out.append(ch)
        elif ch == "#":
            break
        else:
            out.append(ch)
    return "".join(out).rstrip()


def _scalar(tok: str):
    tok = tok.strip()
    if not tok:
        return ""
    if tok[0] in "\"'" and len(tok) >= 2 and tok[-1] == tok[0]:
        return tok[1:-1]
    # Reject flow style outright rather than keeping it as a string. Quoted
    # values were already returned above, so a leading brace here can only be
    # YAML this reader does not implement - and silently turning "{b: 1}" into
    # the literal text "{b: 1}" is exactly the kind of misparse that shows up
    # later as a nonsensical answer file.
    if tok[0] in "{[":
        raise YamlSubsetError(f"flow style is not supported: {tok!r}")
    low = tok.lower()
    if low in ("true", "yes", "on"):
        return True
    if low in ("false", "no", "off"):
        return False
    if low in ("null", "~", ""):
        return None
    if re.fullmatch(r"-?\d+", tok):
        return int(tok)
    return tok


def parse_yaml_subset(text: str):
    lines = []
    for n, raw in enumerate(text.splitlines(), 1):
        if "\t" in raw.split("#")[0]:
            raise YamlSubsetError(f"line {n}: tabs are not valid YAML indentation")
        body = _strip_comment(raw)
        if body.strip() in ("", "---"):
            continue
        lines.append((n, len(body) - len(body.lstrip(" ")), body.strip()))

    def block(idx, indent):
        """Parse consecutive lines at >= indent. Returns (value, next_index)."""
        if idx >= len(lines):
            return None, idx
        if lines[idx][2].startswith("- "):
            items = []
            while idx < len(lines) and lines[idx][1] == indent and lines[idx][2].startswith("- "):
                n, ind, body = lines[idx]
                inner = body[2:].strip()
                # "- key: value" starts a mapping whose remaining keys are
                # indented further on the following lines.
                if ":" in inner and not inner.startswith(("'", '"')):
                    k, _, v = inner.partition(":")
                    item = {}
                    if v.strip():
                        item[k.strip()] = _scalar(v)
                        idx += 1
                    else:
                        idx += 1
                        sub, idx = block(idx, ind + 2) if idx < len(lines) and lines[idx][1] > ind else (None, idx)
                        item[k.strip()] = sub
                    child_indent = ind + 2
                    while idx < len(lines) and lines[idx][1] >= child_indent and not lines[idx][2].startswith("- "):
                        sub, idx = block(idx, lines[idx][1])
                        if isinstance(sub, dict):
                            item.update(sub)
                        else:
                            raise YamlSubsetError(f"line {lines[idx-1][0]}: unexpected value in list item")
                    items.append(item)
                else:
                    items.append(_scalar(inner))
                    idx += 1
            return items, idx

        mapping = {}
        while idx < len(lines) and lines[idx][1] == indent:
            n, ind, body = lines[idx]
            if body.startswith("- "):
                break
            if ":" not in body:
                raise YamlSubsetError(f"line {n}: expected 'key: value', got {body!r}")
            k, _, v = body.partition(":")
            key = k.strip()
            if v.strip():
                mapping[key] = _scalar(v)
                idx += 1
            else:
                idx += 1
                if idx < len(lines) and lines[idx][1] > ind:
                    mapping[key], idx = block(idx, lines[idx][1])
                else:
                    mapping[key] = None
            if idx < len(lines) and lines[idx][1] > indent and not lines[idx][2].startswith("- "):
                raise YamlSubsetError(f"line {lines[idx][0]}: unexpected indentation")
        return mapping, idx

    value, idx = block(0, lines[0][1] if lines else 0)
    if idx != len(lines):
        raise YamlSubsetError(f"line {lines[idx][0]}: could not parse {lines[idx][2]!r}")
    return value or {}


def load_config_file(path):
    with open(path) as fh:
        text = fh.read()
    if path.endswith(".json"):
        return json.loads(text)
    try:
        return parse_yaml_subset(text)
    except YamlSubsetError as exc:
        die(f"{path}: {exc}\n"
            f"       This reader supports a YAML subset only - see the header of\n"
            f"       new-node.py. Converting the file to .json also works.")


# --------------------------------------------------------------------------
def die(msg, code=1):
    # Flush stdout first: the progress lines are buffered while stderr is not,
    # so without this the error appears ABOVE the preflight output that led to
    # it and reads as though it happened first.
    sys.stdout.flush()
    print(f"new-node: {msg}", file=sys.stderr)
    sys.exit(code)


def load_env_file(path):
    """Read the shell-style nodes.env so both tools share one config."""
    out = {}
    if not os.path.exists(path):
        return out
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            out[k.strip()] = v.strip().strip("\"'")
    mapped = {
        "NODE_DOMAIN": "domain", "NODE_GATEWAY": "gateway", "NODE_DNS": "dns",
        "NODE_TIMEZONE": "timezone", "NODE_COUNTRY": "country",
        "NODE_KEYBOARD": "keyboard", "NODE_MAILTO": "mailto",
        "NODE_CIDR_BITS": "cidr_bits", "NODE_DISKS": "disk", "NODE_FS": "filesystem",
        "NODE_SSH_KEY": "ssh_key",
    }
    cfg = {mapped[k]: v for k, v in out.items() if k in mapped}
    if "NODE_IP_START" in out and "NODE_IP_END" in out:
        cfg["ip_range"] = f"{out['NODE_IP_START']}-{out['NODE_IP_END']}"
    if "cidr_bits" in cfg:
        cfg["cidr_bits"] = int(cfg["cidr_bits"])
    return cfg


def parse_range(spec):
    """'192.0.2.10-192.0.2.40' or '192.0.2.10-40' -> [addresses]"""
    if not spec:
        return []
    if "-" not in spec:
        return [str(ipaddress.IPv4Address(spec))]
    start, _, end = spec.partition("-")
    start = start.strip()
    end = end.strip()
    first = ipaddress.IPv4Address(start)
    last = ipaddress.IPv4Address(end) if "." in end else \
        ipaddress.IPv4Address(".".join(start.split(".")[:3] + [end]))
    if last < first:
        raise ValueError(f"range end {last} is before start {first}")
    return [str(ipaddress.IPv4Address(i)) for i in range(int(first), int(last) + 1)]


def node_dir(name):
    """Everything secret about one machine lives in secrets/<name>/:
    credentials.env and its own SSH keypair."""
    return os.path.join(SECRETS_DIR, name)


def claimed_ips():
    """Addresses already handed out. Reads the per-node directories, and also
    the older flat secrets/<name>.env so an existing setup keeps working."""
    out = set()
    if not os.path.isdir(SECRETS_DIR):
        return out
    files = []
    for entry in os.listdir(SECRETS_DIR):
        path = os.path.join(SECRETS_DIR, entry)
        if os.path.isdir(path):
            files.append(os.path.join(path, "credentials.env"))
        elif entry.endswith(".env"):
            files.append(path)
    for f in files:
        try:
            with open(f) as fh:
                for line in fh:
                    if line.startswith("NODE_IP="):
                        out.add(line.split("=", 1)[1].strip())
        except OSError:
            continue
    return out


def generate_ssh_key(dest_dir, fqdn):
    """Generate this machine's own ed25519 keypair.

    One key per node rather than a shared one: the private half never leaves
    its directory, and revoking a machine means deleting its folder rather
    than rotating a credential every node shares. No passphrase - it has to
    work unattended.
    """
    if not shutil.which("ssh-keygen"):
        die("ssh-keygen not found - needed to generate the node's SSH key")
    key = os.path.join(dest_dir, "id_ed25519")
    for stale in (key, key + ".pub"):
        if os.path.exists(stale):
            os.unlink(stale)
    res = subprocess.run(
        ["ssh-keygen", "-t", "ed25519", "-N", "", "-C", f"root@{fqdn}", "-f", key],
        capture_output=True, text=True)
    if res.returncode != 0:
        die(f"ssh-keygen failed: {res.stderr.strip() or res.stdout.strip()}")
    os.chmod(key, 0o600)
    os.chmod(key + ".pub", 0o644)
    with open(key + ".pub") as fh:
        return fh.read().strip()


_ping_cache = {}


def responds(ip):
    """True if something answers at ip. Cached: a preflight over a /24 would
    otherwise ping the same address once per node being provisioned."""
    if ip not in _ping_cache:
        flag = "-t" if sys.platform == "darwin" else "-W"
        _ping_cache[ip] = subprocess.run(
            ["ping", "-c", "1", flag, "1", ip],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    return _ping_cache[ip]


def preflight(nodes, base_cfg, args):
    """Resolve EVERY node's address before anything is written.

    Addresses are checked up front, not inside the provisioning loop, for two
    reasons. A batch that runs out of addresses half way through would
    otherwise leave the earlier nodes provisioned and the rest not - and since
    the password is deliberately written before anything else, that is real
    state to clean up. And under --dry-run nothing lands in secrets/, so
    allocating inside the loop handed every 'auto' node the same address.

    Returns [(name, node_cfg, ip)] or exits with a message naming what is
    wrong: an unusable range, a static address already in use, or a pool with
    fewer free addresses than there are nodes asking for one.
    """
    resolved, planned = [], []
    taken = claimed_ips()

    for entry in nodes:
        if not isinstance(entry, dict) or not entry.get("name"):
            die(f"each node needs a 'name': got {entry!r}")
        name = str(entry["name"])
        cfg = dict(base_cfg)
        cfg.update({k: v for k, v in entry.items() if k != "name" and v is not None})
        for required in ("gateway", "dns"):
            if not cfg.get(required):
                die(f"{name}: '{required}' is not set (nodes.env, the file, or --{required})")
        planned.append((name, cfg, args.ip or entry.get("ip") or "auto"))

    print("==> preflight: checking addresses")

    # Static first, so they claim their address before any pool allocation can
    # hand the same one out.
    for name, cfg, wanted in planned:
        if wanted == "auto":
            continue
        try:
            ip = str(ipaddress.IPv4Address(wanted))
        except ValueError:
            die(f"{name}: '{wanted}' is not a valid IPv4 address")
        if ip in taken:
            die(f"{name}: {ip} is already claimed by another node in secrets/")
        if responds(ip):
            die(f"{name}: {ip} answers a ping - something is already using it.\n"
                f"       Pick a free address, or use ip: auto with a range.")
        taken.add(ip)
        resolved.append((name, cfg, ip))
        print(f"    {name:12s} {ip}  (static, free)")

    # Then the pools.
    auto = [(n, c) for n, c, w in planned if w == "auto"]
    for idx, (name, cfg) in enumerate(auto):
        spec = cfg.get("ip_range") or ""
        if not spec:
            die(f"{name}: ip is 'auto' but no range is set (ip_range, --range, "
                f"or NODE_IP_START/END in nodes.env)")
        try:
            pool = parse_range(spec)
        except ValueError as exc:
            die(f"{name}: bad range {spec!r}: {exc}")
        if not pool:
            die(f"{name}: range {spec!r} contains no addresses")

        ip = None
        for cand in pool:
            if cand in taken or responds(cand):
                continue
            ip = cand
            break
        if ip is None:
            still = len(auto) - idx
            die(f"{name}: no free address left in {spec}.\n"
                f"       Every address in that range is either answering a ping or "
                f"already claimed in secrets/.\n"
                f"       {still} node(s) still need one - widen the range or free some up.")
        taken.add(ip)
        resolved.append((name, cfg, ip))
        print(f"    {name:12s} {ip}  (from {spec})")

    # Preserve the order the nodes were given in.
    order = {n: i for i, (n, _, _) in enumerate(planned)}
    resolved.sort(key=lambda r: order[r[0]])
    return resolved


def hash_password(pw):
    if not shutil.which("openssl"):
        die("openssl not found - needed to hash the root password")
    res = subprocess.run(["openssl", "passwd", "-6", "-stdin"],
                         input=pw, capture_output=True, text=True)
    h = res.stdout.strip()
    if res.returncode != 0 or not h.startswith("$6$"):
        die("'openssl passwd -6' failed (macOS LibreSSL lacks it; install OpenSSL)")
    return h


def disk_section(disk, fs):
    """ext4/xfs take exactly ONE disk: disk-list = ["sda","nvme0n1"] is rejected
    with 'make sure to define only one disk for ext4 and xfs'. A UDEV filter is
    resolved on the target instead, so "auto" installs to whatever the single
    disk is called. That is ambiguous on a multi-disk box - name it there."""
    if disk == "auto":
        return ('# Resolved on the target: installs to whatever the single disk is\n'
                '# called (sda, nvme0n1, ...). Ambiguous on a MULTI-disk machine.\n'
                'filter.DEVNAME = "*"')
    disks = [d.strip() for d in disk.split(",") if d.strip()]
    if fs in ("ext4", "xfs") and len(disks) != 1:
        die(f"filesystem '{fs}' takes exactly one disk, got: {disk}\n"
            f"       use filesystem 'zfs' for several, or name a single disk.")
    return "disk-list  = [" + ", ".join(f'"{d}"' for d in disks) + "]"


def snapshot_secrets(reason):
    """Push a copy of the credential store into /var/backups/pxe-secrets.

    The password and key written above exist in exactly one place until this
    runs. On 2026-09-02 three nodes were lost precisely because that one place
    was the only place - so this is called the instant the files hit disk, not
    at the end of onboarding, and a failure here is loud rather than fatal:
    the credentials are already written and the caller must not unwind them.
    """
    guard = os.path.join(os.path.expanduser("~"), "scripts", "secrets-guard.sh")
    if not os.path.isfile(guard):
        guard = os.path.join(REPO, "scripts", "secrets-guard.sh")
    if not os.path.isfile(guard):
        print("    WARNING: secrets-guard.sh not found - NO BACKUP was taken.")
        print("             Run install.sh, then: ~/scripts/secrets-guard.sh backup")
        return
    try:
        # Pass the store location explicitly: this runs under `sudo
        # ./new-node.py`, where $HOME is /root and any $HOME-derived guess is
        # wrong - which would mean no backup, quietly.
        env = dict(os.environ, ONBOARD_DIR=HERE)
        r = subprocess.run([guard, "backup", "--reason", reason],
                           capture_output=True, text=True, timeout=120, env=env)
        if r.returncode == 0:
            print("    backup      -> /var/backups/pxe-secrets (snapshot taken)")
        else:
            print(f"    WARNING: backup failed ({r.returncode}) - {r.stderr.strip()}")
            print("             This node's credentials have NO second copy yet.")
    except Exception as exc:                                    # noqa: BLE001
        print(f"    WARNING: backup did not run: {exc}")
        print("             This node's credentials have NO second copy yet.")


def write_node(cfg, name, ip, dry_run=False):
    product_name, ui_port = PRODUCTS[cfg.get("product", "pve")]
    fqdn = f"{name}.{cfg['domain']}" if cfg["domain"] else name
    ndir = node_dir(name)
    secret_file = os.path.join(ndir, "credentials.env")
    answer_file = os.path.join(NODES_DIR, f"{name}.answer.toml")

    if os.path.exists(ndir) and not dry_run:
        die(f"{ndir} exists - refusing to overwrite a stored password and key.\n"
            f"       Delete that directory first if you really mean to.")

    password = "".join(pysecrets.choice(PW_ALPHABET) for _ in range(PW_LENGTH))
    pw_hash = hash_password(password)

    # The keypair has to exist before the answer is composed, because the
    # answer embeds its public half.
    if dry_run:
        pubkey = "ssh-ed25519 <generated-at-write-time> root@" + fqdn
    else:
        os.makedirs(SECRETS_DIR, mode=0o700, exist_ok=True)
        os.makedirs(NODES_DIR, mode=0o700, exist_ok=True)
        os.chmod(SECRETS_DIR, 0o700)
        os.makedirs(ndir, mode=0o700, exist_ok=True)
        os.chmod(ndir, 0o700)
        pubkey = generate_ssh_key(ndir, fqdn)

    answer = f"""# {product_name} answer file for {fqdn} - generated by new-node.py.
# THIS WIPES THE TARGET DISK. Credentials + SSH key: secrets/{name}/

[global]
keyboard = "{cfg['keyboard']}"
country  = "{cfg['country']}"
timezone = "{cfg['timezone']}"
fqdn     = "{fqdn}"
mailto   = "{cfg['mailto']}"
root-password-hashed = "{pw_hash}"
"""
    keys = [pubkey]
    if cfg.get("ssh_key"):
        keys.append(cfg["ssh_key"])
    answer += "root-ssh-keys = [" + ", ".join(f'"{k}"' for k in keys) + "]\n"
    answer += f"""
[network]
source  = "from-answer"
cidr    = "{ip}/{cfg['cidr_bits']}"
gateway = "{cfg['gateway']}"
dns     = "{cfg['dns']}"
filter.ID_NET_NAME_MAC = "*"

[disk-setup]
filesystem = "{cfg['filesystem']}"
{disk_section(cfg['disk'], cfg['filesystem'])}
"""

    if dry_run:
        print(f"--- would write {answer_file} ---")
        print(answer.replace(pw_hash, "<hash>"))
        print(f"--- would write {secret_file} (0600) + id_ed25519 keypair in {ndir} ---")
        return None

    # Written FIRST - before the answer file, before any ISO, before serving.
    fd = os.open(secret_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(
            f"# {product_name} node credentials - KEEP. Generated by new-node.py.\n"
            "# This file is gitignored and mode 0600. Second copy (snapshots only):\n"
            "# /var/backups/pxe-secrets/ - see scripts/secrets-guard.sh.\n"
            f"NODE_NAME={name}\nNODE_FQDN={fqdn}\nNODE_IP={ip}\n"
            f"NODE_PRODUCT={cfg.get('product', 'pve')}\n"
            f"NODE_URL=https://{ip}:{ui_port}\nNODE_USER=root@pam\n"
            f"NODE_PASSWORD={password}\nNODE_PASSWORD_HASH={pw_hash}\n"
            f"NODE_SSH_KEY={os.path.join(ndir, 'id_ed25519')}\n"
            f"# ssh -i {os.path.join(ndir, 'id_ed25519')} root@{ip}\n")
    print(f"    password + key -> secrets/{name}/ (0700)")

    fd = os.open(answer_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(answer)
    print(f"    answer file  -> nodes/{name}.answer.toml")

    snapshot_secrets(f"new node {name}")
    return answer_file


def default_answers_dir():
    """Where --serve publishes when not told explicitly.

    Run on the PXE server itself, that is the directory the answer server
    actually reads, so enrolling a machine is genuinely one command. Run
    anywhere else there is no such directory, so it stays local and has to be
    copied across - which the caller is told about, rather than silently
    writing somewhere nothing will ever read.
    """
    env = os.environ.get("PXE_ANSWER_DIR")
    if env:
        return env
    if os.path.isdir("/srv/pxe/answers"):
        return "/srv/pxe/answers"
    return os.path.join(HERE, "answers")


def serve_answer(answer_file, name, mac, answers_dir):
    """Publish the answer file for the answer server to hand out.

    Named after the MAC when one is known, because that is the only thing the
    installer reliably tells the server about itself. Without a MAC it becomes
    default.toml, which every machine matches - fine when onboarding one at a
    time, dangerous when several could netboot at once, so say so.
    """
    target_dir = answers_dir or default_answers_dir()
    os.makedirs(target_dir, mode=0o750, exist_ok=True)
    if mac:
        norm = re.sub(r"[^0-9a-f]", "", str(mac).lower())
        if len(norm) != 12:
            die(f"{name}: --mac {mac!r} is not a MAC address")
        dest = os.path.join(target_dir, f"{norm}.toml")
        note = f"matched by MAC {mac}"
    else:
        dest = os.path.join(target_dir, "default.toml")
        note = ("as default.toml - EVERY machine that netboots gets this one. "
                "Pass --mac to target a single machine.")
    shutil.copyfile(answer_file, dest)
    # The answer server runs as an unprivileged user (www-data) while this
    # usually runs under sudo, so a plain copy lands root:root and the server
    # cannot read its own answers - the install then fails at fetch time with
    # nothing obviously wrong on disk. Inherit the directory's group, which
    # install.sh set up for exactly this.
    try:
        os.chown(dest, -1, os.stat(target_dir).st_gid)
    except (PermissionError, OSError):
        print(f"    WARNING: could not set the group on {dest};")
        print(f"             check the answer server can read it.")
    os.chmod(dest, 0o640)
    print(f"    served -> {dest} ({note})")
    if not dest.startswith("/srv/pxe/"):
        print(f"    NOTE: that is a local directory. The answer server reads")
        print(f"          /srv/pxe/answers on the PXE server - copy it across:")
        print(f"            scp {dest} <user>@<pxe>:/srv/pxe/answers/")


def validate(answer_file):
    helper = os.path.join(HERE, "prepare-auto-iso.sh")
    if not os.access(helper, os.X_OK):
        print("    (prepare-auto-iso.sh missing - skipping validation)")
        return True
    # The validator is proxmox-auto-install-assistant, which is amd64-only and
    # so runs in a container. The PXE server itself typically has no Docker, and
    # "cannot check" is NOT "invalid" - reporting a perfectly good answer file
    # as failed is worse than not checking it.
    if not shutil.which("docker"):
        print("    (no docker here - skipping validation; run "
              "prepare-auto-iso.sh --validate where it is available)")
        return True
    res = subprocess.run([helper, "--validate", answer_file],
                         capture_output=True, text=True)
    if res.returncode != 0:
        print(res.stdout + res.stderr, file=sys.stderr)
        return False
    print("    validated")
    return True


# --------------------------------------------------------------------------
def ask(prompt, default=""):
    suffix = f" [{default}]" if default != "" else ""
    try:
        got = input(f"  {prompt}{suffix}: ").strip()
    except (EOFError, KeyboardInterrupt):
        print()
        die("cancelled")
    return got or str(default)


def interactive(cfg):
    print("Interactive node setup. Enter accepts the [default].\n")
    name = ""
    while not name:
        name = ask("machine name")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*[A-Za-z0-9]|[A-Za-z0-9]", name):
            print("    not a valid hostname")
            name = ""
    cfg["domain"] = ask("domain (FQDN becomes <name>.<domain>)", cfg["domain"])

    print("\n  Address: enter a static IP, or a range to auto-pick the first free one.")
    cfg["ip_range"] = ask("static IP or range (a.b.c.d or a.b.c.d-e.f.g.h)", cfg["ip_range"])
    cfg["cidr_bits"] = int(ask("prefix length", cfg["cidr_bits"]))
    cfg["gateway"] = ask("gateway", cfg["gateway"])
    cfg["dns"] = ask("dns", cfg["dns"])

    print()
    cfg["filesystem"] = ask("filesystem (ext4/xfs/zfs/btrfs)", cfg["filesystem"])
    cfg["disk"] = ask("disk ('auto' = whatever the single disk is called)", cfg["disk"])
    cfg["mailto"] = ask("admin email", cfg["mailto"])
    return [{"name": name}], cfg


def main():
    ap = argparse.ArgumentParser(
        description="Provision Proxmox nodes from prompts, flags or a YAML/JSON file.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Settings resolve: CLI > per-node in file > file defaults > nodes.env > built-in.")
    ap.add_argument("name", nargs="?", help="machine name (omit for interactive)")
    ap.add_argument("-f", "--file", help="YAML or JSON file describing one or more nodes")
    ap.add_argument("-i", "--interactive", action="store_true", help="force prompts")
    ap.add_argument("--ip", help="static address, or 'auto' to take one from the range")
    ap.add_argument("--range", dest="ip_range", help="pool to allocate from, e.g. 192.0.2.10-40")
    ap.add_argument("--gateway")
    ap.add_argument("--dns")
    ap.add_argument("--domain")
    ap.add_argument("--disk", help="'auto', a name, or a comma list (zfs/btrfs only)")
    ap.add_argument("--fs", dest="filesystem", help="ext4|xfs|zfs|btrfs")
    ap.add_argument("--mailto")
    ap.add_argument("--product", choices=sorted(PRODUCTS),
                    help="which Proxmox installer this answer file is for "
                         "(default: pve; pdm = Datacenter Manager, web UI on 8443)")
    ap.add_argument("--mac", help="target NIC MAC - names the answer file for fleet mode")
    ap.add_argument("--serve", action="store_true",
                    help="also copy the answer into the answer server's directory "
                         "(fleet mode: no per-machine ISO rebuild)")
    ap.add_argument("--answers-dir", default=os.environ.get("PXE_ANSWER_DIR", ""),
                    help="where --serve writes (default: $PXE_ANSWER_DIR, else /srv/pxe/answers if present, else ./answers)")
    ap.add_argument("--dry-run", action="store_true", help="show what would be written")
    args = ap.parse_args()

    cfg = dict(DEFAULTS)
    cfg.update(load_env_file(os.path.join(HERE, "nodes.env")))

    nodes = []
    if args.file:
        doc = load_config_file(args.file)
        if not isinstance(doc, dict):
            die(f"{args.file}: expected a mapping at the top level")
        cfg.update({k: v for k, v in (doc.get("defaults") or {}).items() if v is not None})
        nodes = doc.get("nodes") or []
        if not nodes:
            die(f"{args.file}: no 'nodes:' entries found")
    elif args.name and not args.interactive:
        nodes = [{"name": args.name}]
    else:
        nodes, cfg = interactive(cfg)

    for k in ("ip_range", "gateway", "dns", "domain", "disk", "filesystem", "mailto",
              "product"):
        if getattr(args, k, None):
            cfg[k] = getattr(args, k)

    # Nothing is created until every address is known to be usable.
    resolved = preflight(nodes, cfg, args)

    ok = True
    for name, node_cfg, ip in resolved:
        print(f"==> {name}")
        answer_file = write_node(node_cfg, name, ip, dry_run=args.dry_run)
        if answer_file and args.serve:
            serve_answer(answer_file, name, node_cfg.get("mac") or args.mac,
                         args.answers_dir)
        if answer_file and not validate(answer_file):
            print(f"    VALIDATION FAILED - the password is still in secrets/{name}.env",
                  file=sys.stderr)
            ok = False
            continue
        if not args.dry_run:
            _, ui_port = PRODUCTS[node_cfg.get("product", "pve")]
            print(f"    {name}.{node_cfg['domain']} -> https://{ip}:{ui_port}")

    if not ok:
        sys.exit(1)
    if not args.dry_run and nodes:
        print("\nNext:")
        print("  ./new_machine_onboarding/prepare-auto-iso.sh \\")
        print("      new_machine_onboarding/nodes/<name>.answer.toml <proxmox.iso>")
        if cfg.get("product") == "pdm":
            print("  then payloads/build-pdm.sh --iso <that>-auto.iso --name pdm")
        else:
            print("  then payloads/build-proxmox.sh --iso <that>-auto.iso --name pve-auto")
        print("  IT WILL ERASE THE TARGET'S DISK WITHOUT ASKING.")


if __name__ == "__main__":
    main()
