#!/usr/bin/env python3
"""授权解析的单元测试 —— 不需要数据库，纯字符串。

为什么值得单独测：能力位是靠解析 `SHOW GRANTS` 得到的，解析错了不会报错，
只会让工具**声称**自己有能力。2026-09-16 在 MySQL 8.0.43 上就踩到过：
一个只被授了 ``GRANT ALL PRIVILEGES ON `biz_db`.*`` 的业务账号，
因为用了 `"ALL PRIVILEGES" in 整段文本` 这种子串判断，被误判成拥有全局
ALL PRIVILEGES，于是 process / replication / schema_select / super 全为真，
规则一路跑到底才在执行期撞 1142，报告里变成一堆"执行被拒"的跳过。

用法：python3 tests/test_grants.py
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from mbot.probe import (  # noqa: E402
    Capabilities,
    _apply_grants,
    _note_schema_coverage,
    _parse_grants,
)

FAILED = 0


def check(name: str, got, want) -> None:
    global FAILED
    if got == want:
        print(f"  ✓ {name}")
    else:
        FAILED += 1
        print(f"  ✗ {name}\n      期望 {want!r}\n      实际 {got!r}")


def caps_from(grants: list[str]) -> Capabilities:
    """模拟 probe() 的授权那一段：解析授权 + 生成覆盖范围说明。

    真实 probe() 还会用 information_schema.TABLES 覆盖 caps.schemas（更权威），
    这里测的是纯函数部分，不连库。
    """
    c = Capabilities()
    c.grants = grants
    _apply_grants(c)
    _note_schema_coverage(c)
    return c


# ---------------------------------------------------------------- 用例

# 真实抓取：<实例 B> 的 biz_user@%（业务账号，只有 PROCESS 是全局的）
OPERATOR_GRANTS = [
    "GRANT CREATE, PROCESS ON *.* TO `biz_user`@`%`",
    "GRANT ALL PRIVILEGES ON `biz_db`.* TO `biz_user`@`%`",
    "GRANT ALL PRIVILEGES ON `scrm_db`.* TO `biz_user`@`%`",
    "GRANT ALL PRIVILEGES ON `chat_db`.* TO `biz_user`@`%`",
    "GRANT SELECT ON `report_db`.* TO `biz_user`@`%`",
]


def test_biz_user_account() -> None:
    print("【业务账号】CREATE, PROCESS ON *.* + 若干库的 ALL/ SELECT")
    c = caps_from(OPERATOR_GRANTS)
    check("process", c.flags["process"], True)
    check("replication 未授权", c.flags["replication"], False)
    check("super 未授权", c.flags["super"], False)
    check("global_select 未授权", c.flags["global_select"], False)
    check("schema_select 为真（有库可读）", c.flags["schema_select"], True)
    check("visible_schemas", c.schemas, ["biz_db", "scrm_db", "report_db", "chat_db"])
    check("给出覆盖范围说明", bool([n for n in c.notes if "只对 4 个 schema" in n]), True)


def test_global_all_privileges() -> None:
    print("\n【超级账号】ALL PRIVILEGES ON *.*")
    c = caps_from([
        "GRANT ALL PRIVILEGES ON *.* TO `root`@`%` WITH GRANT OPTION",
        "GRANT SYSTEM_VARIABLES_ADMIN,SESSION_VARIABLES_ADMIN ON *.* TO `root`@`%` WITH GRANT OPTION",
    ])
    check("process", c.flags["process"], True)
    check("replication", c.flags["replication"], True)
    check("super", c.flags["super"], True)
    check("global_select", c.flags["global_select"], True)
    check("schema_select", c.flags["schema_select"], True)
    # 全局 ALL PRIVILEGES 不展开成具体权限名 -> 不需要逐个库列举
    check("visible_schemas 为空（由 ALL 覆盖，无需列举）", c.schemas, [])


def test_minimal_readonly() -> None:
    print("\n【A 档只读账号】只有统计侧权限，不碰业务数据")
    c = caps_from([
        "GRANT PROCESS, REPLICATION CLIENT ON *.* TO `mbot_reader`@`%`",
        "GRANT SELECT ON `sys`.* TO `mbot_reader`@`%`",
        "GRANT SELECT ON `performance_schema`.* TO `mbot_reader`@`%`",
    ])
    check("process", c.flags["process"], True)
    check("replication", c.flags["replication"], True)
    check("global_select 仍为假", c.flags["global_select"], False)
    # performance_schema / sys 不算业务库：它们在 information_schema 里可见，
    # 但规则本身会排除这四个系统库，这里不做特殊过滤，如实列出即可。
    check("visible_schemas", c.schemas, ["performance_schema", "sys"])
    check("schema_select 为真", c.flags["schema_select"], True)


def test_usage_only() -> None:
    print("\n【空账号】只有 USAGE")
    c = caps_from(["GRANT USAGE ON *.* TO `nobody`@`%`"])
    for f in ("process", "replication", "super", "global_select", "schema_select"):
        check(f"{f} 为假", c.flags[f], False)
    check("visible_schemas", c.schemas, [])


def test_mariadb_priv_names() -> None:
    print("\n【MariaDB】10.5.9+ 拆成 BINLOG MONITOR / SLAVE MONITOR")
    c = caps_from([
        "GRANT SELECT, PROCESS, BINLOG MONITOR ON *.* TO `mbot_reader`@`%`",
        "GRANT SLAVE MONITOR ON *.* TO `mbot_reader`@`%`",
    ])
    check("replication", c.flags["replication"], True)


def test_table_level_grant_ignored() -> None:
    print("\n【表级授权】不构成 schema 级可见性")
    privs, schemas = _parse_grants(["GRANT SELECT ON `db1`.`t1` TO `u`@`%`"])
    check("全局权限", sorted(privs), [])
    check("schema 权限", schemas, {})


def test_privilege_suffix_and_case() -> None:
    print("\n【列级授权与大小写】")
    privs, schemas = _parse_grants(["grant select (id, name) on `Db1`.* to `u`@`%`"])
    check("列级后缀被剥掉", sorted(privs), [])
    check("schema 名保留原样", list(schemas), ["Db1"])
    check("SELECT 被识别", sorted(schemas["Db1"]), ["SELECT"])


def main() -> int:
    test_biz_user_account()
    test_global_all_privileges()
    test_minimal_readonly()
    test_usage_only()
    test_mariadb_priv_names()
    test_table_level_grant_ignored()
    test_privilege_suffix_and_case()
    print()
    if FAILED:
        print(f"✗ {FAILED} 个断言失败")
        return 1
    print("✓ 授权解析全部通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
