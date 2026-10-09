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
        self.brief("b7", task="t7", owner="peer", paths=("src/a/b",))
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
        self.ok(env("m9", "QUESTION"))
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
                synced.append(os.path.realpath("/dev/fd/%d" % fd) if sys.platform != "darwin" else self._fd_path(fd))
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
                synced.append(self._fd_path(fd))
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
                synced.append(self._fd_path(fd))
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
                synced.append(self._fd_path(fd))
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

    @staticmethod
    def _fd_path(fd):
        import fcntl
        return os.fsdecode(fcntl.fcntl(fd, 50, b"\0" * 1024).split(b"\0")[0])  # F_GETPATH (macOS)


if __name__ == "__main__":
    unittest.main(verbosity=1, warnings="ignore")
