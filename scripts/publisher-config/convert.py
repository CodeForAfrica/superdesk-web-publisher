#!/usr/bin/env python3
"""Convert a Publisher (SWP) config dump into the tracked JSON tree.

Publisher tenant config lives in Postgres and is destroyed by a wipe-and-reseed
(see docs/plans/publisher-config-as-tracked-json.md in the superproject). This is
the one-way converter that turns the opaque `dump.sh` output into the readable,
reviewable tree under `etc/docker/bootstrap/publisher-config/`, which
`swp:config:load` re-seeds at bootstrap. Pairs with `dump.sh`: dump captures a
running instance, this converts it, and the diff is the review.

Input:  the directory produced by `dump.sh` (the folder holding the per-table
        `swp_*.json` files, e.g. `publisher-config/<env>/` inside the tarball).
        Point `--source` at the extracted root or that folder; the first
        directory containing `swp_*.json` wins.

Output (under `--dest`, default `etc/docker/bootstrap/publisher-config`):

    routes.json          list, ordered by position
    rules.json           list, ordered by (tenant then priority then name)
    menus.json           one nested tree per menu root
    content_lists.json   list, ordered by name, each carrying a `seed` policy
    settings.json        list of tenant/global/theme overrides (user-scope dropped)
    (webhooks/output_channels/... : written only if non-empty)

The hard part vs. the Superdesk content-config converter: SWP uses integer
autoincrement PKs and FK *references* (menu.parent_id/route_id, rule
configuration's embedded route id). So the tree is NATURAL-KEYED — FKs become
names, and the loader resolves them back. And several columns are PHP
`serialize()` blobs; they are decoded to plain JSON here (readable, reviewable)
and re-encoded by the PHP loader with `serialize()`.

Faithfulness / determinism (so a re-dump is a reviewable diff, not churn):
  * per-instance PKs, tree bookkeeping (lft/rgt/level/root_id/parent_id),
    position (implied by array order), timestamps and tenant/org scoping are
    stripped;
  * keys are sorted; short list items are emitted on one line;
  * PHP-serialize round-trips: an empty array `a:0:{}` -> `[]`, an assoc array
    -> a JSON object, a sequential array -> a JSON list.
"""

import argparse
import json
from pathlib import Path

# Content-list names that are test artifacts, never seeded. See the plan (§5.2):
# `probe-delete-me` is a staging probe leftover.
CONTENT_LIST_NAME_DENYLIST = {"probe-delete-me"}

# Homepage lists get random-filled by seed-content-lists.sh with fresh fact-checks;
# everything else is created empty for editors to curate (About/Media Centre
# editorial collections). "Media Centre — In the News" is also fact-check-driven,
# not authored, so it is random-filled too. A random-fill list's membership is
# runtime, so it is NOT captured into content_list_items.json on a refresh.
RANDOM_FILL_PREFIX = "Homepage"
RANDOM_FILL_NAMES = {"Page — Media Centre — In the News"}


def is_random_fill(name):
    return name.startswith(RANDOM_FILL_PREFIX) or name in RANDOM_FILL_NAMES

# Settings scopes that are runtime per-user state, never tracked.
SETTINGS_SCOPE_DENYLIST = {"user"}

COMPACT_LINE_MAX = 800
INDENT = "    "


# --------------------------------------------------------------------------- #
# PHP serialize() decoder — dependency-free, just enough for SWP's columns.
# Handles: N (null), b (bool), i (int), d (float), s (string), a (array).
# A PHP array with sequential integer keys 0..n-1 decodes to a JSON list; any
# other key set decodes to a JSON object (string keys). This mirrors what
# `json_decode($x, true)` + `serialize()` reproduce on the loader side.
# --------------------------------------------------------------------------- #
class _PhpParser:
    def __init__(self, data):
        self.s = data
        self.i = 0

    def _expect(self, ch):
        if self.s[self.i] != ch:
            raise ValueError(f"expected {ch!r} at {self.i} in {self.s!r}")
        self.i += 1

    def _read_until(self, ch):
        j = self.s.index(ch, self.i)
        out = self.s[self.i:j]
        self.i = j + 1
        return out

    def parse(self):
        t = self.s[self.i]
        if t == "N":
            self.i += 2  # 'N;'
            return None
        self.i += 2  # skip 'X:'
        if t == "b":
            v = self._read_until(";")
            return v == "1"
        if t == "i":
            return int(self._read_until(";"))
        if t == "d":
            return float(self._read_until(";"))
        if t == "s":
            length = int(self._read_until(":"))
            self._expect('"')
            # length is in BYTES; slice on the utf-8 encoding to be exact.
            raw = self.s[self.i:].encode("utf-8")[:length].decode("utf-8")
            self.i += len(raw)
            self._expect('"')
            self._expect(";")
            return raw
        if t == "a":
            count = int(self._read_until(":"))
            self._expect("{")
            items = []
            for _ in range(count):
                key = self.parse()
                val = self.parse()
                items.append((key, val))
            self._expect("}")
            keys = [k for k, _ in items]
            if keys == list(range(len(keys))):
                return [v for _, v in items]
            return {str(k): v for k, v in items}
        raise ValueError(f"unknown PHP type {t!r} at {self.i}")


