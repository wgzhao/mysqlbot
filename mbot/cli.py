"""命令行入口。

    mbot check   跑一轮只读巡检
    mbot probe   只探能力位
    mbot list    列出规则库
    mbot lint    校验规则文件契约
    mbot doctor  自检（找客户端、找规则目录、做一次连通性测试）
"""

from __future__ import annotations

import argparse
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

from . import __version__
from .conn import QueryError, Target, make_conn
from .probe import probe
from .report import (
    ERROR,
    HIT,
    build_payload,
    overall_severity,
    summarize,
    to_json,
    to_markdown,
    to_sarif,
    to_table,
)
from .rule import SEVERITY_ORDER, load_rules
from .runner import RunOptions, default_init_sql, run_all, select_rules

EXIT_OK = 0
EXIT_FINDINGS = 1
EXIT_FAILURE = 2
EXIT_CONTRACT = 3

PKG_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_RULES_DIR = PKG_ROOT / "rules"


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="mbot",
        description="mysqlbot —— 只读、确定性、无 agent 的 MySQL 体检探针",
    )
    p.add_argument("--version", action="version", version=f"mysqlbot {__version__}")

    g = p.add_argument_group("目标库")
    g.add_argument("--dsn", default=os.environ.get("MYSQLBOT_DSN", ""), help="mysql://user:pass@host:port/")
    g.add_argument("--host", default=os.environ.get("MYSQLBOT_HOST", ""))
    g.add_argument("--port", type=int, default=int(os.environ.get("MYSQLBOT_PORT") or 0))
    g.add_argument("-u", "--user", default=os.environ.get("MYSQLBOT_USER", ""))
    g.add_argument("-p", "--password", default=os.environ.get("MYSQLBOT_PASSWORD", os.environ.get("MYSQL_PWD", "")))
    g.add_argument("-S", "--socket", default=os.environ.get("MYSQLBOT_SOCKET", ""))
    g.add_argument("--defaults-file", default="", help="传给 mysql 客户端的 --defaults-file（可复用 ~/.my.cnf 里的 login-path）")
    g.add_argument("--mysql-binary", default=os.environ.get("MYSQLBOT_MYSQL_BIN", ""), help="mysql 客户端路径")
    g.add_argument("--driver", choices=["auto", "cli", "pymysql"], default="auto")
    g.add_argument("--timeout", type=int, default=60, help="单条规则超时秒数")

    c = p.add_argument_group("规则与输出")
    c.add_argument("--rules-dir", default=str(DEFAULT_RULES_DIR))
    c.add_argument("--only", action="append", default=[], help="只跑这些规则 id（支持 glob），可重复")
    c.add_argument("--skip", action="append", default=[], help="跳过这些规则 id（支持 glob），可重复")
    c.add_argument("--dimension", action="append", default=[], help="按维度过滤")
    c.add_argument("--scope", action="append", default=[], help="按作用域过滤")
    c.add_argument("--tag", action="append", default=[], help="按标签过滤")
    c.add_argument("--min-severity", choices=list(SEVERITY_ORDER), default="info")
    c.add_argument("-o", "--output", choices=["table", "json", "markdown", "sarif"], default="table")
    c.add_argument("--out-file", default="", help="写入文件而不是 stdout")
    c.add_argument("-v", "--verbose", action="store_true")
    c.add_argument("--init-sql", action="append", default=[], help="会话前导语句（需不产生结果集），可重复")
    c.add_argument("--no-init", action="store_true", help="不注入默认会话前导（谨慎：会导致表统计读到缓存值）")
    c.add_argument("--ignore-min-uptime", action="store_true",
                   help="忽略规则的运行时长门禁（仅用于自测/演练；生产上会让累计型指标的结论失真）")
    c.add_argument("--fail-on", choices=["none", "info", "warn", "critical"], default="warn",
                   help="命中达到该严重度时退出码为 1（默认 warn）")
    c.add_argument("--label", default="", help="报告里显示的实例标签")

    p.add_argument("command", nargs="?", default="check",
                   choices=["check", "probe", "list", "lint", "doctor", "docs"])
    return p


def _target_from_args(a) -> Target:
    if a.dsn:
        t = Target.from_dsn(a.dsn)
        if a.user:
            t.user = a.user
        if a.password:
            t.password = a.password
        if a.host:
            t.host = a.host
        if a.port:
            t.port = a.port
        if a.socket:
            t.socket = a.socket
    else:
        t = Target(host=a.host, port=a.port, user=a.user, password=a.password, socket=a.socket)
    t.defaults_file = a.defaults_file
    return t


