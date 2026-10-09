#!/usr/bin/env python3
"""Tests for paseo/bin/slp-journal: real CLI subprocesses, temp dirs only."""
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
import warnings

warnings.simplefilter("ignore", ResourceWarning)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.path.join(ROOT, "paseo", "bin", "slp-journal")
SCHEMA = os.path.join(ROOT, "paseo", "schemas", "room-message.v1.schema.json")
ENV = {k: v for k, v in os.environ.items() if k != "SLP_JOURNAL"}


def run(args, stdin=None):
    p = subprocess.run([sys.executable, CLI] + args, input=stdin, capture_output=True, text=True, env=ENV)
    try:
        j = json.loads(p.stdout) if p.stdout.strip().startswith("{") else p.stdout
    except ValueError:
        j = p.stdout
    return p.returncode, j


def fd_path(fd):
    """Path of an open fd: F_GETPATH on macOS, /proc/self/fd (or /dev/fd) elsewhere."""
    if sys.platform == "darwin":
        import fcntl
        return os.fsdecode(fcntl.fcntl(fd, fcntl.F_GETPATH, b"\0" * 1024).split(b"\0")[0])
    for tpl in ("/proc/self/fd/%d", "/dev/fd/%d"):
        try:
            return os.path.realpath(os.readlink(tpl % fd))
        except OSError:
            continue
    raise unittest.SkipTest("no way to map an fd to its path on this platform")