def php_unserialize(value):
    """Decode a PHP serialize() string to a JSON-able structure. Called only on
    columns known to hold serialized blobs. Passes through None/empty and, as a
    safety net, anything that does not start like a serialized value or fails to
    parse (returned verbatim rather than raising)."""
    if not isinstance(value, str) or value == "":
        return value
    if value != "N;" and not (len(value) > 1 and value[1] == ":"):
        return value  # not a serialized blob
    try:
        return _PhpParser(value).parse()
    except (ValueError, IndexError):
        return value


# --------------------------------------------------------------------------- #
# Deterministic pretty-printer (identical policy to the content-config convert).
# --------------------------------------------------------------------------- #
def _compact(obj):
    return json.dumps(obj, sort_keys=True, ensure_ascii=False, separators=(", ", ": "))


def emit(obj, indent=0):
    pad = INDENT * indent
    child = INDENT * (indent + 1)
    if isinstance(obj, dict):
        if not obj:
            return "{}"
        keys = sorted(obj)
        lines = ["{"]
        for i, k in enumerate(keys):
            tail = "," if i < len(keys) - 1 else ""
            lines.append(
                f"{child}{json.dumps(k, ensure_ascii=False)}: "
                f"{emit(obj[k], indent + 1)}{tail}"
            )
        lines.append(pad + "}")
        return "\n".join(lines)
    if isinstance(obj, list):
        if not obj:
            return "[]"
        lines = ["["]
        for i, v in enumerate(obj):
            tail = "," if i < len(obj) - 1 else ""
            compact = _compact(v)
            if len(compact) <= COMPACT_LINE_MAX:
                lines.append(f"{child}{compact}{tail}")
            else:
                lines.append(f"{child}{emit(v, indent + 1)}{tail}")
        lines.append(pad + "]")
        return "\n".join(lines)
    return json.dumps(obj, ensure_ascii=False)