def _label(a, caps) -> str:
    if a.label:
        return a.label
    t = _target_from_args(a)
    where = t.socket or (f"{t.host or 'localhost'}:{t.port or 3306}")
    return f"{where}/{t.user or caps.current_user}"


def _load(a):
    rules, errors = load_rules(Path(a.rules_dir))
    return rules, errors


# ---------------------------------------------------------------- commands


def cmd_probe(a) -> int:
    conn = make_conn(_target_from_args(a), a.driver, a.mysql_binary, a.timeout)
    try:
        conn.connect()
        caps = probe(conn)
    except QueryError as exc:
        print(f"连接失败：{exc}", file=sys.stderr)
        return EXIT_FAILURE
    payload = {
        "schema": "mysqlbot/probe/v1",
        "version": caps.version_str,
        "version_comment": caps.version_comment,
        "edition": "MariaDB" if caps.is_mariadb else ("Percona" if caps.is_percona else "MySQL"),
        "current_user": caps.current_user,
        "flags": caps.flags,
        "missing_reasons": caps.reasons,
        "facts": caps.facts,
        "grants": caps.grants,
        "visible_schemas": caps.schemas,
        "notes": caps.notes,
    }
    text = to_json(payload)
    if a.out_file:
        Path(a.out_file).write_text(text, encoding="utf-8")
    else:
        print(text)
    return EXIT_OK


def cmd_list(a) -> int:
    rules, errors = _load(a)
    if errors:
        for e in errors:
            print(f"规则问题: {e}", file=sys.stderr)
    rows = []
    for r in rules:
        rows.append((r.severity, r.id, r.dimension, r.scope, r.obj, r.exactness, r.since or "-", ",".join(r.requires) or "-", r.title))
    rows.sort(key=lambda x: (-SEVERITY_ORDER.get(x[0], 0), x[1]))
    hdr = ("SEV", "ID", "DIM", "SCOPE", "OBJECT", "EXACT", "SINCE", "REQUIRES", "TITLE")
    widths = [max(len(str(hdr[i])), *(len(str(r[i])) for r in rows)) if rows else len(hdr[i]) for i in range(len(hdr))]
    line = "  ".join(str(hdr[i]).ljust(widths[i]) for i in range(len(hdr)))
    print(line)
    print("-" * len(line))
    for r in rows:
        print("  ".join(str(r[i]).ljust(widths[i]) for i in range(len(hdr))))
    print(f"\n共 {len(rules)} 条规则")
    return EXIT_CONTRACT if errors else EXIT_OK


def cmd_lint(a) -> int:
    from .rule import DIMENSIONS, EXACTNESS, SCOPES

    rules, errors = _load(a)
    problems = list(errors)
    seen_ids: dict[str, str] = {}
    for r in rules:
        if r.id in seen_ids:
            problems.append(f"{r.path.name}: @id {r.id} 与 {seen_ids[r.id]} 重复")
        seen_ids[r.id] = r.path.name
        if not r.title:
            problems.append(f"{r.path.name}: 缺少 @title")
        if not r.remediation:
            problems.append(f"{r.path.name}: 缺少 @remediation（每条规则都应给出处置建议）")
        if not r.caveats:
            problems.append(f"{r.path.name}: 缺少 @caveats（必须写明误报条件）")
        if r.severity not in SEVERITY_ORDER:
            problems.append(f"{r.path.name}: @severity 非法")
        if r.dimension not in DIMENSIONS:
            problems.append(f"{r.path.name}: @dimension {r.dimension!r} 不在受控词表 {sorted(DIMENSIONS)}")
        if r.scope not in SCOPES:
            problems.append(f"{r.path.name}: @scope {r.scope!r} 不在受控词表 {sorted(SCOPES)}")
        if r.exactness not in EXACTNESS:
            problems.append(f"{r.path.name}: @exactness {r.exactness!r} 不在受控词表 {sorted(EXACTNESS)}")
        if "severity" not in r.sql.lower():
            problems.append(f"{r.path.name}: SQL 里没有出现 severity（契约要求每行含 severity 列）")
        if r.safety and not r.safety_note:
            problems.append(f"{r.path.name}: 声明了 @safety 就必须同时写 @safety_note（解释执行风险）")
        if r.min_uptime < 0:
            problems.append(f"{r.path.name}: @min_uptime 不能为负")
        for need in r.requires:
            if need not in _KNOWN_CAPS:
                problems.append(f"{r.path.name}: @requires 里有未知能力位 {need!r}")
    if problems:
        for p in problems:
            print(f"✗ {p}")
        print(f"\n{len(problems)} 个问题 / {len(rules)} 条规则")
        return EXIT_CONTRACT
    print(f"✓ {len(rules)} 条规则全部符合契约")
    return EXIT_OK


