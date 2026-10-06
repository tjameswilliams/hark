#!/usr/bin/env python3
"""Analyze voiceprint dumps from the `voiceprint` spike tool.

usage: analyze_voiceprints.py <dump-dir> [streaming|offline]

Ground truth comes from the recording layout: ch0 is the mic, so a speaker
whose energy is almost all on the mic channel is the person at this Mac
("me") in every meeting, and a speaker almost entirely on the system channel
is definitely someone else.
"""
import glob, json, os, sqlite3, sys
import numpy as np

dump_dir = sys.argv[1]
pipeline = sys.argv[2] if len(sys.argv) > 2 else "offline"
# "offline-span": offline diarizer, but voiceprints averaged from the raw
# chunk embeddings instead of the library's speakerDatabase entries.
vector_key = "spanCentroid" if pipeline.endswith("-span") else "centroid"
pipeline = pipeline.removesuffix("-span")
MIN_SECONDS = 30      # ignore speakers with less talk time than this
ME_SHARE, REMOTE_SHARE = 0.7, 0.3

titles = {}
db = os.path.expanduser("~/Library/Application Support/Hark/hark.sqlite")
if os.path.exists(db):
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    for title, path in con.execute("select title, audio_path from sessions where kind='meeting'"):
        titles[os.path.basename(path or "")] = title

def dist(a, b):
    return 1.0 - float(np.dot(a, b))

def pct(xs, ps=(5, 25, 50, 75, 95)):
    if not len(xs):
        return "n=0"
    return f"n={len(xs):<4} min {min(xs):.2f}  " + "  ".join(
        f"p{p} {np.percentile(xs, p):.2f}" for p in ps) + f"  max {max(xs):.2f}"

meetings = []
for path in sorted(glob.glob(os.path.join(dump_dir, "*.json"))):
    d = json.load(open(path))
    if not d.get(pipeline):
        continue
    speakers = []
    for s in d[pipeline]["speakers"]:
        if not s.get(vector_key):
            continue
        s["v"] = np.array(s[vector_key])
        s["a"] = np.array(s["firstHalf"]) if s.get("firstHalf") else None
        s["b"] = np.array(s["secondHalf"]) if s.get("secondHalf") else None
        s["meeting"] = d["file"]
        speakers.append(s)
    meetings.append({"file": d["file"], "title": titles.get(d["file"], "?"),
                     "seconds": d["audioSeconds"], "speakers": speakers,
                     "cost": d[pipeline]["seconds"]})

print(f"=== pipeline: {pipeline} ({vector_key}) — {len(meetings)} meetings ===\n")
print("-- speakers per meeting (>= %ds talk time / all) --" % MIN_SECONDS)
me = {}
for m in meetings:
    solid = [s for s in m["speakers"] if s["seconds"] >= MIN_SECONDS]
    mine = [s for s in solid if s["micShare"] >= ME_SHARE]
    if mine:
        me[m["file"]] = max(mine, key=lambda s: s["seconds"])
    desc = "  ".join(f"{s['id']}:{s['seconds']:.0f}s/mic{s['micShare']:.2f}" for s in solid)
    print(f"{m['file'][:16]} {m['title'][:24]:24} {m['seconds']/60:5.1f}min "
          f"{len(solid):2}/{len(m['speakers']):2}  rtfx {m['seconds']/m['cost']:4.0f}  {desc}")
    if len(mine) > 1:
        print(f"{'':16} ^ {len(mine)} mic-channel speakers — 'me' was split or shared the mic")

solid_all = [s for m in meetings for s in m["speakers"] if s["seconds"] >= MIN_SECONDS]
remote = [s for s in solid_all if s["micShare"] <= REMOTE_SHARE]
me_list = [me[m["file"]] for m in meetings if m["file"] in me]