def cid_of(ident):
    c = {"base": ident["base"], "changedPaths": sorted(set(ident["changedPaths"])),
         "evidenceRefs": sorted(set(ident.get("evidenceRefs", [])))}
    for k in ("commit", "patchSha256"):
        if k in ident:
            c[k] = ident[k]
    return hashlib.sha256(json.dumps(c, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def env(mid, signal, task="t1", sender="lead", recipient="peer", cid=None, payload=None, **kw):
    e = {"version": 1, "roomId": "r1", "taskId": task, "messageId": mid, "causationId": None,
         "senderAgentId": sender, "recipientAgentId": recipient, "signal": signal,
         "createdAt": "2026-01-01T00:00:00Z", "payload": payload or {}}
    if cid:
        e["candidateId"] = cid
    e.update(kw)
    return e


def ident(n, paths=("a.txt",)):
    return {"base": "d935943", "commit": ("%07x" % n), "changedPaths": list(paths), "evidenceRefs": ["ev/%d" % n]}


class Base(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.addCleanup(self.td.cleanup)
        self.dir = os.path.realpath(self.td.name)
        self.j = os.path.join(self.dir, "j", "room.jsonl")
        self.proj = os.path.join(self.dir, "proj")
        for d in ("src/a/b", "src/ab", "other/x"):
            os.makedirs(os.path.join(self.proj, d))

    def app(self, e):
        return run(["--journal", self.j, "append", "-"], json.dumps(e))

    def ok(self, e):
        rc, r = self.app(e)
        self.assertEqual(rc, 0, r)
        return r

    def rej(self, e, reason):
        rc, r = self.app(e)
        self.assertEqual(rc, 3, r)
        self.assertEqual(r["reason"], reason, r)

    def state(self):
        rc, r = run(["--journal", self.j, "state"])
        self.assertEqual(rc, 0, r)
        return r

    def brief(self, mid="b1", task="t1", owner="peer", paths=("src/a",), root=None):
        return self.ok(env(mid, "BRIEF", task=task, recipient=owner,
                           payload={"writeScope": {"root": root or self.proj, "paths": list(paths)}}))

    def cand(self, mid, n, task="t1", owner="peer"):
        i = ident(n)
        c = cid_of(i)
        self.ok(env(mid, "CANDIDATE", task=task, sender=owner, recipient="lead", cid=c, payload={"identity": i}))
        return c

    def review(self, mid, c, task="t1"):
        self.ok(env(mid, "REVIEW", task=task, sender="peer", cid=c, payload={"kind": "candidate", "verdict": "ok"}))

    def accept(self, mid, c, rid, task="t1"):
        return env(mid, "ACCEPT", task=task, cid=c, payload={"reviewMessageId": rid})


class SchemaTests(Base):
    def test_valid_envelope_and_cli_basics(self):
        self.assertEqual(run(["--version"])[1].strip(), "slp-journal envelope-v1")
        self.assertEqual(run(["--self-check"])[0], 0)
        self.ok(env("m1", "QUESTION"))
        f = os.path.join(self.dir, "e.json")
        json.dump(env("m2", "ACK"), open(f, "w"))
        self.assertEqual(run(["validate", f])[0], 0)

    def test_rejections(self):
        base = env("m1", "QUESTION")
        for k in ["version", "roomId", "taskId", "messageId", "causationId", "senderAgentId",
                  "recipientAgentId", "signal", "createdAt", "payload"]:
            e = dict(base); del e[k]
            rc, r = run(["--journal", self.j, "append", "-"], json.dumps(e))
            self.assertEqual((rc, r["reason"], r["detail"]), (3, "missing-field", k))
        cases = [
            ({"version": 2}, "bad-version"), ({"version": True}, "bad-version"),
            ({"signal": "question"}, "bad-signal"), ({"extra": 1}, "unknown-field"),
            ({"candidateId": "xyz"}, "bad-candidateId"), ({"messageId": "../x"}, "bad-id"),
            ({"messageId": "a" * 129}, "bad-id"), ({"createdAt": "2026-01-01T00:00:00+01:00"}, "bad-createdAt"),
            ({"createdAt": "2026-13-45T00:00:00Z"}, "bad-createdAt"), ({"payload": []}, "bad-payload"),
            ({"payload": {"blob": "x" * 17000}}, "payload-too-large"),
            ({"signal": "ACCEPT"}, "missing-field"), ({"signal": "REVIEW", "payload": {}}, "bad-review-kind"),
            ({"signal": "REVIEW", "payload": {"kind": "candidate"}}, "missing-field"),
            ({"signal": "REVIEW", "payload": {"kind": "plan"}, "candidateId": "a" * 64}, "unexpected-candidateId"),
        ]
        for patch, reason in cases:
            rc, r = run(["--journal", self.j, "append", "-"], json.dumps({**base, **patch}))
            self.assertEqual((rc, r["reason"]), (3, reason), (patch, r))
        self.assertEqual(run(["--journal", self.j, "append", "-"], "not json")[1]["reason"], "unreadable-json")
        self.assertEqual(self.state()["lastSeq"], 0)

    def test_noncandidate_reviews_ok(self):
        for i, k in enumerate(["plan", "watch", "other"]):
            self.ok(env("rv%d" % i, "REVIEW", payload={"kind": k}))

    def test_validator_agrees_with_schema(self):
        sch = json.load(open(SCHEMA))
        c = run(["contract"])[1]
        self.assertEqual(sch["properties"]["version"]["const"], c["version"])
        self.assertEqual(sch["required"], c["required"])
        self.assertEqual(sorted(sch["properties"]), sorted(c["required"] + c["optional"]))
        self.assertFalse(sch["additionalProperties"])
        self.assertEqual(sch["properties"]["signal"]["enum"], c["signals"])
        self.assertEqual(sch["properties"]["candidateId"]["pattern"], c["candidateIdPattern"])
        self.assertEqual(sch["properties"]["createdAt"]["pattern"], c["timePattern"])
        self.assertEqual(sch["$defs"]["id"]["pattern"], c["idPattern"])
        self.assertEqual(sch["$defs"]["id"]["maxLength"], c["idMaxLength"])
        self.assertEqual(sch["properties"]["payload"]["x-maxSerializedBytes"], c["payloadMaxBytes"])
        self.assertEqual(sch["allOf"][0]["if"]["properties"]["signal"]["enum"], c["candidateRequiredSignals"])
        self.assertEqual(sch["allOf"][1]["then"]["properties"]["payload"]["properties"]["kind"]["enum"], c["reviewKinds"])
        self.assertEqual(run(["--version"])[1].strip(), "slp-journal envelope-v%d" % sch["properties"]["version"]["const"])


class DedupTests(Base):
    def test_accept_three_times_one_transition(self):
        self.brief()
        c = self.cand("c1", 1)
        self.review("rv1", c)
        a = self.accept("acc1", c, "rv1")
        first = self.ok(a)
        self.assertFalse(first["duplicate"])
        for _ in range(2):
            r = self.ok(a)
            self.assertEqual((r["duplicate"], r["seq"]), (True, first["seq"]))
        t = self.state()["tasks"]["t1"]
        self.assertEqual(len(t["acceptances"]), 1)
        self.assertEqual(self.state()["lastSeq"], first["seq"])

    def test_conflicting_duplicate_and_delivery_rules(self):
        self.ok(env("m1", "QUESTION"))
        self.rej(env("m1", "QUESTION", payload={"q": "other"}), "conflict")
        d = lambda s: run(["--journal", self.j, "deliver", "m1", s])
        self.assertEqual(d("delivered")[0], 0)
        rc, r = d("delivered")
        self.assertEqual((rc, r["duplicate"]), (0, True))
        self.assertEqual(d("processed")[1]["reason"], "state-out-of-order")
        self.assertEqual(d("processing")[0], 0)
        self.assertEqual(d("processed")[0], 0)
        rc, r = d("delivered")
        self.assertEqual((rc, r["reason"]), (3, "state-regression"))
        self.assertEqual(run(["--journal", self.j, "deliver", "nope", "delivered"])[1]["reason"], "unknown-message")
        self.assertEqual(d("bogus")[1]["reason"], "bad-delivery-state")
        self.assertEqual(self.state()["messages"]["m1"]["state"], "processed")


class ConcurrencyAndCrashTests(Base):
    def test_concurrent_appends_gapless(self):
        n, m = 8, 12
        script = ("import subprocess,sys,json\nw=sys.argv[1]\nfor i in range(%d):\n"
                  " e=%r.replace('MID','%%s-%%d'%%(w,i))\n"
                  " p=subprocess.run([sys.executable,%r,'--journal',%r,'append','-'],input=e,text=True,capture_output=True)\n"
                  " assert p.returncode==0,p.stdout\n") % (m, json.dumps(env("MID", "QUESTION")), CLI, self.j)
        procs = [subprocess.Popen([sys.executable, "-c", script, "w%d" % w]) for w in range(n)]
        self.assertTrue(all(p.wait() == 0 for p in procs))
        lines = open(self.j).read().splitlines()
        recs = [json.loads(l) for l in lines]
        self.assertEqual([r["seq"] for r in recs], list(range(1, n * m + 1)))
        self.assertEqual(len({r["envelope"]["messageId"] for r in recs}), n * m)
        self.assertEqual(oct(os.stat(self.j).st_mode & 0o777), "0o600")
        self.assertEqual(oct(os.stat(os.path.dirname(self.j)).st_mode & 0o777), "0o700")

    def test_torn_tail_repaired_then_append(self):
        self.ok(env("m1", "QUESTION"))
        torn = b'{"seq":2,"entryId":"x","kind":"mess'
        with open(self.j, "ab") as f:
            f.write(torn)
        r = self.ok(env("m2", "QUESTION"))
        self.assertEqual(r["seq"], 2)
        self.assertEqual(r["repaired"]["truncatedBytes"], len(torn))
        self.assertEqual(self.state()["lastSeq"], 2)

    def test_interior_corruption_hard_error(self):
        self.ok(env("m1", "QUESTION")); self.ok(env("m2", "QUESTION")); self.ok(env("m3", "QUESTION"))
        lines = open(self.j).read().splitlines()
        lines[1] = lines[1][:20]
        open(self.j, "w").write("\n".join(lines) + "\n")
        before = open(self.j).read()
        rc, r = self.app(env("m4", "QUESTION"))
        self.assertEqual((rc, r["reason"]), (4, "journal-corrupt"))
        self.assertIn("seq 2", r["detail"])
        self.assertEqual(open(self.j).read(), before)
        self.assertEqual(run(["--journal", self.j, "state"])[0], 4)

    def test_restart_recovery_and_replayed_accept(self):
        self.brief()
        c1 = self.cand("c1", 1)
        c2 = self.cand("c2", 2)
        self.review("rv2", c2)
        a = self.accept("acc", c2, "rv2")
        self.ok(a)
        for m, s in [("c1", "delivered"), ("c1", "processing"), ("acc", "delivered")]:
            self.assertEqual(run(["--journal", self.j, "deliver", m, s])[0], 0)
        st = self.state()
        t = st["tasks"]["t1"]
        self.assertEqual((t["owner"], t["currentCandidate"], t["acceptedCandidate"], t["candidates"]), ("peer", c2, c2, [c1, c2]))
        self.assertEqual(st["needsReconcile"], ["c1"])
        self.assertIn("acc", st["unprocessed"])
        self.assertIn("b1", st["unprocessed"])
        self.assertEqual(self.ok(a)["duplicate"], True)
        self.assertEqual(len(self.state()["tasks"]["t1"]["acceptances"]), 1)
        self.assertEqual(self.state()["needsReconcile"], ["c1"])


class StaleCandidateTests(Base):
    def test_stale_and_mismatch(self):
        self.brief()
        self.brief("b2", task="t2", owner="peer2", paths=("other/x",))
        c1 = self.cand("c1", 1)
        self.review("rv1", c1)
        c2 = self.cand("c2", 2)
        self.rej(self.accept("acc1", c2, "rv1"), "review-mismatch")
        self.rej(self.accept("acc2", c1, "rv1"), "stale-candidate")
        self.rej(env("acc3", "ACCEPT", cid=c2, payload={}), "review-required")
        self.rej(env("acc4", "ACCEPT", cid=c2, payload={"reviewWaived": "  "}), "review-required")
        self.rej(self.accept("acc5", c2, "rv1", task="t2"), "cross-task-candidate")
        self.rej(env("acc6", "ACCEPT", cid="f" * 64, payload={"reviewWaived": "x"}), "unknown-candidate")
        self.review("rv2", c2)
        self.ok(self.accept("acc7", c2, "rv2"))
        self.rej(self.accept("acc8", c2, "rv2"), "already-accepted")
        self.rej(env("rej1", "REJECT", cid=c2), "already-accepted")
        self.assertEqual(len(self.state()["tasks"]["t1"]["acceptances"]), 1)

    def test_waived_and_reject_keep_scope(self):
        self.brief()
        c = self.cand("c1", 1)
        self.ok(env("rj", "REJECT", cid=c, payload={"reason": "repair"}))
        t = self.state()["tasks"]["t1"]
        self.assertFalse(t["scopeReleased"])
        c2 = self.cand("c2", 2)
        self.ok(env("acc", "ACCEPT", cid=c2, payload={"reviewWaived": "trivial doc"}))
        self.assertTrue(self.state()["tasks"]["t1"]["scopeReleased"])

    def test_candidate_identity(self):
        self.brief()
        i = ident(1)
        self.rej(env("c1", "CANDIDATE", sender="peer", cid="0" * 64, payload={"identity": i}), "candidate-id-mismatch")
        self.rej(env("c2", "CANDIDATE", sender="peer", cid=cid_of(i), payload={}), "bad-identity")
        self.rej(env("c3", "CANDIDATE", sender="peer", cid=cid_of(i), payload={"identity": {**i, "changedPaths": ["../x"]}}), "bad-path")
        self.rej(env("c4", "CANDIDATE", sender="intruder", cid=cid_of(i), payload={"identity": i}), "not-owner")
        f = os.path.join(self.dir, "i.json")
        json.dump({**i, "changedPaths": ["b/./c", "a.txt", "a.txt"]}, open(f, "w"))
        self.assertEqual(run(["candidate-id", f])[1]["candidateId"], cid_of({**i, "changedPaths": ["a.txt", "b/c"]}))
        self.cand("c5", 1)
        self.rej(env("c6", "CANDIDATE", sender="peer", cid=cid_of(i), payload={"identity": i}), "candidate-exists")


class ScopeTests(Base):
    def conflict(self, paths, mid="bx"):
        self.rej(env(mid, "BRIEF", task="t" + mid, recipient="other", payload={"writeScope": {"root": self.proj, "paths": paths}}),
                 "scope-conflict")

    def test_overlap_rules(self):
        self.brief()
        self.conflict(["src/a"], "b2")
        self.conflict(["src/a/b"], "b3")
        self.conflict(["src"], "b4")
        self.conflict(["."], "b5")
        self.ok(env("b6", "BRIEF", task="t6", recipient="other", payload={"writeScope": {"root": self.proj, "paths": ["src/ab"]}}))
        self.rej(env("b7", "BRIEF", task="t7", recipient="peer", payload={"writeScope": {"root": self.proj, "paths": ["src/a/b"]}}),
                 "scope-conflict")
        self.rej(env("b8", "BRIEF", task="t8", recipient="other", payload={"writeScope": {"root": self.proj, "paths": ["../x"]}}), "scope-escape")
        self.rej(env("b9", "BRIEF", task="t9", recipient="other", payload={"writeScope": {"root": self.proj, "paths": ["/etc"]}}), "scope-escape")

    def test_symlink_and_release(self):
        os.symlink(os.path.join(self.proj, "src", "a"), os.path.join(self.proj, "other", "link"))
        os.symlink("/tmp", os.path.join(self.proj, "other", "esc"))
        self.brief()
        self.conflict(["other/link"], "b2")
        self.rej(env("b3", "BRIEF", task="t3", recipient="other", payload={"writeScope": {"root": self.proj, "paths": ["other/esc"]}}), "scope-escape")
        c = self.cand("c1", 1)
        self.ok(env("acc", "ACCEPT", cid=c, payload={"reviewWaived": "ok"}))
        self.ok(env("b4", "BRIEF", task="t4", recipient="other", payload={"writeScope": {"root": self.proj, "paths": ["src/a"]}}))

    def test_cli_subcommand(self):
        def ov(a, b):
            rc, r = run(["scope-overlap", "--root", self.proj, "--a", a, "--b", b])
            self.assertEqual(rc, 0, r)
            return r["overlap"]
        self.assertTrue(ov("src/a", "src/a/b"))
        self.assertFalse(ov("src/a", "src/ab"))
        self.assertEqual(run(["scope-overlap", "--root", self.proj, "--a", "../x", "--b", "src"])[0], 3)

    def test_duplicate_task_brief_rejected(self):
        self.brief()
        self.rej(env("b2", "BRIEF", recipient="peer", payload={"writeScope": {"root": self.proj, "paths": ["src/ab"]}}), "task-exists")


class ReviewRepairTests(Base):
    def test_alias_shares_lock(self):
        self.ok(env("seed", "QUESTION"))
        alias = os.path.join(self.dir, "alias.jsonl")
        os.symlink(self.j, alias)
        script = ("import subprocess,sys\nw,jp=sys.argv[1:3]\nfor i in range(10):\n"
                  " e=%r.replace('MID','%%s-%%d'%%(w,i))\n"
                  " p=subprocess.run([sys.executable,%r,'--journal',jp,'append','-'],input=e,text=True,capture_output=True)\n"
                  " assert p.returncode==0,p.stdout\n") % (json.dumps(env("MID", "QUESTION")), CLI)
        procs = [subprocess.Popen([sys.executable, "-c", script, "w%d" % w, self.j if w % 2 else alias]) for w in range(8)]
        self.assertTrue(all(p.wait() == 0 for p in procs))
        recs = [json.loads(l) for l in open(self.j).read().splitlines()]
        self.assertEqual([r["seq"] for r in recs], list(range(1, 82)))
        self.assertEqual(len({r["envelope"]["messageId"] for r in recs}), 81)

    def test_nested_roots_overlap(self):
        sub = lambda *x: os.path.join(self.proj, *x)
        brief = lambda mid, task, who, root, paths: env(mid, "BRIEF", task=task, recipient=who,
                                                         payload={"writeScope": {"root": root, "paths": paths}})
        self.ok(brief("b1", "t1", "A", self.proj, ["src/a"]))
        self.rej(brief("b2", "t2", "B", sub("src"), ["."]), "scope-conflict")
        self.rej(brief("b3", "t3", "B", sub("src", "a"), ["b"]), "scope-conflict")
        self.ok(brief("b4", "t4", "B", sub("other"), ["x"]))
        self.ok(brief("b5", "t5", "C", sub("src", "ab"), ["."]))
        self.ok(brief("b6", "t6", "D", self.proj, ["src/abc"]))

    def test_scope_persisted_not_recomputed(self):
        link = os.path.join(self.proj, "lnk")
        os.symlink(os.path.join(self.proj, "src", "a"), link)
        self.brief(paths=("lnk",))
        before = self.state()["tasks"]["t1"]["writeScope"]
        self.assertEqual(before["paths"], ["src/a"])
        os.unlink(link)
        os.symlink(os.path.join(self.proj, "other"), link)
        after = self.state()["tasks"]["t1"]["writeScope"]
        self.assertEqual(after, before)
        self.ok(env("m9", "QUESTION", sender="peer", recipient="lead"))
        rec = json.loads(open(self.j).read().splitlines()[0])
        self.assertIn("resolvedScope", rec)
        self.assertNotIn("resolvedScope", rec["envelope"])
        self.rej(env("b2", "BRIEF", task="t2", recipient="Z", payload={"writeScope": {"root": self.proj, "paths": ["src/a"]}}), "scope-conflict")

    def test_unreadable_journal_is_error(self):
        if os.geteuid() == 0:
            self.skipTest("root ignores file modes")
        self.ok(env("m1", "QUESTION"))
        os.chmod(self.j, 0)
        self.addCleanup(os.chmod, self.j, 0o600)
        rc, r = run(["--journal", self.j, "state"])
        self.assertEqual((rc, r["reason"]), (4, "io-error"))
        self.assertEqual(self.app(env("m2", "QUESTION"))[0], 4)

    def test_corrupt_prefix_with_torn_tail_untouched(self):
        os.makedirs(os.path.dirname(self.j))
        raw = b'INVALID\n{"torn":'
        with open(self.j, "wb") as f:
            f.write(raw)
        os.chmod(self.j, 0o600)
        rc, r = self.app(env("m1", "QUESTION"))
        self.assertEqual((rc, r["reason"]), (4, "journal-corrupt"))
        self.assertEqual(open(self.j, "rb").read(), raw)

    def test_permissions_enforced(self):
        self.ok(env("m1", "QUESTION"))
        os.chmod(self.j, 0o644)
        self.assertEqual(run(["--journal", self.j, "state"])[0], 0)
        self.assertEqual(oct(os.stat(self.j).st_mode & 0o777), "0o600")
        os.chmod(self.j, 0o666)
        self.ok(env("m2", "QUESTION"))
        self.assertEqual(oct(os.stat(self.j).st_mode & 0o777), "0o600")

    def test_not_owned_open_mode_refused(self):
        src = open(CLI).read()
        self.assertIn("journal-permissions", src)
        self.assertIn("st.st_uid != os.geteuid()", src)

    def test_dir_fsync_on_create(self):
        import importlib.machinery, importlib.util
        loader = importlib.machinery.SourceFileLoader("slpj", CLI)
        m = importlib.util.module_from_spec(importlib.util.spec_from_loader("slpj", loader))
        loader.exec_module(m)
        existing = os.path.join(self.dir, "existing")
        os.mkdir(existing)
        jp = os.path.join(existing, "newA", "newB", "journal.jsonl")
        synced = []
        real = os.fsync

        def spy(fd):
            if os.fstat(fd).st_mode & 0o170000 == 0o040000:
                synced.append(fd_path(fd))
            return real(fd)
        m.os.fsync = spy
        try:
            with m.Journal(jp, write=True) as j:
                j.append_message(env("m1", "QUESTION"))
        finally:
            m.os.fsync = real
        for d in (existing, os.path.join(existing, "newA"), os.path.join(existing, "newA", "newB")):
            self.assertIn(d, synced)
        self.assertEqual(oct(os.stat(os.path.join(existing, "newA")).st_mode & 0o777), "0o700")

    def test_first_append_syncs_ancestors_of_unsynced_dirs(self):
        import importlib.machinery, importlib.util
        loader = importlib.machinery.SourceFileLoader("slpj2", CLI)
        m = importlib.util.module_from_spec(importlib.util.spec_from_loader("slpj2", loader))
        loader.exec_module(m)
        existing = os.path.join(self.dir, "existing")
        newA, newB = os.path.join(existing, "newA"), os.path.join(existing, "newA", "newB")
        os.makedirs(newB, mode=0o700)  # a paused writer made these but has not fsynced them
        synced = []
        real = os.fsync

        def spy(fd):
            if os.fstat(fd).st_mode & 0o170000 == 0o040000:
                synced.append(fd_path(fd))
            return real(fd)
        m.os.fsync = spy
        try:
            with m.Journal(os.path.join(newB, "journal.jsonl"), write=True) as j:
                j.append_message(env("m1", "QUESTION"))
        finally:
            m.os.fsync = real
        for d in (newB, newA, existing, self.dir, "/"):
            self.assertIn(d, synced)

    def test_every_write_syncs_dirs_even_if_files_preexist(self):
        import importlib.machinery, importlib.util
        loader = importlib.machinery.SourceFileLoader("slpj3", CLI)
        m = importlib.util.module_from_spec(importlib.util.spec_from_loader("slpj3", loader))
        loader.exec_module(m)
        d = os.path.join(self.dir, "existing", "newA", "newB")
        os.makedirs(d, mode=0o700)
        jp = os.path.join(d, "journal.jsonl")
        for f in (jp, jp + ".lock"):  # created by a paused writer: no syncs
            os.close(os.open(f, os.O_CREAT | os.O_WRONLY, 0o600))
        synced = []
        real = os.fsync

        def spy(fd):
            if os.fstat(fd).st_mode & 0o170000 == 0o040000:
                synced.append(fd_path(fd))
            return real(fd)
        m.os.fsync = spy
        try:
            with m.Journal(jp, write=True) as j:
                j.append_message(env("m1", "QUESTION"))
                self.assertIn(d, synced)
            synced.clear()
            with m.Journal(jp, write=True) as j:
                j.deliver("m1", "delivered")
            self.assertIn(d, synced)
            synced.clear()
            with m.Journal(jp, write=False) as j:
                pass
            self.assertEqual(synced, [])
        finally:
            m.os.fsync = real

    def test_every_write_syncs_full_chain(self):
        import importlib.machinery, importlib.util
        loader = importlib.machinery.SourceFileLoader("slpj4", CLI)
        m = importlib.util.module_from_spec(importlib.util.spec_from_loader("slpj4", loader))
        loader.exec_module(m)
        d = os.path.join(self.dir, "existing", "newA", "newB")
        os.makedirs(d, mode=0o700)
        jp = os.path.join(d, "journal.jsonl")
        for f in (jp, jp + ".lock"):
            os.close(os.open(f, os.O_CREAT | os.O_WRONLY, 0o600))
        synced = []
        real = os.fsync

        def spy(fd):
            if os.fstat(fd).st_mode & 0o170000 == 0o040000:
                synced.append(fd_path(fd))
            return real(fd)
        m.os.fsync = spy
        try:
            with m.Journal(jp, write=True) as j:
                j.append_message(env("m1", "QUESTION"))
        finally:
            m.os.fsync = real
        for x in (d, os.path.dirname(d), os.path.join(self.dir, "existing"), self.dir, "/"):
            self.assertIn(x, synced)

    def test_dir_fsync_unsupported_is_skipped_other_errors_propagate(self):
        import errno, importlib.machinery, importlib.util
        loader = importlib.machinery.SourceFileLoader("slpj5", CLI)
        m = importlib.util.module_from_spec(importlib.util.spec_from_loader("slpj5", loader))
        loader.exec_module(m)
        real = os.fsync
        try:
            m.os.fsync = lambda fd: (_ for _ in ()).throw(OSError(errno.EINVAL, "x"))
            m.fsync_dir(self.dir)
            m.os.fsync = lambda fd: (_ for _ in ()).throw(OSError(errno.EIO, "x"))
            with self.assertRaises(OSError):
                m.fsync_dir(self.dir)
        finally:
            m.os.fsync = real


class StateMachineBase(Base):
    NOW = "2026-01-01T00:00:00Z"

    def sc(self, *args, now=None):
        return run(["--journal", self.j, "--now", now or self.NOW] + list(args))

    def seat(self, cmd, task, who, *rest):
        return self.sc(cmd, task, "--as", who, "--room", "r1", *rest)

    def sok(self, cmd, task, who, *rest):
        rc, r = self.seat(cmd, task, who, *rest)
        self.assertEqual(rc, 0, r)
        self.assertEqual(len(r.strip().splitlines()), 1, r)
        return dict(kv.split("=", 1) for kv in r.split() if "=" in kv)

    def srej(self, reason, cmd, task, who, *rest):
        rc, r = self.seat(cmd, task, who, *rest)
        self.assertEqual((rc, r.get("reason") if isinstance(r, dict) else r), (3, reason), r)

    def brief_w(self, task="t1", to="peer", paths=("src/a",), who="lead", *extra, root=None):
        a = [x for p in paths for x in ("--path", p)]
        return self.sok("brief", task, who, "--to", to, "--root", root or self.proj, *a, *extra)

    def cand_w(self, task="t1", n=1, who="peer", paths=("a.txt",)):
        pa = [x for p in paths for x in ("--path", p)]
        r = self.sok("candidate", task, who, "--base", "d935943", "--commit", "%07x" % n, *pa, "--evidence", "ev/%d" % n)
        self.assertEqual(r["cid"], cid_of(ident(n, paths)))
        return r["cid"]

    def status(self, task="t1", now=None):
        rc, r = self.sc("state", now=now)
        self.assertEqual(rc, 0, r)
        return r["tasks"][task]["status"]

    def tstate(self, now=None):
        rc, r = self.sc("state", now=now)
        self.assertEqual(rc, 0, r)
        return r

    def review_task(self, task, cid, reviewer="rev"):
        return self.sok("brief", task, "lead", "--to", reviewer, "--review", "--cid", cid)

    def done(self, *extra, now=None):
        rc, r = self.sc("done-check", "lead", *extra, now=now)
        if isinstance(r, dict):
            return rc, [r["reason"]], r
        return rc, [l.split()[1] for l in r.splitlines() if l.startswith("blocker")], r


class LifecycleTests(StateMachineBase):
    def test_full_lifecycle_one_command_per_signal(self):
        b = self.brief_w()
        self.assertEqual(b["status"], "ASSIGNED")
        rc, r = run(["--journal", self.j, "deliver", b["msg"], "delivered"])
        self.assertEqual(rc, 0, r)
        self.assertEqual(self.status(), "RUNNING")
        c = self.cand_w()
        self.assertEqual(self.status(), "CANDIDATE_READY")
        rb = self.review_task("rt1", c)
        self.assertEqual(rb["status"], "ASSIGNED")
        self.assertEqual(self.status(), "REVIEWING")
        self.srej("under-review", "accept", "t1", "lead", "--cid", c, "--waive", "skip")
        rv = self.sok("review", "rt1", "rev")
        self.assertEqual(rv["status"], "REVIEWED")
        self.assertEqual(self.status(), "CANDIDATE_READY")
        self.assertEqual(self.status("rt1"), "REVIEWED")
        a = self.sok("accept", "t1", "lead", "--cid", c)
        self.assertEqual(a["status"], "ACCEPTED")
        t = self.tstate()["tasks"]["t1"]
        self.assertTrue(t["scopeReleased"])
        self.assertEqual(t["ownership"]["event"], "released-by-accept")
        self.brief_w("t2", "peer2")  # scope is free again

    def test_assigned_to_running_by_delivery_or_owner_message(self):
        self.brief_w()
        self.assertEqual(self.status(), "ASSIGNED")
        self.sok("send", "t1", "peer", "QUESTION", "--note", "q")
        self.assertEqual(self.status(), "RUNNING")

    def test_reject_repair_cycle_and_ownership_choices(self):
        self.brief_w()
        c1 = self.cand_w(n=1)
        rj = self.sok("reject", "t1", "lead", "--cid", c1, "--note", "fix")
        self.assertEqual(rj["status"], "NEEDS_REPAIR")
        t = self.tstate()["tasks"]["t1"]
        self.assertEqual((t["owner"], t["scopeReleased"], t["ownership"]["event"]), ("peer", False, "kept"))
        self.srej("stale-candidate", "accept", "t1", "lead", "--cid", c1, "--waive", "x")
        rc, _ = run(["--journal", self.j, "deliver", rj["msg"], "delivered"])
        self.assertEqual(self.status(), "RUNNING")
        c2 = self.cand_w(n=2)
        self.sok("reject", "t1", "lead", "--cid", c2, "--reassign", "peer2")
        t = self.tstate()["tasks"]["t1"]
        self.assertEqual((t["owner"], t["scopeReleased"], t["ownership"]["event"]), ("peer2", False, "reassigned"))
        self.srej("not-owner", "candidate", "t1", "peer", "--base", "b", "--commit", "abcdef1", "--path", "a")
        c3 = self.cand_w(n=3, who="peer2")
        self.sok("reject", "t1", "lead", "--cid", c3, "--release")
        t = self.tstate()["tasks"]["t1"]
        self.assertEqual((t["status"], t["owner"], t["scopeReleased"], t["ownership"]["event"]), ("READY", None, True, "released-by-reject"))
        self.brief_w("t2", "peer3")  # released scope can be re-briefed

    def test_old_review_cannot_accept_repaired_candidate(self):
        self.brief_w()
        c1 = self.cand_w(n=1)
        self.review_task("rt1", c1)
        self.sok("review", "rt1", "rev")
        self.sok("reject", "t1", "lead", "--cid", c1)
        c2 = self.cand_w(n=2)
        self.srej("stale-candidate", "accept", "t1", "lead", "--cid", c1)
        rc, r = self.app(env("acc", "ACCEPT", cid=c2, payload={"reviewMessageId": "nope"}))
        self.assertEqual((rc, r["reason"]), (3, "review-mismatch"))
        self.srej("review-required", "accept", "t1", "lead", "--cid", c2)
        self.review_task("rt2", c2)
        self.sok("review", "rt2", "rev")
        self.assertEqual(self.sok("accept", "t1", "lead", "--cid", c2)["status"], "ACCEPTED")

    def test_illegal_transitions(self):
        self.brief_w()
        c = self.cand_w()
        self.srej("illegal-transition", "send", "t1", "peer", "BLOCKED", "--owner", "lead", "--return", "x")
        self.srej("illegal-transition", "send", "t1", "lead", "DEFER", "--owner", "lead", "--return", "x")
        self.srej("task-exists", "brief", "t1", "lead", "--to", "peer", "--root", self.proj, "--path", "other/x")
        self.sok("accept", "t1", "lead", "--cid", c, "--waive", "doc")
        self.srej("task-closed", "send", "t1", "peer", "QUESTION", "--note", "late")
        self.srej("task-closed", "candidate", "t1", "peer", "--base", "b", "--commit", "abcdef2", "--path", "a")
        rc, r = self.sc("control", "cancel", "t1", "--as", "lead", "--room", "r1")
        self.assertEqual((rc, r["reason"]), (3, "illegal-transition"))
        self.brief_w("t2", "peer2", ("other/x",))
        self.sc("control", "cancel", "t2", "--as", "lead", "--room", "r1")
        self.assertEqual(self.status("t2"), "CANCELLED")
        self.srej("task-closed", "candidate", "t2", "peer2", "--base", "b", "--commit", "abcdef3", "--path", "a")
        rc, r = self.sc("control", "revoke", "t2", "--as", "lead", "--room", "r1")
        self.assertEqual((rc, r["reason"]), (3, "illegal-transition"))

    def test_review_only_task_needs_no_candidate_and_cannot_write(self):
        self.sok("brief", "rv", "lead", "--to", "rev", "--review")
        self.srej("review-task-no-candidate", "candidate", "rv", "rev", "--base", "b", "--commit", "abcdef1", "--path", "a")
        self.srej("review-mismatch", "review", "rv", "rev", "--kind", "candidate", "--cid", "a" * 64)
        self.srej("not-owner", "review", "rv", "intruder", "--kind", "plan")
        self.assertEqual(self.sok("review", "rv", "rev", "--kind", "plan")["status"], "REVIEWED")
        self.srej("illegal-transition", "review", "rv", "rev", "--kind", "plan")
        rc, r = self.app(env("bx", "BRIEF", task="rv3", recipient="rev", payload={"kind": "review", "writeScope": {"root": self.proj, "paths": ["src"]}}))
        self.assertEqual((rc, r["reason"]), (3, "review-has-scope"))

    def test_review_brief_must_name_current_candidate(self):
        self.brief_w()
        c1 = self.cand_w(n=1)
        self.cand_w(n=2)
        self.srej("stale-candidate", "brief", "rt", "lead", "--to", "rev", "--review", "--cid", c1)
        self.srej("unknown-candidate", "brief", "rt", "lead", "--to", "rev", "--review", "--cid", "e" * 64)

    def test_blocked_and_deferred_carry_owner_and_return_condition(self):
        self.brief_w()
        self.srej("missing-field", "send", "t1", "peer", "BLOCKED", "--note", "x")
        self.srej("missing-field", "send", "t1", "peer", "BLOCKED", "--owner", "lead")
        self.sok("send", "t1", "peer", "BLOCKED", "--owner", "lead", "--return", "api ready")
        t = self.tstate()["tasks"]["t1"]
        self.assertEqual((t["status"], t["block"]["owner"], t["block"]["returnCondition"], t["scopeReleased"]), ("BLOCKED", "lead", "api ready", False))
        self.srej("scope-conflict", "brief", "t2", "lead", "--to", "z", "--root", self.proj, "--path", "src/a")
        self.sok("send", "t1", "lead", "ANSWER", "--note", "go")
        self.assertEqual(self.status(), "ASSIGNED")
        self.srej("missing-field", "send", "t1", "lead", "DEFER", "--owner", "lead")
        self.sok("send", "t1", "lead", "DEFER", "--owner", "lead", "--return", "after t9 lands")
        t = self.tstate()["tasks"]["t1"]
        self.assertEqual((t["status"], t["block"]["owner"]), ("DEFERRED", "lead"))
        self.sok("send", "t1", "lead", "REVISED BRIEF", "--note", "new")
        self.assertEqual(self.status(), "ASSIGNED")

    def test_recorder_is_not_write_owner_and_only_coordinator_dispositions(self):
        self.srej("owner-is-recorder", "brief", "t1", "lead", "--to", "lead", "--root", self.proj, "--path", "src/a")
        self.brief_w()
        c = self.cand_w()
        self.srej("not-coordinator", "accept", "t1", "peer", "--cid", c, "--waive", "self-accept")
        self.srej("not-coordinator", "reject", "t1", "peer", "--cid", c)
        self.srej("not-coordinator", "brief", "t3", "rogue", "--to", "p3", "--root", self.proj, "--path", "other/x")
        self.srej("not-coordinator", "send", "t1", "peer", "ANSWER")
        self.srej("unknown-task", "send", "nope", "peer", "QUESTION", "--to", "lead")


class OwnershipScopeTests(StateMachineBase):
    def git(self, cwd, *a):
        subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false"] + list(a),
                       cwd=cwd, check=True, capture_output=True)

    def test_nonexistent_tail_and_dotdot(self):
        self.brief_w("t1", "peer", ("src/new/deep/file",))
        self.srej("scope-conflict", "brief", "t2", "lead", "--to", "p2", "--root", self.proj, "--path", "src/new")
        self.srej("scope-conflict", "brief", "t2", "lead", "--to", "p2", "--root", self.proj, "--path", "src/new/x/../deep")
        self.srej("scope-escape", "brief", "t3", "lead", "--to", "p2", "--root", self.proj, "--path", "src/new/../../../..")
        self.brief_w("t4", "p4", ("src/newer",))

    def test_sibling_prefix_symlink_and_nested_roots(self):
        os.symlink(os.path.join(self.proj, "src", "a"), os.path.join(self.proj, "lnk"))
        self.brief_w("t1", "peer", ("src/a",))
        self.brief_w("t2", "p2", ("src/ab",))
        self.srej("scope-conflict", "brief", "t3", "lead", "--to", "p3", "--root", self.proj, "--path", "lnk")
        self.srej("scope-conflict", "brief", "t4", "lead", "--to", "p4", "--root", os.path.join(self.proj, "src"), "--path", "a/b")

    def test_two_worktrees_of_one_repo_vs_same_worktree(self):
        repo = os.path.join(self.dir, "repo")
        os.makedirs(os.path.join(repo, "src"))
        try:
            self.git(repo, "init", "-q")
            open(os.path.join(repo, "src", "f.txt"), "w").write("x")
            self.git(repo, "add", ".")
            self.git(repo, "commit", "-qm", "init")
            wt = os.path.join(self.dir, "wt2")
            self.git(repo, "worktree", "add", "-q", "-b", "other", wt)
        except (OSError, subprocess.CalledProcessError):
            self.skipTest("git unavailable")
        self.brief_w("t1", "peer", ("src",), root=repo)
        self.brief_w("t2", "p2", ("src",), root=wt)
        self.srej("scope-conflict", "brief", "t3", "lead", "--to", "p3", "--root", os.path.join(repo, "src"), "--path", "f.txt")
        self.srej("scope-conflict", "brief", "t4", "lead", "--to", "p4", "--root", wt, "--path", "src")
        s = self.tstate()["tasks"]
        self.assertEqual(s["t1"]["writeScope"]["rootId"], os.path.realpath(repo))
        self.assertEqual(s["t2"]["writeScope"]["rootId"], os.path.realpath(wt))

    def test_revoke_then_transfer_and_old_owner_loses_rights(self):
        self.brief_w()
        c = self.cand_w()
        rc, r = self.sc("control", "revoke", "t1", "--as", "peer", "--room", "r1")
        self.assertEqual((rc, r["reason"]), (3, "not-coordinator"))
        r = self.sc("control", "revoke", "t1", "--as", "lead", "--room", "r1")
        self.assertEqual(r[0], 0, r)
        t = self.tstate()["tasks"]["t1"]
        self.assertEqual((t["status"], t["owner"], t["scopeReleased"], t["currentCandidate"]), ("READY", None, True, None))
        self.srej("stale-candidate", "accept", "t1", "lead", "--cid", c, "--waive", "x")
        rc, r = self.sc("control", "transfer", "t1", "--as", "lead", "--room", "r1", "--to", "lead")
        self.assertEqual((rc, r["reason"]), (3, "bad-control"))
        self.brief_w("t2", "p2", ("src/a/b",))  # revoke freed the scope for someone else
        rc, r = self.sc("control", "transfer", "t1", "--as", "lead", "--room", "r1", "--to", "peer2")
        self.assertEqual((rc, r["reason"]), (3, "scope-conflict"))
        rc, r = self.sc("control", "cancel", "t2", "--as", "lead", "--room", "r1")
        self.assertEqual(rc, 0, r)
        rc, r = self.sc("control", "transfer", "t1", "--as", "lead", "--room", "r1", "--to", "peer2")
        self.assertEqual(rc, 0, r)
        t = self.tstate()["tasks"]["t1"]
        self.assertEqual((t["status"], t["owner"], t["scopeReleased"]), ("ASSIGNED", "peer2", False))
        self.srej("not-owner", "candidate", "t1", "peer", "--base", "b", "--commit", "abcdef9", "--path", "a")
        self.cand_w("t1", 5, who="peer2")

    def test_transfer_from_owned_state_keeps_exclusion(self):
        self.brief_w()
        rc, r = self.sc("control", "transfer", "t1", "--as", "lead", "--room", "r1", "--to", "peer2")
        self.assertEqual(rc, 0, r)
        self.srej("scope-conflict", "brief", "t2", "lead", "--to", "p3", "--root", self.proj, "--path", "src/a")

    def test_control_dedup_and_conflict(self):
        self.brief_w()
        a = ["control", "transfer", "t1", "--as", "lead", "--room", "r1", "--to", "peer2", "--id", "ctl1"]
        self.assertEqual(self.sc(*a)[0], 0)
        rc, r = self.sc(*a)
        self.assertEqual(rc, 0)
        self.assertIn("dup", r)
        rc, r = self.sc("control", "transfer", "t1", "--as", "lead", "--room", "r1", "--to", "peer3", "--id", "ctl1")
        self.assertEqual((rc, r["reason"]), (3, "conflict"))


class LeaseTests(StateMachineBase):
    def test_expired_lease_marks_reconcile_but_keeps_exclusion(self):
        self.brief_w("t1", "peer", ("src/a",), "lead", "--lease", "2026-01-01T00:10:00Z")
        s = self.tstate(now="2026-01-01T00:05:00Z")
        self.assertEqual((s["tasks"]["t1"]["leaseExpired"], s["tasksNeedReconcile"]), (False, []))
        s = self.tstate(now="2026-01-01T00:20:00Z")
        self.assertEqual((s["tasks"]["t1"]["leaseExpired"], s["tasksNeedReconcile"], s["tasks"]["t1"]["scopeReleased"]), (True, ["t1"], False))
        rc, r = self.sc("brief", "t2", "--as", "lead", "--room", "r1", "--to", "p2", "--root", self.proj, "--path", "src/a", now="2026-01-01T00:20:00Z")
        self.assertEqual((rc, r["reason"]), (3, "scope-conflict"))
        rc, bl, _ = self.done(now="2026-01-01T00:20:00Z")
        self.assertIn("lease-expired", bl)
        rc, r = self.sc("control", "reconcile", "t1", "--as", "lead", "--room", "r1", "--lease", "none", now="2026-01-01T00:20:00Z")
        self.assertEqual(rc, 0, r)
        s = self.tstate(now="2026-01-01T00:30:00Z")
        self.assertEqual((s["tasks"]["t1"]["leaseExpired"], s["tasks"]["t1"]["scopeReleased"]), (False, False))
        rc, r = self.sc("brief", "t2", "--as", "lead", "--room", "r1", "--to", "p2", "--root", self.proj, "--path", "src/a")
        self.assertEqual((rc, r["reason"]), (3, "scope-conflict"))
        rc, r = self.sc("control", "reconcile", "t1", "--as", "lead", "--room", "r1", "--lease", "2026-02-01T00:00:00Z")
        self.assertEqual(rc, 0, r)
        self.assertEqual(self.tstate(now="2026-01-15T00:00:00Z")["tasks"]["t1"]["leaseExpired"], False)
        rc, r = self.sc("control", "revoke", "t1", "--as", "lead", "--room", "r1")
        self.assertEqual(rc, 0, r)
        self.brief_w("t2", "p2")

    def test_bad_lease_rejected(self):
        self.srej("bad-lease", "brief", "t1", "lead", "--to", "peer", "--root", self.proj, "--path", "src/a", "--lease", "tomorrow")


class DependencyTests(StateMachineBase):
    def upstream(self, kind="commit"):
        repo = os.path.join(self.dir, "up")
        os.makedirs(repo)
        subprocess.run(["git", "init", "-q"], cwd=repo, check=True, capture_output=True)
        open(os.path.join(repo, "f"), "w").write("x")
        subprocess.run(["git", "add", "."], cwd=repo, check=True, capture_output=True)
        subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false", "commit", "-qm", "i"],
                       cwd=repo, check=True, capture_output=True)
        sha = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True, check=True).stdout.strip()
        return repo, sha

    def accept_up(self, repo, commit=None, patch=None, task="up"):
        self.brief_w(task, "peer", ("src",), root=repo) if os.path.isdir(os.path.join(repo, "src")) else None
        a = ["--base", "b0", "--path", "f"]
        a += ["--commit", commit] if commit else ["--patch-sha", patch[0], "--patch-file", patch[1]]
        c = self.sok("candidate", task, "peer", *a)["cid"]
        self.sok("accept", task, "lead", "--cid", c, "--waive", "ok")
        return c

    def test_dependency_gates(self):
        repo, sha = self.upstream()
        os.makedirs(os.path.join(repo, "src"))
        self.brief_w("up", "peer", ("src",), root=repo)
        dep = lambda c: ["--depends", "up:" + c]
        self.srej("dependency-unknown", "brief", "d", "lead", "--to", "p2", "--root", self.proj, "--path", "src/a", "--depends", "zz:" + "a" * 64)
        self.srej("dependency-not-accepted", "brief", "d", "lead", "--to", "p2", "--root", self.proj, "--path", "src/a", *dep("a" * 64))
        a = ["--base", "b0", "--commit", sha, "--path", "f"]
        c = self.sok("candidate", "up", "peer", *a)["cid"]
        self.srej("dependency-not-accepted", "brief", "d", "lead", "--to", "p2", "--root", self.proj, "--path", "src/a", *dep(c))
        self.sok("accept", "up", "lead", "--cid", c, "--waive", "ok")
        self.srej("dependency-wrong-candidate", "brief", "d", "lead", "--to", "p2", "--root", self.proj, "--path", "src/a", *dep("b" * 64))
        b = self.sok("brief", "d", "lead", "--to", "p2", "--root", self.proj, "--path", "src/a", *dep(c))
        self.assertEqual(b["status"], "ASSIGNED")
        self.assertEqual(self.tstate()["tasks"]["d"]["dependsOn"], [{"taskId": "up", "candidateId": c, "artifact": "commit"}])

    def test_cancelled_upstream_is_not_enough_and_missing_commit(self):
        repo, sha = self.upstream()
        os.makedirs(os.path.join(repo, "src"))
        self.brief_w("up", "peer", ("src",), root=repo)
        c = self.sok("candidate", "up", "peer", "--base", "b0", "--commit", "deadbee", "--path", "f")["cid"]
        self.sok("accept", "up", "lead", "--cid", c, "--waive", "ok")
        self.srej("dependency-artifact-inaccessible", "brief", "d", "lead", "--to", "p2", "--root", self.proj, "--path", "src/a", "--depends", "up:" + c)
        self.brief_w("up2", "peer", ("other/x",))
        self.sc("control", "cancel", "up2", "--as", "lead", "--room", "r1")
        self.srej("dependency-not-accepted", "brief", "d", "lead", "--to", "p2", "--root", self.proj, "--path", "src/a", "--depends", "up2:" + "c" * 64)

    def test_patch_artifact(self):
        self.brief_w("up", "peer", ("src",))
        pf = os.path.join(self.dir, "x.patch")
        open(pf, "w").write("diff\n")
        sha = hashlib.sha256(b"diff\n").hexdigest()
        c = self.sok("candidate", "up", "peer", "--base", "b0", "--patch-sha", sha, "--patch-file", pf, "--path", "f")["cid"]
        self.sok("accept", "up", "lead", "--cid", c, "--waive", "ok")
        self.assertEqual(self.sok("brief", "d", "lead", "--to", "p2", "--root", self.proj, "--path", "other/x", "--depends", "up:" + c)["status"], "ASSIGNED")
        open(pf, "w").write("tampered\n")
        self.srej("dependency-artifact-inaccessible", "brief", "d2", "lead", "--to", "p2", "--root", self.proj, "--path", "src/ab", "--depends", "up:" + c)
        os.unlink(pf)
        self.srej("dependency-artifact-inaccessible", "brief", "d2", "lead", "--to", "p2", "--root", self.proj, "--path", "src/ab", "--depends", "up:" + c)

    def test_replay_does_not_reevaluate_artifacts(self):
        self.brief_w("up", "peer", ("src",))
        pf = os.path.join(self.dir, "x.patch")
        open(pf, "w").write("diff\n")
        c = self.sok("candidate", "up", "peer", "--base", "b0", "--patch-sha", hashlib.sha256(b"diff\n").hexdigest(), "--patch-file", pf, "--path", "f")["cid"]
        self.sok("accept", "up", "lead", "--cid", c, "--waive", "ok")
        self.sok("brief", "d", "lead", "--to", "p2", "--root", self.proj, "--path", "other/x", "--depends", "up:" + c)
        before = self.tstate()
        os.unlink(pf)
        self.assertEqual(self.tstate(), before)