def write_json(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(emit(obj) + "\n", encoding="utf-8")


def load_table(src_dir, name):
    path = src_dir / f"{name}.json"
    if not path.exists():
        return []
    return json.loads(path.read_text(encoding="utf-8"))


def find_dump_dir(source):
    source = Path(source)
    if list(source.glob("swp_*.json")):
        return source
    hits = sorted(source.rglob("swp_content_list.json"))
    if not hits:
        raise SystemExit(f"No swp_*.json dump files found under {source}")
    return hits[0].parent


# --------------------------------------------------------------------------- #
# Per-table conversion.
# --------------------------------------------------------------------------- #
def convert_routes(rows):
    """Emit the theme-generator route format (the keys RouteType accepts), so the
    loader can feed them straight to ThemeRoutesGenerator. RouteService::createRoute
    DERIVES the collection/content boilerplate (variable_pattern, the slug
    requirement, defaults, staticprefix) from name+type, so those columns are NOT
    tracked — they are reproduced faithfully at load. Only fields the form owns are
    kept, and only when non-default (so the files stay minimal and diffs small).

    Caveat: a route with a hand-customised variable_pattern/requirements (only
    possible for TYPE_CUSTOM) would not round-trip — none exist today; add those
    keys here if one ever appears in a dump.
    """
    by_id = {r["id"]: r for r in rows}
    out = []
    for r in sorted(rows, key=lambda r: (r.get("position") or 0, r["id"])):
        doc = {
            "name": r["name"],
            "slug": r["slug"],
            "type": r["type"],
            # createRoute() reads $routeData['parent'] unconditionally -> keep it.
            "parent": by_id[r["parent_id"]]["name"] if r.get("parent_id") else None,
        }
        if r.get("template_name"):
            doc["templateName"] = r["template_name"]
        if r.get("articles_template_name"):
            doc["articlesTemplateName"] = r["articles_template_name"]
        if r.get("cache_time_in_seconds"):
            doc["cacheTimeInSeconds"] = r["cache_time_in_seconds"]
        if r.get("description"):
            doc["description"] = r["description"]
        out.append(doc)
    # The loader creates routes in array order and resolves `parent` by name in
    # the same pass, so a parent MUST precede its children or the child lands
    # parentless. Staging's position order interleaves them, so re-order into a
    # stable topological order (roots first, then each level) here.
    return _order_parents_first(out)


def _order_parents_first(routes):
    by_name = {r["name"]: r for r in routes}
    ordered, placed = [], set()

    def place(r):
        if r["name"] in placed:
            return
        parent = r.get("parent")
        if parent and parent in by_name and parent not in placed:
            place(by_name[parent])
        placed.add(r["name"])
        ordered.append(r)

    for r in routes:  # preserve original order among siblings
        place(r)
    return ordered


def convert_rules(rows, route_id_to_name, summary):
    out = []
    for r in sorted(
        rows, key=lambda r: (r.get("tenant_code") or "", r.get("priority") or 0, r["name"])
    ):
        # Organization-scoped rules (tenant_code NULL) — the "send everything to
        # the default tenant" catch-all — are routing INFRASTRUCTURE created next
        # to the tenant in bootstrap-publisher.sh, not tenant content. They are
        # also invisible to the tenant-scoped rule repository the loader uses, so
        # tracking them here would defeat its idempotency. Left to the bootstrap.
        if r.get("tenant_code") is None:
            summary["skipped_rules"].append(r["name"])
            continue
        cfg = php_unserialize(r.get("configuration"))
        # Translate the embedded route FK id -> route name so the tree is portable.
        if isinstance(cfg, dict) and isinstance(cfg.get("route"), int):
            cfg["route"] = route_id_to_name.get(cfg["route"], cfg["route"])
        out.append({
            "name": r["name"],
            "expression": r["expression"],
            "priority": r.get("priority") or 0,
            # null tenant_code => organization-scoped (the catch-all); a code =>
            # tenant-scoped. The loader keys FK resolution off this.
            "tenant_code": r.get("tenant_code"),
            "description": r.get("description"),
            "configuration": cfg,
        })
    return out


def _menu_node(row, children_by_parent, route_id_to_name):
    # Theme-generator menu format (the keys MenuType accepts). The *_attributes
    # columns are rebuilt by MenuItemManager via the KnpMenu extension chain, so
    # they are not tracked. createMenu() reads $menuData['route'] unconditionally,
    # so 'route' is always present (name or null).
    doc = {
        "name": row["name"],
        "label": row.get("label") or "",
        "uri": row.get("uri"),
        "route": route_id_to_name.get(row["route_id"]) if row.get("route_id") else None,
    }
    kids = sorted(
        children_by_parent.get(row["id"], []),
        key=lambda c: (c.get("position") or 0, c.get("lft") or 0, c["id"]),
    )
    if kids:
        doc["children"] = [
            _menu_node(k, children_by_parent, route_id_to_name) for k in kids
        ]
    return doc


def convert_menus(rows, route_id_to_name):
    children_by_parent = {}
    for r in rows:
        children_by_parent.setdefault(r.get("parent_id"), []).append(r)
    roots = sorted(
        (r for r in rows if not r.get("parent_id")),
        key=lambda r: (r.get("position") or 0, r.get("lft") or 0, r["id"]),
    )
    return [_menu_node(r, children_by_parent, route_id_to_name) for r in roots]


def convert_content_lists(rows, summary):
    out = []
    for r in sorted(rows, key=lambda r: r["name"]):
        name = r["name"]
        if name in CONTENT_LIST_NAME_DENYLIST:
            summary["skipped_lists"].append(name)
            continue
        filters = php_unserialize(r.get("filters"))
        if not filters:  # empty a:0:{} -> null (a manual list has no criteria)
            filters = None
        # ContentListType field names (camelCase). `seed` is OURS, not a form
        # field — the loader strips it before submitting; seed-content-lists.sh
        # reads it to decide which lists to random-fill. `filters` is stored
        # decoded for readability; the loader json_encodes it for the form.
        doc = {
            "name": name,
            "type": r["type"],
            "seed": "random" if is_random_fill(name) else "empty",
        }
        if r.get("description"):
            doc["description"] = r["description"]
        if r.get("list_limit") is not None:
            doc["limit"] = r["list_limit"]
        if r.get("cache_life_time") is not None:
            doc["cacheLifeTime"] = r["cache_life_time"]
        if filters is not None:
            doc["filters"] = filters
        out.append(doc)
    return out


def convert_membership(rows, summary):
    """Group the curated-list membership projection into an ordered map keyed by
    list name. content_id is never tracked — only the stable article GUID
    (swp_article.code). The seeder resolves guid -> local article id at seed time.
    Test-artifact lists are dropped (same denylist as the list definitions).
    Random-fill lists (homepage, In the News) have runtime membership seeded from
    fresh fact-checks, so their contents are never captured here."""
    by_list = {}
    for r in sorted(rows, key=lambda r: (r["list"], r.get("position") or 0)):
        name = r["list"]
        if name in CONTENT_LIST_NAME_DENYLIST or is_random_fill(name):
            continue
        by_list.setdefault(name, []).append({
            "guid": r["guid"],
            "slug": r.get("slug"),
            "sticky": bool(r.get("sticky")),
        })
    summary["membership_lists"] = len(by_list)
    summary["membership_items"] = sum(len(v) for v in by_list.values())
    return by_list


def convert_settings(rows, summary):
    out = []
    for r in sorted(rows, key=lambda r: (r.get("scope") or "", r["name"])):
        scope = r.get("scope")
        if scope in SETTINGS_SCOPE_DENYLIST:
            summary["skipped_settings"].append(r["name"])
            continue
        out.append({
            "name": r["name"],
            "scope": scope,
            # owner is an instance-specific id; there is a single tenant/org, so
            # it is carried verbatim for now. When a real override appears,
            # translate to a portable ref (see the plan).
            "owner": r.get("owner"),
            "value": r.get("value"),
        })
    return out


# Latent config tables: dumped for capture, written only if non-empty. Faithful
# passthrough (serialized columns left as-is until one actually has data to shape).
LATENT_TABLES = {
    # swp_webhook is intentionally NOT here: the revalidate webhook embeds a
    # shared secret in its URL, so it is excluded from the dump (see dump.sh).
    "swp_output_channel": "output_channels.json",
    "swp_fbia_feed": "fbia_feeds.json",
    "swp_fbia_page": "fbia_pages.json",
    "swp_apple_news_config": "apple_news_configs.json",
    "swp_redirect_route": "redirect_routes.json",
}


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--source", required=True, help="dump dir or tarball-extracted root")
    parser.add_argument(
        "--dest", default="etc/docker/bootstrap/publisher-config",
        help="output directory (default: etc/docker/bootstrap/publisher-config)",
    )
    args = parser.parse_args(argv)

    src = find_dump_dir(args.source)
    dest = Path(args.dest)
    summary = {"skipped_lists": [], "skipped_rules": [], "skipped_settings": [], "empty": [], "written": []}

    routes = load_table(src, "swp_route")
    rules = load_table(src, "swp_rule")
    menus = load_table(src, "swp_menu")
    lists = load_table(src, "swp_content_list")
    settings = load_table(src, "swp_settings")
    route_id_to_name = {r["id"]: r["name"] for r in routes}

    write_json(dest / "routes.json", convert_routes(routes)); summary["written"].append("routes")
    write_json(dest / "rules.json", convert_rules(rules, route_id_to_name, summary)); summary["written"].append("rules")
    write_json(dest / "menus.json", convert_menus(menus, route_id_to_name)); summary["written"].append("menus")
    write_json(dest / "content_lists.json", convert_content_lists(lists, summary)); summary["written"].append("content_lists")
    write_json(dest / "settings.json", convert_settings(settings, summary)); summary["written"].append("settings")

    membership = load_table(src, "content_list_membership")
    write_json(dest / "content_list_items.json", convert_membership(membership, summary))
    summary["written"].append("content_list_items")

    for table, filename in LATENT_TABLES.items():
        rows = load_table(src, table)
        if rows:
            write_json(dest / filename, rows)
            summary["written"].append(filename)
        else:
            summary["empty"].append(table)

    print(f"Source: {src}")
    print(f"Dest:   {dest}")
    print(f"Written:            {summary['written']}")
    print(f"Skipped lists:      {summary['skipped_lists']}")
    print(f"Skipped rules(org): {summary['skipped_rules']}")
    print(f"Skipped settings:   {summary['skipped_settings']}")
    print(f"Empty (not written):{summary['empty']}")


if __name__ == "__main__":
    main()
