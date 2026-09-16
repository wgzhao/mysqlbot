"""连接层：把「执行一条只读 SQL」抽成一个动作，屏蔽底层驱动差异。

两个后端：
  cli     —— 调用本机 mysql 客户端（默认）。零依赖，天然支持 socket、SSL、
             ~/.my.cnf、login-path、SSH 隧道，任何装了客户端的机器都能跑。
  pymysql —— Python 驱动。类型与 NULL 更精确，适合脚本化集成。

只读保证在角色层（见 sql/readonly_account.sql），这一层不提供任何写路径：
没有任何 API 允许调用方提交 DML/DDL，只暴露 query()。
"""

from __future__ import annotations

import re
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

# ---------------------------------------------------------------- 错误分类

# 这些错误说明「当前账号看不到/没有这个能力」，属于可降级，不是故障
_CAPABILITY_CODES = {
    1044,  # Access denied for user ... to database
    1045,  # Access denied for user (auth)
    1142,  # SELECT command denied
    1143,  # INSERT command denied (理论上不该出现，出现说明账号配错了)
    1227,  # Access denied; you need (at least one of) the PROCESS privilege(s)
    1146,  # Table doesn't exist  -> 版本差异导致视图不存在
    1109,  # Unknown table
    1054,  # Unknown column     -> 版本差异导致列不存在
    1193,  # Unknown system variable -> 变量在目标版本已移除/尚未引入
    1231,  # Variable can't be set -> 版本差异
    1305,  # PROCEDURE/FUNCTION does not exist
    3167,  # information_schema 相关
}

_PERMISSION_CODES = {1044, 1045, 1142, 1143, 1227}
_SCHEMA_CODES = {1146, 1109, 1054, 1193, 1231, 1305, 3167}


class QueryError(Exception):
    """一条 SQL 执行失败。kind 决定上层是降级还是报错。"""

    def __init__(self, message: str, code: int | None = None, kind: str = "other"):
        super().__init__(message)
        self.code = code
        self.kind = kind  # permission | missing_object | syntax | conn | other

    @property
    def degradable(self) -> bool:
        return self.kind in ("permission", "missing_object")


def _classify(code: int | None) -> str:
    if code is None:
        return "other"
    if code in _PERMISSION_CODES:
        return "permission"
    if code in _SCHEMA_CODES:
        return "missing_object"
    if code == 1064:
        return "syntax"
    return "other"


# ---------------------------------------------------------------- 结果容器


@dataclass
class Result:
    columns: list[str] = field(default_factory=list)
    rows: list[list] = field(default_factory=list)

    def __len__(self) -> int:
        return len(self.rows)

    def dicts(self) -> list[dict]:
        return [dict(zip(self.columns, r)) for r in self.rows]

    def scalar(self):
        if self.rows and self.rows[0]:
            return self.rows[0][0]
        return None


# ---------------------------------------------------------------- DSN 解析


@dataclass
class Target:
    host: str = ""
    port: int = 0
    user: str = ""
    password: str = ""
    socket: str = ""
    defaults_file: str = ""
    extra_args: list[str] = field(default_factory=list)

    @classmethod
    def from_dsn(cls, dsn: str) -> "Target":
        """支持 mysql://user:pass@host:port/ 与 unix socket 形式。"""
        t = cls()
        if not dsn:
            return t
        m = re.match(r"^mysql(\+\w+)?://((?P<u>[^:@/]*)(:(?P<p>[^@/]*))?@)?(?P<h>[^/?]+)?(/.*)?$", dsn)
        if not m:
            # 退化处理：当成 socket 路径
            t.socket = dsn
            return t
        if m.group("u"):
            from urllib.parse import unquote

            t.user = unquote(m.group("u"))
            t.password = unquote(m.group("p") or "")
        host = m.group("h") or ""
        if host.startswith("unix:") or host.endswith(".sock"):
            t.socket = host[5:] if host.startswith("unix:") else host
        elif ":" in host:
            h, _, p = host.rpartition(":")
            t.host, t.port = h, int(p)
        else:
            t.host = host
        return t