_KNOWN_CAPS = {
    "p_s", "p_s_statements", "p_s_waits", "p_s_mdl", "p_s_locks", "p_s_memory",
    "sys", "sys_indexes", "sys_statements", "sys_functions", "process", "replication",
    "schema_select", "global_select", "super", "innodb", "mysql84", "mariadb", "audit_admin",
}


def cmd_docs(a) -> int:
    """从规则头部元数据生成规则目录（docs/findings.md）。

    文档从规则本身生成，而不是手工维护——否则规则一改，文档就开始说谎。
    """
    rules, errors = _load(a)
    for e in errors:
        print(f"规则问题: {e}", file=sys.stderr)

    order = {sev: i for i, sev in enumerate(("critical", "warn", "info"))}
    rules.sort(key=lambda r: (order.get(r.severity, 9), r.dimension, r.id))

    out: list[str] = []
    out.append("# mysqlbot 规则目录")
    out.append("")
    out.append(f"共 **{len(rules)}** 条规则。本文件由 `mbot docs` 从每条规则头部的元数据生成，"
               "请勿手工编辑——改规则后重新生成即可。")
    out.append("")
    out.append("## 阅读约定")
    out.append("")
    out.append("- **严重度**：`critical` 需要立即处置；`warn` 需要评估；`info` 是事实陈述与优化建议。"
               "规则 SQL 可以用 `severity` 列升级自身严重度（例如等待时间跨过阈值）。")
    out.append("- **exactness（结论精确度）**：")
    out.append("  - `exact` 直接读出的事实（变量、版本）")
    out.append("  - `catalog` 来自数据字典的确定结构（表定义、锁、事务）")
    out.append("  - `cumulative` 自实例启动累计的计数器，重启清零")
    out.append("  - `sampled` 依赖统计采样，需运行足够久才可信")
    out.append("  - `scraped` 抓取的瞬时值")
    out.append("- **能力位（@requires）**：缺失时该规则会被**显式跳过**并在报告里列明原因，"
               "不会静默给出「干净」结论。")
    out.append("- **运行时长（@min_uptime）**：累计型指标在实例重启后无意义，"
               "不满足时同样显式跳过。")
    out.append("- 每条规则都是独立 SQL，可以在 mysql 客户端 / DBeaver 里直接单独执行："
               "返回 0 行 = 未命中，返回行 = 命中，每行带 `severity` 列。")
    out.append("")

    # 总览表
    out.append("## 总览")
    out.append("")
    out.append("| 严重度 | 规则 | 维度 | 作用域 | 对象 | 精确度 | 起始版本 | 依赖能力位 |")
    out.append("|---|---|---|---|---|---|---|---|")
    for r in rules:
        out.append(
            f"| {r.severity} | [`{r.id}`](#{r.id}) | {r.dimension} | {r.scope} | `{r.obj}` "
            f"| {r.exactness} | {r.since or '-'} | {', '.join(r.requires) or '-'} |"
        )
    out.append("")

    # 明细
    for r in rules:
        out.append(f"## {r.id}")
        out.append("")
        out.append(f"**{r.title}**")
        out.append("")
        out.append(f"- 严重度 `{r.severity}` · 维度 `{r.dimension}` · 作用域 `{r.scope}` · 对象 `{r.obj}`")
        out.append(f"- 精确度 `{r.exactness}` · 起始版本 `{r.since or '不限'}`"
                   + (f" · 移除于 `{r.removed_in}`" if r.removed_in else ""))
        out.append(f"- 依赖能力位：{', '.join(f'`{x}`' for x in r.requires) or '无'}"
                   + (f" · 需要运行满 {r.min_uptime}s" if r.min_uptime else ""))
        out.append(f"- 参考：{r.ref}")
        if r.tags:
            out.append(f"- 标签：{', '.join(r.tags)}")
        out.append("")
        if r.remediation:
            out.append(f"**处置**：{r.remediation}")
            out.append("")
        if r.caveats:
            out.append(f"**注意（误报条件与局限）**：{r.caveats}")
            out.append("")
        if r.safety:
            out.append(f"**⚠️ 含可执行语句**：`{r.safety}` — {r.safety_note}")
            out.append("")
        out.append("<details><summary>SQL</summary>")
        out.append("")
        out.append("```sql")
        out.append(r.sql)
        out.append("```")
        out.append("")
        out.append("</details>")
        out.append("")

    text = "\n".join(out)
    if a.out_file:
        Path(a.out_file).write_text(text, encoding="utf-8")
        print(f"已写入 {a.out_file}")
    else:
        print(text)
    return EXIT_OK


