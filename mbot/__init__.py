"""mysqlbot —— 只读、确定性、无 agent 的 MySQL 体检探针。

设计照搬 pgbot 的五条公理：
  1. 只读是角色而不是开关 —— 能力由授权决定，脚本不提供写路径
  2. 发现全部确定性算出来，LLM 只负责解释
  3. 降级而不报错 —— 能力缺失记 unavailable，不中断
  4. 每条结论都带 exactness（exact/cumulative/sampled/scraped/catalog）
  5. 输出是契约，不是日志
"""

__version__ = "0.1.0"