print("\n-- cosine distance distributions --")
split = [dist(s["a"], s["b"]) for s in solid_all if s["a"] is not None and s["b"] is not None]
print("same person, same meeting (half vs half): ", pct(split))
same_me = [dist(a["v"], b["v"]) for i, a in enumerate(me_list) for b in me_list[i + 1:]]
print("same person, different meetings (me↔me):  ", pct(same_me))
diff_me = [dist(a["v"], r["v"]) for a in me_list for r in remote]
print("different people (me ↔ remote speakers):   ", pct(diff_me))
diff_in = [dist(a["v"], b["v"]) for m in meetings
           for i, a in enumerate([s for s in m["speakers"] if s["seconds"] >= MIN_SECONDS])
           for b in [s for s in m["speakers"] if s["seconds"] >= MIN_SECONDS][i + 1:]]
print("different labels within one meeting:       ", pct(diff_in))

print("\n-- threshold sweep on 'me' (accept when distance <= t) --")
print("    t   miss-rate(me↔me)   false-accept(me↔remote)")
for t in np.arange(0.20, 0.81, 0.05):
    miss = np.mean([d > t for d in same_me]) if same_me else float("nan")
    fa = np.mean([d <= t for d in diff_me]) if diff_me else float("nan")
    print(f"  {t:.2f}      {miss*100:5.1f}%              {fa*100:5.1f}%")

print("\n-- progressive enrollment of 'me', chronological --")
print("   (voiceprint = running mean of every confirmed meeting so far)")
profile, n = None, 0
for m in meetings:
    solid = [s for s in m["speakers"] if s["seconds"] >= MIN_SECONDS]
    truth = me.get(m["file"])
    if profile is not None and solid:
        ranked = sorted(solid, key=lambda s: dist(profile, s["v"]))
        best = ranked[0]
        runner = dist(profile, ranked[1]["v"]) if len(ranked) > 1 else float("nan")
        verdict = ("no mic speaker" if truth is None
                   else "CORRECT" if best is truth else "WRONG")
        truth_d = f"{dist(profile, truth['v']):.2f}" if truth is not None else "  - "
        print(f"{m['file'][:16]} {m['title'][:22]:22} nearest {dist(profile, best['v']):.2f} "
              f"(mic {best['micShare']:.2f})  runner-up {runner:.2f}  true-me {truth_d}  {verdict}")
    if truth is not None:
        profile = truth["v"] if profile is None else profile * n + truth["v"]
        n += 1
        profile = profile / np.linalg.norm(profile)
        if n == 1:
            print(f"{m['file'][:16]} {m['title'][:22]:22} enrolled from {truth['seconds']:.0f}s of speech")

print("\n-- remote speakers: nearest neighbour in any OTHER meeting --")
nn = []
for s in remote:
    others = [o for o in remote if o["meeting"] != s["meeting"]]
    if others:
        o = min(others, key=lambda o: dist(s["v"], o["v"]))
        nn.append((dist(s["v"], o["v"]), s, o))
print(pct([d for d, _, _ in nn]))

def cluster(threshold):
    """Greedy average-link grouping of remote speakers across meetings."""
    groups = []
    for s in sorted(remote, key=lambda s: -s["seconds"]):
        best, best_d = None, threshold
        for g in groups:
            if any(o["meeting"] == s["meeting"] for o in g):
                continue  # two labels in one meeting are assumed distinct
            d = float(np.mean([dist(s["v"], o["v"]) for o in g]))
            if d <= best_d:
                best, best_d = g, d
        (best.append(s) if best is not None else groups.append([s]))
    return groups

for t in (0.30, 0.40, 0.50):
    groups = cluster(t)
    multi = [g for g in groups if len(g) > 1]
    print(f"threshold {t:.2f}: {len(remote)} remote speakers → {len(groups)} people, "
          f"{len(multi)} recurring across meetings")

if "--groups" in sys.argv:
    t = float(sys.argv[sys.argv.index("--groups") + 1])
    print(f"\n-- recurring remote voices at threshold {t:.2f} (listen to verify) --")
    for i, g in enumerate(sorted(cluster(t), key=lambda g: -len(g))):
        if len(g) < 2:
            continue
        print(f"voice {i + 1}: {len(g)} meetings")
        for s in sorted(g, key=lambda s: s["meeting"]):
            print(f"    {s['meeting'][:16]} {titles.get(s['meeting'], '?')[:24]:24} {s['id']:>4} "
                  f"{s['seconds']:5.0f}s  clip {s['clipStart']:.1f}-{s['clipEnd']:.1f}s")

