# Local SQLite store for daily QA reports, and week/month rollups from that store.
# Reads and writes files only. Does not call GitLab.
import argparse
import json
import sqlite3
import sys
from datetime import datetime, timedelta
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS days (
  report_date TEXT PRIMARY KEY,
  window_from TEXT NOT NULL,
  window_to TEXT NOT NULL,
  stored_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS documents (
  report_date TEXT NOT NULL,
  page TEXT NOT NULL,
  title TEXT NOT NULL,
  category TEXT NOT NULL,
  note_count INTEGER NOT NULL,
  PRIMARY KEY (report_date, page)
);
CREATE TABLE IF NOT EXISTS endpoints (
  report_date TEXT NOT NULL,
  method TEXT NOT NULL,
  path TEXT NOT NULL,
  service TEXT NOT NULL,
  category TEXT NOT NULL,
  note_count INTEGER NOT NULL,
  PRIMARY KEY (report_date, method, path)
);
CREATE TABLE IF NOT EXISTS issues (
  report_date TEXT NOT NULL,
  iid INTEGER NOT NULL,
  kind TEXT NOT NULL,
  title TEXT NOT NULL,
  state TEXT NOT NULL,
  PRIMARY KEY (report_date, iid, kind)
);
"""


def repo_root():
    here = Path(__file__).resolve().parent
    current = here
    while True:
        if (current / "tools" / "gitlab.ps1").is_file():
            return current
        if current.parent == current:
            return here.parent
        current = current.parent


def connect(db_path):
    path = Path(db_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path))
    conn.executescript(SCHEMA)
    return conn


def as_list(value):
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return [value]


def save_payload(conn, payload):
    day = payload["date"]
    now = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    conn.execute("DELETE FROM documents WHERE report_date = ?", (day,))
    conn.execute("DELETE FROM endpoints WHERE report_date = ?", (day,))
    conn.execute("DELETE FROM issues WHERE report_date = ?", (day,))
    conn.execute(
        "INSERT INTO days(report_date, window_from, window_to, stored_at) VALUES(?,?,?,?) "
        "ON CONFLICT(report_date) DO UPDATE SET window_from=excluded.window_from, "
        "window_to=excluded.window_to, stored_at=excluded.stored_at",
        (day, payload.get("windowFrom") or "", payload.get("windowTo") or "", now),
    )
    for row in as_list(payload.get("documents")):
        conn.execute(
            "INSERT INTO documents(report_date, page, title, category, note_count) VALUES(?,?,?,?,?)",
            (day, row.get("page") or "", row.get("title") or "", row.get("category") or "", int(row.get("noteCount") or 0)),
        )
    for row in as_list(payload.get("endpoints")):
        conn.execute(
            "INSERT INTO endpoints(report_date, method, path, service, category, note_count) VALUES(?,?,?,?,?,?)",
            (
                day,
                row.get("method") or "",
                row.get("path") or "",
                row.get("service") or "",
                row.get("category") or "",
                int(row.get("noteCount") or 0),
            ),
        )
    for kind, key in (("created", "created"), ("checked", "checked")):
        for row in as_list(payload.get(key)):
            conn.execute(
                "INSERT INTO issues(report_date, iid, kind, title, state) VALUES(?,?,?,?,?)",
                (day, int(row.get("iid") or 0), kind, row.get("title") or "", row.get("state") or ""),
            )
    conn.commit()


def load_config(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def parse_day(value):
    return datetime.strptime(value, "%Y-%m-%d").date()


def daterange(start, end):
    day = start
    while day <= end:
        yield day
        day += timedelta(days=1)


def state_label(labels, state):
    if state == "closed":
        return labels["closed"]
    if state == "opened":
        return labels["open"]
    if state:
        return state
    return labels["unknown"]


def category_order(cfg):
    order = {}
    for index, item in enumerate(cfg.get("categories") or []):
        order[item["label"]] = index
    order[cfg["labels"]["categoryOther"]] = len(order)
    return order


def add_category_lines(lines, groups, template, order):
    rows = sorted(groups.items(), key=lambda item: (-item[1], order.get(item[0], 99)))
    for label, count in rows:
        if count <= 0:
            continue
        lines.append(template.replace("{n}", str(count)).replace("{cat}", label))


def fill(template, **values):
    text = template
    for key, value in values.items():
        text = text.replace("{" + key + "}", str(value))
    return text


def per_day_counts(conn, start_s, end_s):
    stats = {}

    def slot(day):
        return stats.setdefault(day, {
            "docs": 0, "docNotes": 0, "apis": 0, "apiNotes": 0, "created": 0, "checked": 0,
        })

    for day, count, notes in conn.execute(
        "SELECT report_date, COUNT(*), COALESCE(SUM(note_count), 0) FROM documents "
        "WHERE report_date >= ? AND report_date <= ? GROUP BY report_date",
        (start_s, end_s),
    ):
        item = slot(day)
        item["docs"] = count
        item["docNotes"] = notes

    for day, count, notes in conn.execute(
        "SELECT report_date, COUNT(*), COALESCE(SUM(note_count), 0) FROM endpoints "
        "WHERE report_date >= ? AND report_date <= ? GROUP BY report_date",
        (start_s, end_s),
    ):
        item = slot(day)
        item["apis"] = count
        item["apiNotes"] = notes

    for day, kind_name, count in conn.execute(
        "SELECT report_date, kind, COUNT(*) FROM issues "
        "WHERE report_date >= ? AND report_date <= ? GROUP BY report_date, kind",
        (start_s, end_s),
    ):
        item = slot(day)
        item["created" if kind_name == "created" else "checked"] = count

    return stats


def build_report(conn, cfg, start, end, kind):
    labels = cfg["labels"]
    order = category_order(cfg)
    rule = labels["separator"]
    span_days = (end - start).days + 1
    start_s = start.isoformat()
    end_s = end.isoformat()
    stored = [row[0] for row in conn.execute(
        "SELECT report_date FROM days WHERE report_date >= ? AND report_date <= ? ORDER BY report_date",
        (start_s, end_s),
    )]
    stored_set = set(stored)
    missing = [day.isoformat() for day in daterange(start, end) if day.isoformat() not in stored_set]
    windows = conn.execute(
        "SELECT window_from, window_to FROM days WHERE report_date >= ? AND report_date <= ?",
        (start_s, end_s),
    ).fetchall()

    docs = {}
    for report_date, page, title, category, note_count in conn.execute(
        "SELECT report_date, page, title, category, note_count FROM documents WHERE report_date >= ? AND report_date <= ?",
        (start_s, end_s),
    ):
        item = docs.setdefault(page, {"title": title, "category": category, "notes": 0, "report_date": report_date})
        item["notes"] += note_count
        if report_date >= item["report_date"]:
            item["title"] = title
            item["category"] = category
            item["report_date"] = report_date

    apis = {}
    for report_date, method, path, service, category, note_count in conn.execute(
        "SELECT report_date, method, path, service, category, note_count FROM endpoints WHERE report_date >= ? AND report_date <= ?",
        (start_s, end_s),
    ):
        key = ((method or "").lower(), (path or "").lower())
        item = apis.setdefault(key, {
            "method": method, "path": path, "service": service, "category": category,
            "notes": 0, "report_date": report_date,
        })
        item["notes"] += note_count
        if report_date >= item["report_date"]:
            item["method"] = method
            item["path"] = path
            item["service"] = service
            item["category"] = category
            item["report_date"] = report_date

    created = {}
    checked = {}
    for report_date, iid, kind_name, title, state in conn.execute(
        "SELECT report_date, iid, kind, title, state FROM issues WHERE report_date >= ? AND report_date <= ?",
        (start_s, end_s),
    ):
        bucket = created if kind_name == "created" else checked
        item = bucket.setdefault(iid, {"title": title, "state": state, "report_date": report_date})
        if report_date >= item["report_date"]:
            item["title"] = title
            item["state"] = state
            item["report_date"] = report_date

    titles = {"week": labels["weekTitle"], "month": labels["monthTitle"], "range": labels["rangeTitle"]}
    lines = ["# " + titles.get(kind, labels["rangeTitle"]) + " - " + start_s + " " + end_s, ""]
    lines.append(labels["rangeDays"].replace("{from}", start_s).replace("{to}", end_s))
    clocks = {(row[0], row[1]) for row in windows}
    if len(clocks) == 1:
        clock_from, clock_to = next(iter(clocks))
        lines.append(labels["rangeHours"].replace("{from}", clock_from).replace("{to}", clock_to))
    if missing:
        lines.append(labels["missingDays"].replace("{days}", ", ".join(missing)))

    api_groups = {}
    for item in apis.values():
        api_groups[item["category"]] = api_groups.get(item["category"], 0) + 1
    doc_groups = {}
    for item in docs.values():
        doc_groups[item["category"]] = doc_groups.get(item["category"], 0) + 1
    lines.append("")
    add_category_lines(lines, api_groups, labels["categoryApiLine"], order)
    add_category_lines(lines, doc_groups, labels["categoryDocLine"], order)

    story_notes = sum(item["notes"] for item in docs.values())
    api_notes = sum(item["notes"] for item in apis.values())
    lines.extend(["", rule, "", "## " + labels["summary"]])
    summary = []
    if docs:
        summary.append("- " + labels["summaryDocs"] + ": " + str(len(docs)) + " " + labels["documents"] + " - " + str(story_notes) + " " + labels["comments"])
    if apis:
        summary.append("- " + labels["summaryApis"] + ": " + str(len(apis)) + " " + labels["endpoints"] + " - " + str(api_notes) + " " + labels["comments"])
    if created:
        summary.append("- " + labels["summaryCreated"] + ": " + str(len(created)) + " " + labels["issues"])
    if checked:
        summary.append("- " + labels["summaryChecked"] + ": " + str(len(checked)) + " " + labels["issues"])
    lines.extend(summary or ["- " + labels["empty"]])

    if span_days > 1:
        stats = per_day_counts(conn, start_s, end_s)
        weekdays = labels.get("weekdayNames") or {}
        lines.extend(["", rule, "", "## " + labels["summaryPerDay"]])
        for day in daterange(start, end):
            key = day.isoformat()
            name = weekdays.get(str(day.weekday())) or labels["unknown"]
            if key not in stored_set:
                lines.append("- " + fill(labels["perDayNoData"], weekday=name))
                continue
            row = stats.get(key) or {}
            parts = []
            if row.get("docs", 0):
                parts.append(fill(labels["perDayDocsPart"], docs=row["docs"], docNotes=row.get("docNotes", 0)))
            if row.get("apis", 0):
                parts.append(fill(labels["perDayApisPart"], apis=row["apis"], apiNotes=row.get("apiNotes", 0)))
            if row.get("created", 0):
                parts.append(fill(labels["perDayCreatedPart"], created=row["created"]))
            if row.get("checked", 0):
                parts.append(fill(labels["perDayCheckedPart"], checked=row["checked"]))
            if parts:
                lines.append("- " + name + " - " + labels["perDayJoin"].join(parts))

    lines.extend([
        "",
        rule,
        "",
        "## " + labels["section1"],
    ])
    if docs:
        lines.append(labels["total"] + ": " + str(len(docs)) + " " + labels["documents"] + " - " + str(story_notes) + " " + labels["comments"])
    else:
        lines.append("- " + labels["empty"])
    for item in sorted(docs.values(), key=lambda row: (-row["notes"], row["title"])):
        lines.append("- " + item["title"] + " - " + str(item["notes"]) + " " + labels["comments"])

    lines.extend([
        "",
        rule,
        "",
        "## " + labels["section2"],
    ])
    if apis:
        lines.append(labels["total"] + ": " + str(len(apis)) + " " + labels["endpoints"] + " - " + str(api_notes) + " " + labels["comments"])
    else:
        lines.append("- " + labels["empty"])
    for item in sorted(apis.values(), key=lambda row: (-row["notes"], row["service"] or "")):
        label = item["service"] or item["path"] or labels["unknown"]
        endpoint = (item["method"] + " " + item["path"]).strip()
        if endpoint:
            lines.append("- " + label + " - `" + endpoint + "`")
        else:
            lines.append("- " + label)

    lines.extend([
        "",
        rule,
        "",
        "## " + labels["section3"],
    ])
    if created:
        lines.append(labels["total"] + ": " + str(len(created)) + " " + labels["issues"])
    else:
        lines.append("- " + labels["empty"])
    for iid in sorted(created):
        lines.append("- #" + str(iid) + " " + created[iid]["title"])

    lines.extend([
        "",
        rule,
        "",
        "## " + labels["section4"],
    ])
    if checked:
        lines.append(labels["total"] + ": " + str(len(checked)) + " " + labels["issues"])
    else:
        lines.append("- " + labels["empty"])
    for iid in sorted(checked):
        item = checked[iid]
        lines.append("- #" + str(iid) + " " + item["title"] + " - " + labels["state"] + ": " + state_label(labels, item["state"]))

    lines.extend(["", rule, "", labels["sourceDb"], ""])
    return "\n".join(lines), len(stored), missing


def default_db():
    return repo_root() / ".data" / "reports.db"


def default_config():
    return Path(__file__).resolve().parent.parent / "config" / "report-config.json"


def main(argv):
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)

    save = sub.add_parser("save")
    save.add_argument("--db")
    save.add_argument("--json", required=True)

    listing = sub.add_parser("list")
    listing.add_argument("--db")

    span = sub.add_parser("range")
    span.add_argument("--db")
    span.add_argument("--config")
    span.add_argument("--from", dest="start", required=True)
    span.add_argument("--to", dest="end", required=True)
    span.add_argument("--kind", choices=("week", "month", "range"), default="range")
    span.add_argument("--out")

    args = parser.parse_args(argv)
    db_path = Path(args.db) if args.db else default_db()
    conn = connect(db_path)
    try:
        if args.cmd == "save":
            payload = json.loads(Path(args.json).read_text(encoding="utf-8"))
            save_payload(conn, payload)
            print("[store] date=" + payload["date"])
            return 0
        if args.cmd == "list":
            rows = conn.execute(
                "SELECT d.report_date, "
                "(SELECT COUNT(*) FROM documents x WHERE x.report_date = d.report_date), "
                "(SELECT COUNT(*) FROM endpoints x WHERE x.report_date = d.report_date), "
                "(SELECT COUNT(*) FROM issues x WHERE x.report_date = d.report_date AND x.kind = 'created'), "
                "(SELECT COUNT(*) FROM issues x WHERE x.report_date = d.report_date AND x.kind = 'checked') "
                "FROM days d ORDER BY d.report_date"
            ).fetchall()
            if not rows:
                print("[store] days=0")
                return 0
            for report_date, docs, apis, created, checked in rows:
                print("date=%s docs=%s apis=%s created=%s checked=%s" % (report_date, docs, apis, created, checked))
            return 0
        cfg = load_config(args.config or default_config())
        text, stored, missing = build_report(conn, cfg, parse_day(args.start), parse_day(args.end), args.kind)
        if args.out:
            out = Path(args.out)
        else:
            name = "report-%s-%s_%s.txt" % (args.kind, args.start, args.end)
            out = repo_root() / ".tmp" / "daily-report" / name
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text, encoding="utf-8")
        print("[report] " + str(out))
        print("[store] days=%s missing=%s" % (stored, len(missing)))
        return 0
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