class DoneCheckTests(StateMachineBase):
    def test_clean_passes_and_each_blocker_blocks(self):
        self.brief_w()
        rc, r = self.sc("done-check", "nobody")
        self.assertEqual((rc, r["reason"]), (3, "unknown-lead"))
        rc, bl, r = self.done()
        self.assertEqual((rc, "task-open" in bl), (3, True), r)
        self.assertIn("message-unprocessed", bl)
        c = self.cand_w()
        self.assertIn("candidate-undisposed", self.done()[1])
        self.sok("send", "t1", "peer", "QUESTION", "--note", "q")
        self.assertIn("signal-undisposed", self.done()[1])
        self.sok("accept", "t1", "lead", "--cid", c, "--waive", "ok")
        bl = self.done()[1]
        self.assertIn("signal-undisposed", bl)
        self.assertNotIn("candidate-undisposed", bl)
        self.assertNotIn("task-open", bl)
        self.sok("send", "t1", "lead", "ANSWER", "--note", "a")
        st = self.tstate()
        for m in st["messages"]:
            for s in ("delivered", "processing", "processed"):
                self.assertEqual(run(["--journal", self.j, "deliver", m, s])[0], 0)
            if m == sorted(st["messages"])[0]:
                pass
        rc, bl, r = self.done()
        self.assertEqual((rc, bl), (0, []), r)
        self.assertEqual(r.strip(), "ok done-check lead clean")
        rc, bl, r = self.done("--running", "peer", "--permission-pending", "peer2")
        self.assertEqual((rc, bl), (3, ["agent-running", "permission-pending"]), r)

    def test_needs_reconcile_message_and_lease_and_unreleased(self):
        self.brief_w("t1", "peer", ("src/a",), "lead", "--lease", "2026-01-01T00:01:00Z")
        c = self.cand_w()
        self.sok("accept", "t1", "lead", "--cid", c, "--waive", "ok")
        for m in self.tstate()["messages"]:
            for s in ("delivered", "processing", "processed"):
                run(["--journal", self.j, "deliver", m, s])
        self.assertEqual(self.done()[0], 0)
        self.brief_w("t2", "peer", ("other/x",))
        rc, bl, _ = self.done(now="2026-01-02T00:00:00Z")
        self.assertEqual(rc, 3)
        m = [m for m, v in self.tstate()["messages"].items() if v["state"] == "recorded"][0]
        run(["--journal", self.j, "deliver", m, "delivered"])
        run(["--journal", self.j, "deliver", m, "processing"])
        self.assertIn("message-needs-reconcile", self.done()[1])

    def test_blocked_deferred_tasks_block_done(self):
        self.brief_w()
        self.sok("send", "t1", "peer", "BLOCKED", "--owner", "lead", "--return", "x")
        self.assertIn("task-open", self.done()[1])
        self.sc("control", "cancel", "t1", "--as", "lead", "--room", "r1")
        self.assertNotIn("task-open", self.done()[1])