# --listen <out.html> <threshold>: self-contained page of clips, one group per
# recurring voice, so a human can confirm the groupings by ear. This is the
# only ground truth available for remote speakers.
if "--listen" in sys.argv:
    import base64, html, subprocess, tempfile
    out = sys.argv[sys.argv.index("--listen") + 1]
    t = float(sys.argv[sys.argv.index("--listen") + 2])
    rec_dir = os.path.expanduser("~/Library/Application Support/Hark/recordings")
    tmp = tempfile.mkdtemp()

    def clip(s):
        wav, m4a = os.path.join(tmp, "c.wav"), os.path.join(tmp, "c.m4a")
        subprocess.run(["sox", os.path.join(rec_dir, s["meeting"]), wav, "remix", "1,2",
                        "trim", f"{s['clipStart']:.2f}", f"{s['clipEnd'] - s['clipStart']:.2f}",
                        "norm", "-3"], check=True, capture_output=True)
        subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "48000", wav, m4a],
                       check=True, capture_output=True)
        return base64.b64encode(open(m4a, "rb").read()).decode()

    def said(s):
        row = con.execute(
            """select group_concat(text, ' ') from (select g.text from segments g
               join sessions x on x.id = g.session_id where x.audio_path like ?
               and g.t_end_ms > ? and g.t_start_ms < ? order by g.t_start_ms)""",
            ("%" + s["meeting"], s["clipStart"] * 1000, s["clipEnd"] * 1000)).fetchone()
        return (row[0] or "")[:220]

    def row(s, note=""):
        return (f"<div class=row><audio controls preload=none "
                f"src='data:audio/mp4;base64,{clip(s)}'></audio><div><b>"
                f"{html.escape(titles.get(s['meeting'], '?'))}</b> · {s['meeting'][:10]} · "
                f"{s['seconds']:.0f}s of speech {note}<br><span>{html.escape(said(s))}</span>"
                f"</div></div>")

    parts = []
    groups = sorted(cluster(t), key=lambda g: (-len(g), -sum(s["seconds"] for s in g)))
    for i, g in enumerate([g for g in groups if len(g) > 1]):
        spread = max(dist(a["v"], b["v"]) for a in g for b in g)
        parts.append(f"<h2>Voice {chr(65 + i)} — matched in {len(g)} meetings "
                     f"<small>(widest distance {spread:.2f})</small></h2>")
        parts += [row(s) for s in sorted(g, key=lambda s: s["meeting"])]
    parts.append("<h2>You (mic channel) — one clip per meeting</h2>")
    prof = np.mean([s["v"] for s in me_list], axis=0)
    for s in me_list:
        d = dist(prof / np.linalg.norm(prof), s["v"])
        parts.append(row(s, f"· distance to your average {d:.2f}" + (" ⚠︎ outlier" if d > 0.45 else "")))
    open(out, "w").write(
        "<!doctype html><meta charset=utf-8><title>Voice match check</title><style>"
        "body{font:14px -apple-system,sans-serif;max-width:760px;margin:24px auto;padding:0 16px;"
        "background:#fff;color:#111}h2{margin-top:32px;font-size:16px}small{font-weight:400;color:#666}"
        ".row{display:flex;gap:12px;align-items:center;margin:8px 0}audio{flex:none;width:260px}"
        "span{color:#555}@media(prefers-color-scheme:dark){body{background:#161616;color:#eee}"
        "span,small{color:#aaa}}</style><h1>Is each group one person?</h1>"
        f"<p>Clips grouped automatically by voiceprint ({pipeline} diarizer, threshold {t:.2f}). "
        "Each group should be a single person across different meetings.</p>" + "".join(parts))
    print(f"\nwrote {out}")