# ---------------------------------------------------------------- CLI 后端

_BATCH_ESCAPES = {"t": "\t", "n": "\n", "0": "\0", "\\": "\\", "r": "\r"}


def _unescape_batch(text: str) -> str:
    if "\\" not in text:
        return text
    out: list[str] = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if ch == "\\" and i + 1 < n:
            nxt = text[i + 1]
            if nxt in _BATCH_ESCAPES:
                out.append(_BATCH_ESCAPES[nxt])
                i += 2
                continue
        out.append(ch)
        i += 1
    return "".join(out)


class CliConn:
    """通过 mysql 客户端执行查询。

    --batch 模式下 mysql 会把 \t \n \\ \0 转义成字面量，所以字段可以安全地
    以 \t 切分。代价是真正的 NULL 和字符串 'NULL' 都打印为 NULL —— 规则里
    不要依赖这一区分（本工具输出的列都是标识符/数值/布尔判断，不涉及）。
    """

    def __init__(self, target: Target, binary: str = "mysql", timeout: int = 60):
        self.target = target
        self.binary = binary or "mysql"
        self.timeout = timeout
        self.server: dict = {}

    # -- 构造命令行 ---------------------------------------------------
    def _base_cmd(self) -> list[str]:
        t = self.target
        cmd = [self.binary, "--batch", "--connect-timeout=10"]
        if t.defaults_file:
            cmd.append(f"--defaults-file={t.defaults_file}")
        if t.socket:
            cmd.append(f"--socket={t.socket}")
        if t.host:
            cmd.append(f"--host={t.host}")
        if t.port:
            cmd.append(f"--port={t.port}")
        if t.user:
            cmd.append(f"--user={t.user}")
        if t.password:
            cmd.append(f"--password={t.password}")
        cmd.extend(t.extra_args)
        return cmd

    # -- 连通性 -------------------------------------------------------
    def connect(self) -> None:
        r = self.query(
            "SELECT VERSION() AS version,"
            " @@version_comment AS version_comment,"
            " @@innodb_version AS innodb_version,"
            " CURRENT_USER() AS connected_as"
        )
        if not r.rows:
            raise QueryError("连接成功但拿不到版本信息", kind="conn")
        row = r.dicts()[0]
        self.server = {
            "version": row.get("version") or "",
            "version_comment": row.get("version_comment") or "",
            "innodb_version": row.get("innodb_version") or "",
            "current_user": row.get("connected_as") or "",
        }

    # -- 查询 ---------------------------------------------------------
    def query(self, sql: str) -> Result:
        cmd = self._base_cmd()
        try:
            proc = subprocess.run(
                cmd,
                input=sql,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=self.timeout,
            )
        except FileNotFoundError as exc:
            raise QueryError(f"找不到 mysql 客户端 {self.binary!r}", kind="conn") from exc
        except subprocess.TimeoutExpired as exc:
            raise QueryError(f"查询超时（>{self.timeout}s）", kind="conn") from exc

        if proc.returncode != 0:
            raise _error_from_stderr(proc.stderr or "")

        return _parse_batch_output(proc.stdout or "")

    def close(self) -> None:  # 无状态，留作接口对称
        return None


def _error_from_stderr(stderr: str) -> QueryError:
    msg = stderr.strip() or "mysql 客户端返回非零退出码"
    m = re.search(r"ERROR\s+(\d+)\s*\(([^)]*)\)", msg)
    code = int(m.group(1)) if m else None
    first = next((ln for ln in msg.splitlines() if "ERROR" in ln), msg.splitlines()[0] if msg else msg)
    first = re.sub(r"^ERROR\s+\d+\s*\([^)]*\)\s*(at line \d+:?\s*)?", "", first).strip()
    if code is None and ("Can't connect" in msg or "Lost connection" in msg or "Connection refused" in msg):
        return QueryError(msg, code=None, kind="conn")
    return QueryError(first, code=code, kind=_classify(code))