class LeadReplacementTests(StateMachineBase):
    def test_new_lead_restores_state_and_blocks_duplicate_writer(self):
        self.brief_w()
        c = self.cand_w()
        self.sok("send", "t1", "peer", "QUESTION", "--note", "q")
        before = self.tstate()
        rc, r = self.sc("control", "lead", "--as", "rogue", "--room", "r1", "--from", "lead", "--to", "lead2")
        self.assertEqual((rc, r["reason"]), (3, "not-coordinator"))
        rc, r = self.sc("control", "lead", "--as", "lead2", "--room", "r1", "--from", "lead", "--to", "lead2")
        self.assertEqual(rc, 0, r)
        after = self.tstate()
        self.assertEqual(after["roomLeads"], {"r1": "lead2"})
        for k in ("tasks", "openSignals"):
            self.assertEqual(after[k], before[k])
        self.srej("not-coordinator", "accept", "t1", "lead", "--cid", c, "--waive", "old lead")
        self.srej("scope-conflict", "brief", "t9", "lead2", "--to", "pz", "--root", self.proj, "--path", "src/a")
        self.srej("scope-conflict", "brief", "t9", "lead2", "--to", "peer", "--root", self.proj, "--path", "src/a/b")
        self.assertEqual(self.sok("accept", "t1", "lead2", "--cid", c, "--waive", "ok")["status"], "ACCEPTED")
        self.brief_w("t9", "pz", ("src/a",), "lead2")
        self.assertEqual(self.sc("done-check", "lead", now=self.NOW)[0], 3)
        rc, r = self.sc("control", "lead", "--as", "lead", "--room", "r1", "--from", "lead", "--to", "lead3")
        self.assertEqual((rc, r["reason"]), (3, "not-coordinator"))

    def test_incoming_lead_cannot_be_a_write_owner(self):
        self.brief_w()
        rc, r = self.sc("control", "lead", "--as", "lead", "--room", "r1", "--from", "lead", "--to", "peer")
        self.assertEqual((rc, r["reason"]), (3, "owner-is-recorder"))


class ReplayTests(StateMachineBase):
    def test_restart_replay_identical_without_filesystem(self):
        self.brief_w("t1", "peer", ("src/a",), "lead", "--lease", "2026-01-01T00:10:00Z")
        os.symlink(os.path.join(self.proj, "other"), os.path.join(self.proj, "lnk"))
        self.brief_w("t2", "p2", ("lnk",))
        c = self.cand_w()
        self.review_task("rt", c)
        self.sc("control", "transfer", "t2", "--as", "lead", "--room", "r1", "--to", "p3")
        s1 = self.tstate(now="2026-01-02T00:00:00Z")
        j2 = os.path.join(self.dir, "copy", "room.jsonl")
        os.makedirs(os.path.dirname(j2))
        import shutil
        shutil.copy(self.j, j2)
        shutil.rmtree(self.proj)
        rc, s2 = run(["--journal", j2, "--now", "2026-01-02T00:00:00Z", "state"])
        self.assertEqual(rc, 0, s2)
        self.assertEqual(s1, s2)
        self.assertEqual(self.tstate(now="2026-01-02T00:00:00Z"), s1)


if __name__ == "__main__":
    unittest.main(verbosity=1, warnings="ignore")
