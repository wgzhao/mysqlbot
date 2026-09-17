#!/usr/bin/env python3
"""信号登记表与版本推演的单元测试 —— 不需要数据库。

为什么值得单独测：这一层回答的是"这条规则在哪些版本上能跑"，
而它错了**不会报错**——只会让工具给出一个听上去很合理的答案：

  - `@since` 写得过宽 → 规则在旧版本上执行失败，
    报告里却是"环境限制"（这正是 2026-09-16 那批静默缺陷的形态）
  - 变体集合有覆盖空洞 → 某个版本区间里规则**静静地不跑**，
    而目录结构上看不出任何异常
  - `resolve_target` 把 "5.7" 当成 5.7.0 → 推演结果比现实悲观，
    也就是在说谎（一条真正能跑的规则被判成"不可用"）
  - 对账用字符串匹配跳过原因 → 假的「✓ 一致」

这些都是"结论错但过程无异常"的类别，端到端测试抓不到，只能靠单测钉住。

用法：python3 tests/test_signals.py
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from mbot import signals as sg  # noqa: E402
from mbot.conn import QueryError  # noqa: E402
from mbot.probe import attest_variable_signals  # noqa: E402
from mbot.rule import Rule, parse_rule_text, parse_version  # noqa: E402

FAILED = 0


def check(name: str, got, want) -> None:
    global FAILED
    if got == want:
        print(f"  ✓ {name}")
    else:
        FAILED += 1
        print(f"  ✗ {name}\n      期望 {want!r}\n      实际 {got!r}")


def mk(rid: str, sql: str, since: str = "5.7", removed_in: str = "", variant_of: str = "") -> Rule:
    return Rule(
        id=rid, path=Path(f"{rid}.sql"), sql=sql, since=since, removed_in=removed_in,
        variant_of=variant_of, title="t", remediation="r", caveats="c",
    )


# ===========================================================================
print("\n── resolve_target：部分版本号要补成该线的最新补丁，不是 .0 ──")
check('"5.7" -> 5.7.999（不是 5.7.0）', sg.resolve_target("5.7"), (5, 7, 999))
check('"9" -> 9.999.999', sg.resolve_target("9"), (9, 999, 999))
check('"8.0.43" 原样保留', sg.resolve_target("8.0.43"), (8, 0, 43))
check('"5.7.44-48-log" 取前三段', sg.resolve_target("5.7.44"), (5, 7, 44))
# 这一条是核心：@since 5.7.3 的规则在 --at 5.7 上必须判为「能跑」，
# 否则工具会宣称一条在 5.7.44 上跑得好好的规则"在 5.7 上不可用"。
check(
    "@since 5.7.3 的规则在 5.7 上可跑",
    mk("r", "SELECT 1 AS severity FROM t", since="5.7.3").supports_version(sg.resolve_target("5.7")),
    True,
)

# ===========================================================================
print("\n── scan：只认 SQL 正文，注释里提到不算引用 ──")
# 真实场景：规则的 @caveats 里解释"为什么不用 QUERY_SAMPLE_TEXT"，
# 若把注释也算引用，会得出"这规则依赖 8.0.22"的错误结论。
text = """-- @id: sample
-- @title: t
-- @severity: info
-- @caveats: 样本列取 DIGEST_TEXT 而非 QUERY_SAMPLE_TEXT，后者是 8.0.22 才加的
SELECT 'info' AS severity, d.DIGEST_TEXT AS q
FROM performance_schema.events_statements_summary_by_digest d
"""
r = parse_rule_text(text, Path("sample.sql"))
names = [u.signal.name for u in sg.scan(r)]
check("注释里的 QUERY_SAMPLE_TEXT 不被计入", "events_statements_summary_by_digest.QUERY_SAMPLE_TEXT" in names, False)
check("正文里的 DIGEST_TEXT 被计入", "events_statements_summary_by_digest.DIGEST_TEXT" in names, True)

# ===========================================================================
print("\n── scan：硬引用 vs 软查表 —— 同一信号两种用法，后果不同 ──")
hard = mk("h", "SELECT 'warn' AS severity, @@binlog_expire_logs_auto_purge AS v FROM DUAL")
soft = mk("s", "SELECT 'warn' AS severity FROM performance_schema.global_variables "
               "WHERE VARIABLE_NAME = 'binlog_expire_logs_auto_purge'")
u_hard = [u for u in sg.scan(hard) if u.signal.name == "binlog_expire_logs_auto_purge"]
u_soft = [u for u in sg.scan(soft) if u.signal.name == "binlog_expire_logs_auto_purge"]
check("@@var 判为硬引用", (u_hard[0].hard, u_hard[0].soft) if u_hard else None, (True, False))
check("'var' 字面量判为软引用", (u_soft[0].hard, u_soft[0].soft) if u_soft else None, (False, True))
check("硬引用的最低版本 = 8.0.29", sg.min_version(sg.scan(hard)), "8.0.29")
# 软引用的变量本身不抬高最低版本（8.0.29 被忽略），但规则还要读
# performance_schema.global_variables 这张表，表引用是硬引用 → 5.7。
# 这正是"软查表"的价值：变量缺失不会让整条规则失效，只让那一行读不到。
check("软引用不因变量抬高版本（只剩表本身的 5.7）", sg.min_version(sg.scan(soft)), "5.7")
# 软引用的规则在 5.7 上不应被报为版本风险
check("软引用在 5.7 上无可执行风险", sg.verdict_for(soft, "5.7").status, sg.RUNNABLE)

# ===========================================================================
print("\n── check_rule：声明过宽（跨次版本 = 错误；同线补丁级 = 提示）──")
cross = mk("c", "SELECT 'info' AS severity, d.QUERY_SAMPLE_TEXT AS s "
                "FROM performance_schema.events_statements_summary_by_digest d", since="5.7")
e, h = sg.check_rule(cross)
check("跨次版本差异判为错误", len(e), 1)
check("错误里点出了 offender", "QUERY_SAMPLE_TEXT" in (e[0] if e else ""), True)

patch = mk("p", "SELECT 'info' AS severity, COUNT(*) AS n "
                "FROM performance_schema.metadata_locks", since="5.7")
e, h = sg.check_rule(patch)
check("补丁级差异不判错", len(e), 0)
check("补丁级差异给提示", len(h), 1)
check("提示里建议的精确版本", "5.7.3" in (h[0] if h else ""), True)

# ===========================================================================
print("\n── check_rule：硬引用有上界的信号，必须声明 @removed_in ──")
no_upper = mk("n", "SELECT 'warn' AS severity, @@expire_logs_days AS v FROM DUAL", since="5.7")
e, _ = sg.check_rule(no_upper)
check("缺 @removed_in 判为错误", len(e), 1)
check("错误提到移除版本", "8.4" in (e[0] if e else ""), True)

equal_bound = mk("q", "SELECT 'warn' AS severity, @@expire_logs_days AS v FROM DUAL",
                 since="5.7", removed_in="8.4")
e, _ = sg.check_rule(equal_bound)
check("边界相等（8.4 vs 8.4）不算过宽", len(e), 0)

too_late = mk("l", "SELECT 'warn' AS severity, @@expire_logs_days AS v FROM DUAL",
              since="5.7", removed_in="9.7")
e, _ = sg.check_rule(too_late)
check("上界晚于信号移除判为错误", len(e), 1)

# ===========================================================================
print("\n── variant_base / variant_gaps：变体覆盖不能有空洞 ──")
check("显式 @variant_of 优先", sg.variant_base(mk("a_57", "SELECT 1", variant_of="a")), "a")
check("无声明时从 _57 后缀推断", sg.variant_base(mk("a_57", "SELECT 1")), "a")
check("无后缀则用原名", sg.variant_base(mk("a", "SELECT 1")), "a")

# 无缝覆盖：5.7~8.0 与 8.0~∞
good = [mk("g", "SELECT 1", since="8.0"),
        mk("g_57", "SELECT 1", since="5.7", removed_in="8.0", variant_of="g")]
check("无缝覆盖无空洞", sg.variant_gaps(good), [])

# 空洞：8.0~8.4 之间没人管
gap = [mk("h", "SELECT 1", since="8.4"),
       mk("h_57", "SELECT 1", since="5.7", removed_in="8.0", variant_of="h")]
check("检出 8.0~8.4 覆盖空洞", len(sg.variant_gaps(gap)), 1)
check("空洞描述含区间", "8.0" in (sg.variant_gaps(gap)[0] if sg.variant_gaps(gap) else ""), True)

# 没有收口到无穷：两个变体都设了上界
unclosed = [mk("k", "SELECT 1", since="8.0", removed_in="8.4"),
            mk("k_57", "SELECT 1", since="5.7", removed_in="8.0", variant_of="k")]
check("未覆盖到无穷也报出", len(sg.variant_gaps(unclosed)), 1)

# ===========================================================================
print("\n── verdict_for：三态判定 ──")
check("区间外 -> 门禁跳过", sg.verdict_for(mk("v", "SELECT 1", since="8.0"), "5.7").status, sg.GATED)
check("已移除 -> 门禁跳过",
      sg.verdict_for(mk("v", "SELECT 1", since="5.7", removed_in="8.0"), "8.0").status, sg.GATED)
check("区间内 -> 可运行", sg.verdict_for(mk("v", "SELECT 1", since="8.0"), "9.7").status, sg.RUNNABLE)
sample_col = ("SELECT 'info' AS severity, d.QUERY_SAMPLE_TEXT AS s "
              "FROM performance_schema.events_statements_summary_by_digest d")
# 同一条规则，两个目标版本，结论不同 —— 这就是"版本区间"该做的事：
# 声明 @since 8.0，在 5.7 上被门禁挡住（不是风险，是设计如此）；
# 在 8.0.43 上 QUERY_SAMPLE_TEXT 已存在（8.0.22 引入），所以能跑。
check("声明的区间外 -> 门禁跳过，不是风险", sg.verdict_for(mk("v", sample_col, since="8.0"), "5.7").status, sg.GATED)
check("同规则在 8.0.43 上可跑", sg.verdict_for(mk("v", sample_col, since="8.0"), "8.0.43").status, sg.RUNNABLE)

# 版本风险：声明的区间**包含**目标版本，但正文引用的信号在那里已不存在。
# 这正是 @removed_in 缺失时的形态——登记表让它在离线阶段就暴露出来。
risk = mk("v", "SELECT 'warn' AS severity, @@expire_logs_days AS v FROM DUAL", since="8.0")
check("区间内但信号已移除 -> 版本风险", sg.verdict_for(risk, "9.7").status, sg.AT_RISK)
check("风险项带 offender", sg.verdict_for(risk, "9.7").offending, ["variable:expire_logs_days"])
check("同一规则在 8.0.43 上无风险", sg.verdict_for(risk, "8.0.43").status, sg.RUNNABLE)

# ===========================================================================
print("\n── 登记表自检：区间必须自洽 ──")
bad_range = [s.name for s in sg.SIGNALS.values()
             if s.since_tuple and s.removed_tuple and not (s.removed_tuple > s.since_tuple)]
check("不存在 since >= removed_in 的信号", bad_range, [])
bad_dup = len(sg.SIGNALS) != len({s.name for s in sg.SIGNALS.values()})
check("信号名不重复", bad_dup, False)
# removed_in 与 since 同段（如 8.0/8.0）会让区间为空，是个容易写错的地方
empty_range = [s.name for s in sg.SIGNALS.values()
               if s.since_tuple and s.removed_tuple and sg._norm(s.since_tuple) == sg._norm(s.removed_tuple)]
check("不存在空区间信号", empty_range, [])

# ===========================================================================
print("\n── 变量信号 attestation：登记表 vs 真实实例 ──")
# 这一层的意义：**软查表**缺变量是哑的 —— MAX(CASE WHEN VARIABLE_NAME='x')
# 返回 NULL，规则既不报错也不跳过，可能静静地给出错误结论。硬引用失败会报
# 1193，由 error 计数兜住；软引用只能靠"直接问实例有没有这个变量"来核对。

# 9.7.2 上登记表该给出的预测（与本次实测一致）：
for _gone in ("expire_logs_days", "innodb_log_file_size", "innodb_log_files_in_group"):
    check(f"{_gone} 在 9.7.2 上预测为不存在",
          sg.SIGNALS[_gone].available_in((9, 7, 2)), False)
check("binlog_expire_logs_seconds 在 9.7.2 上预测为存在",
      sg.SIGNALS["binlog_expire_logs_seconds"].available_in((9, 7, 2)), True)


class _FakeResult:
    def __init__(self, rows):
        self.rows = rows


class _FakeConn:
    """只实现 attest_variable_signals 用到的那一点接口。"""

    def __init__(self, present, fail=False):
        self.present = present
        self.fail = fail

    def query(self, sql):
        if self.fail:
            raise QueryError("模拟：读不到 performance_schema.global_variables")
        return _FakeResult([[n] for n in self.present])


_var_sigs = [s for s in sg._ORDER if s.kind == "variable"]
# 构造一份"与 9.7.2 登记表完全一致"的实例变量集
_ok_present = [s.name for s in _var_sigs if s.available_in((9, 7, 2))]

n_reg, n_pres, bad, skip = attest_variable_signals(_FakeConn(_ok_present), (9, 7, 2))
check("实例与登记表一致时 -> 0 条不一致", bad, [])
check("登记数 = 全部变量信号数", n_reg, len(_var_sigs))
check("存在数 = 预测为存在的个数", n_pres, len(_ok_present))
check("一致时不产生跳过原因", skip, "")

# 反向：同一个实例，按**错误**的版本判定 → 必须报出来（这才是它的用途）
_, _, bad57, _ = attest_variable_signals(_FakeConn(_ok_present), (5, 7, 44))
check("按 5.7.44 误判时能抓到不一致", len(bad57) > 0, True)
check("方向一：登记为区间内、实例却没有 -> 报出",
      any("expire_logs_days" in b and "却不存在" in b for b in bad57), True)
check("方向二：登记为区间外、实例却仍有 -> 报出",
      any("binlog_expire_logs_seconds" in b and "却仍存在" in b for b in bad57), True)

# 查询失败必须**降级**（返回原因），不能抛出去把 doctor 打挂 —— 铁律 3
_, _, bad_fail, skip_fail = attest_variable_signals(_FakeConn([], fail=True), (9, 7, 2))
check("读不到变量表时 -> 不报不一致，而是给跳过原因", bad_fail, [])
check("读不到变量表时 -> 跳过原因非空", bool(skip_fail), True)

print()
if FAILED:
    print(f"✗ {FAILED} 项失败")
    sys.exit(1)
print("✓ 全部通过")