def _parse_batch_output(text: str) -> Result:
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    if not lines:
        return Result()
    columns = [_unescape_batch(c) for c in lines[0].split("\t")]
    rows: list[list] = []
    for line in lines[1:]:
        if line == "":
            continue
        cells = []
        for cell in line.split("\t"):
            if cell == "NULL":
                cells.append(None)
            else:
                cells.append(_unescape_batch(cell))
        rows.append(cells)
    return Result(columns=columns, rows=rows)


# ---------------------------------------------------------------- PyMySQL 后端


class PyMyConn:
    def __init__(self, target: Target, timeout: int = 60):
        try:
            import pymysql  # noqa: F401
        except ImportError as exc:  # pragma: no cover
            raise QueryError("未安装 PyMySQL（pip install pymysql）", kind="conn") from exc
        self.target = target
        self.timeout = timeout
        self.server: dict = {}

    def _connect(self):
        import pymysql

        t = self.target
        kwargs: dict = {
            "user": t.user or None,
            "password": t.password or None,
            "charset": "utf8mb4",
            "cursorclass": pymysql.cursors.Cursor,
            "read_timeout": self.timeout,
            "connect_timeout": 10,
        }
        if t.socket:
            kwargs["unix_socket"] = t.socket
        if t.host:
            kwargs["host"] = t.host
        if t.port:
            kwargs["port"] = t.port
        return pymysql.connect(**kwargs)

    def connect(self) -> None:
        try:
            with self._connect() as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        "SELECT VERSION() AS version, @@version_comment AS version_comment,"
                        " @@innodb_version AS innodb_version, CURRENT_USER() AS connected_as"
                    )
                    cols = [d[0] for d in cur.description]
                    row = dict(zip(cols, cur.fetchone()))
        except Exception as exc:
            raise QueryError(f"连接失败: {exc}", kind="conn") from exc
        self.server = {k: (v or "") for k, v in row.items()}

    def query(self, sql: str) -> Result:
        try:
            with self._connect() as conn:
                with conn.cursor() as cur:
                    cur.execute(sql)
                    columns = [d[0] for d in (cur.description or [])]
                    rows = [list(r) for r in (cur.fetchall() or [])]
        except Exception as exc:
            code = exc.args[0] if getattr(exc, "args", None) else None
            raise QueryError(str(exc), code=code, kind=_classify(code)) from exc
        return Result(columns=columns, rows=rows)

    def close(self) -> None:
        return None


# ---------------------------------------------------------------- 工厂


def find_cli() -> str | None:
    """按常见位置找 mysql 客户端。"""
    found = shutil.which("mysql")
    if found:
        return found
    candidates = [
        "/opt/homebrew/opt/mysql-client/bin/mysql",
        "/usr/local/bin/mysql",
        "/usr/bin/mysql",
    ]
    candidates += [str(p) for p in sorted(Path("/opt/homebrew/Cellar").glob("mysql*/**/bin/mysql"))]
    candidates += [str(p) for p in sorted(Path("/opt/homebrew/Cellar").glob("mysql-client*/**/bin/mysql"))]
    for c in candidates:
        if Path(c).is_file():
            return c
    return None


def make_conn(target: Target, driver: str = "auto", binary: str = "", timeout: int = 60):
    """driver: auto | cli | pymysql。auto 优先 cli（零依赖、通用），不可用时回退 pymysql。"""
    if driver in ("auto", "cli"):
        exe = binary or find_cli()
        if exe or driver == "cli":
            return CliConn(target, binary=exe or "mysql", timeout=timeout)
    if driver in ("auto", "pymysql"):
        return PyMyConn(target, timeout=timeout)
    raise ValueError(f"未知驱动: {driver}")