def cmd_doctor(a) -> int:
    ok = True
    from .conn import find_cli

    binary = a.mysql_binary or find_cli()
    print(f"mysql 客户端 : {binary or '未找到'}")
    ok = ok and bool(binary)

    rules_dir = Path(a.rules_dir)
    print(f"规则目录     : {rules_dir} {'存在' if rules_dir.is_dir() else '不存在'}")
    ok = ok and rules_dir.is_dir()

    rules, errors = _load(a)
    print(f"规则         : {len(rules)} 条，解析错误 {len(errors)} 个")
    for e in errors:
        print(f"  ✗ {e}")
    ok = ok and not errors

    conn = make_conn(_target_from_args(a), a.driver, a.mysql_binary, a.timeout)
    try:
        conn.connect()
        caps = probe(conn)
        print(f"连通性       : OK —— MySQL {caps.version_str} / user={caps.current_user}")
        print(f"能力位       : {sum(1 for v in caps.flags.values() if v)} 开 / {sum(1 for v in caps.flags.values() if not v)} 关")
        off = sorted(k for k, v in caps.flags.items() if not v)
        if off:
            print(f"              关闭的：{', '.join(off)}")
        if caps.schemas:
            shown = "、".join(caps.schemas[:8]) + ("…" if len(caps.schemas) > 8 else "")
            print(f"可见 schema  : {len(caps.schemas)} 个（{shown}）")
        print(f"会话前导     : {default_init_sql(caps) or '（无）'}")
    except QueryError as exc:
        print(f"连通性       : 失败 —— {exc}")
        ok = False
    return EXIT_OK if ok else EXIT_FAILURE


def cmd_check(a) -> int:
    rules, errors = _load(a)
    if errors:
        for e in errors:
            print(f"规则问题: {e}", file=sys.stderr)
    if not rules:
        print(f"规则目录 {a.rules_dir} 下没有可用规则", file=sys.stderr)
        return EXIT_FAILURE

    opt = RunOptions(
        only=a.only or None,
        skip=a.skip or None,
        dimensions=a.dimension or None,
        scopes=a.scope or None,
        tags=a.tag or None,
        min_severity=a.min_severity,
        init_sql=a.init_sql or None,
        no_init=a.no_init,
        ignore_min_uptime=a.ignore_min_uptime,
    )
    selected = select_rules(rules, opt)
    if not selected:
        print("过滤后没有剩余规则", file=sys.stderr)
        return EXIT_FAILURE

    conn = make_conn(_target_from_args(a), a.driver, a.mysql_binary, a.timeout)
    try:
        conn.connect()
        caps = probe(conn)
        outcomes = run_all(selected, conn, caps, opt)
    except QueryError as exc:
        print(f"连接失败：{exc}", file=sys.stderr)
        return EXIT_FAILURE

    now = datetime.now()
    meta = {
        "tool_version": __version__,
        "generated_at": now.strftime("%Y-%m-%d %H:%M:%S"),
        "generated_at_utc": now.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "host_label": _label(a, caps),
    }

    if a.output == "json":
        text = to_json(build_payload(caps, outcomes, meta))
    elif a.output == "markdown":
        text = to_markdown(caps, outcomes, meta)
    elif a.output == "sarif":
        text = to_sarif(caps, outcomes, meta)
    else:
        text = to_table(caps, outcomes, meta, verbose=a.verbose)

    if a.out_file:
        Path(a.out_file).write_text(text, encoding="utf-8")
        print(f"已写入 {a.out_file}")
    else:
        print(text)

    counts = summarize(outcomes)
    if counts.get(ERROR):
        return EXIT_CONTRACT
    if a.fail_on == "none":
        return EXIT_OK
    threshold = SEVERITY_ORDER[a.fail_on]
    worst = max((SEVERITY_ORDER.get(o.severity, 0) for o in outcomes if o.status == HIT), default=-1)
    return EXIT_FINDINGS if worst >= threshold else EXIT_OK


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    handler = {
        "check": cmd_check,
        "probe": cmd_probe,
        "list": cmd_list,
        "lint": cmd_lint,
        "doctor": cmd_doctor,
        "docs": cmd_docs,
    }[args.command]
    try:
        return handler(args)
    except KeyboardInterrupt:
        print("\n中断", file=sys.stderr)
        return EXIT_FAILURE


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
