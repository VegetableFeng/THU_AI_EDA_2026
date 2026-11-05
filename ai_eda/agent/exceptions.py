"""Agent 流程共享的异常类型（独立模块，避免 runs <-> subagents 循环导入）。"""


class AgentCancelled(RuntimeError):
    """用户取消了 Agent 运行。"""
