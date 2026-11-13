#!/usr/bin/env python3
"""Let AI work out program, reference and input files for an ssbatch job.

Used by ssbatch when the user did not give -P, -R or -I. Prints one line:

    <program>\t<reference>\t<comma-separated inputs>\t<source>\t<key>

source is "cache" (no AI call), "ai" (fresh AI call, now cached) or "none"
(AI unavailable or answer rejected; ssbatch then keeps its old behaviour).
Empty fields are printed as "-". This script never fails a submission: on any
error it prints the "none" line and exits 0.

AI only names things. Sizes are measured by estimateResource.sh with du, and
memory/time still come from the job-record fit.

Cache: <smartSbatchJobRecordDir>/aiCache/<key>.json, one file per distinct job
script / command shape. File paths and script arguments are left out of the
key, so every sample of the same step shares one entry. Edit an entry to fix
a wrong guess; delete it to force a new AI call.
"""

import hashlib
import json
import os
import re
import shlex
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    import aiHelper
except ImportError:
    aiHelper = None

MAX_SCRIPT = 20000
PATH_RE = re.compile(r"(?<![\w$])(?:\.{0,2}/)?[\w.+-]+(?:/[\w.+-]+)+|[\w.+-]+\.[A-Za-z][\w.]*")


def out(program="-", ref="-", inputs="-", source="none", key="-"):
    print("\t".join([program or "-", ref or "-", inputs or "-", source, key]))
    sys.exit(0)


def cache_key(text, core):
    masked = PATH_RE.sub("<PATH>", text)
    masked = re.sub(r"\s+", " ", masked).strip()
    return hashlib.md5(("%s\ncore=%s" % (masked, core)).encode()).hexdigest()[:16]


def tokens_of(text):
    try:
        return shlex.split(text, comments=True)
    except ValueError:
        return text.split()


VAR_RE = re.compile(r"\$\{(\w+)\}|\$(\w+)")
ASSIGN_RE = re.compile(r"^\s*(?:export\s+|local\s+)?([A-Za-z_]\w*)=(\S*)\s*$")


def expand_script(body, params):
    """Substitute $1.. and simple `name=value` assignments into the script text.

    Static only: nothing is executed, and values containing command
    substitution or arithmetic are left alone. Unknown variables stay as-is.
    """
    env = {str(i + 1): p for i, p in enumerate(params)}
    env["@"] = env["*"] = " ".join(params)

    def sub(text):
        return VAR_RE.sub(lambda m: env.get(m.group(1) or m.group(2), m.group(0)), text)

    out = []
    for line in body.splitlines():
        line = sub(line)
        m = ASSIGN_RE.match(line)
        if m and "$(" not in m.group(2) and "`" not in m.group(2):
            env[m.group(1)] = m.group(2).strip("\"'")
        out.append(line)
    return "\n".join(out)


def local_inputs(tokens, rule, skip):
    """Apply the cached rule (flags + extensions) to this job's own tokens."""
    flags = set(rule.get("input_flags") or [])
    exts = tuple(e.lower() for e in (rule.get("input_extensions") or []) if e)
    found = []
    for i, tok in enumerate(tokens):
        for part in tok.split(","):
            if not part or part in skip or part in found or not os.path.exists(part):
                continue
            by_flag = i > 0 and tokens[i - 1] in flags
            by_ext = exts and part.lower().endswith(exts)
            if by_flag or by_ext:
                found.append(part)
    return found


def ask_ai(text, core):
    prompt = (
        "You read a Slurm job and identify what drives its memory and run-time. "
        "Reply with ONLY one JSON object, no prose, with keys:\n"
        '  "program": the main bioinformatics/compute tool actually doing the work '
        '(e.g. "bowtie2", "STAR", "samtools-sort"), not the shell or script name; '
        "letters, digits, . _ - only.\n"
        '  "reference": short genome/reference label if one is used (e.g. "hg38", '
        '"mm10"), else "none".\n'
        '  "inputs": list of the data input files/folders whose size drives the '
        "cost, exactly as written in the job (exclude references, indexes, "
        "outputs, the script itself).\n"
        '  "input_flags": command-line options that precede those inputs (e.g. '
        '["-1","-2","-U"]), or [].\n'
        '  "input_extensions": file suffixes of the inputs (e.g. [".fq.gz",".bam"]).\n'
        '  "scales_with": "input" or "none".\n\n'
        "Cores requested: %s\n\nJob:\n%s" % (core, text[:MAX_SCRIPT])
    )
    answer = aiHelper.ai_ask(prompt) if aiHelper else None
    if not answer:
        return None
    m = re.search(r"\{.*\}", answer, re.S)
    try:
        return json.loads(m.group(0)) if m else None
    except ValueError:
        return None


def clean_name(value):
    value = re.sub(r"[^\w.-]", "-", str(value or "")).strip("-.")
    return value[:60]


def main():
    if len(sys.argv) < 4:
        out()
    record_dir, core, kind = sys.argv[1], sys.argv[2], sys.argv[3]
    rest = sys.argv[4:]

    if kind == "wrap":
        text = " ".join(rest)
        tokens = tokens_of(text)
        skip = set()
        key_text = text
    elif kind == "script" and rest and os.path.isfile(rest[0]):
        script = rest[0]
        try:
            body = Path(script).read_text(errors="replace")
        except OSError:
            out()
        params = " ".join(rest[1:])
        text = "Script arguments: %s\n\n%s" % (params, body)
        # Lines of the script plus its arguments; inputs may be in either.
        # Expand $1/$s etc. so ${s}_R1.fq.gz becomes this sample's real file.
        tokens = tokens_of(params) + tokens_of(expand_script(body, rest[1:]))
        skip = {script}
        key_text = body  # arguments differ per sample, keep them out of the key
    else:
        out()

    key = cache_key(key_text, core)
    cache_dir = Path(record_dir) / "aiCache"
    cache_file = cache_dir / ("%s.json" % key)

    rule, source = None, "cache"
    if cache_file.is_file():
        try:
            rule = json.loads(cache_file.read_text())
        except ValueError:
            rule = None
    if rule is None:
        rule = ask_ai(text, core)
        source = "ai"
        if not isinstance(rule, dict):
            out(key=key)

    program = clean_name(rule.get("program"))
    ref = clean_name(rule.get("reference")) or "none"

    # Reject a program name that is not in the job at all (hallucination).
    if not program or program.split("-")[0].lower() not in text.lower():
        out(key=key)
    program = "%s-%score" % (program, core)

    if source == "ai":
        inputs = [p for p in (rule.get("inputs") or []) if isinstance(p, str)
                  and p not in skip and os.path.exists(p)]
        if not inputs:
            inputs = local_inputs(tokens, rule, skip)
        try:
            cache_dir.mkdir(parents=True, exist_ok=True)
            saved = {k: rule.get(k) for k in
                     ("program", "reference", "input_flags", "input_extensions", "scales_with")}
            saved["example"] = text[:500]
            cache_file.write_text(json.dumps(saved, indent=1) + "\n")
        except OSError:
            pass
    else:
        inputs = local_inputs(tokens, rule, skip)

    if rule.get("scales_with") == "none":
        inputs = []
    out(program, ref, ",".join(inputs), source, key)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        out()
