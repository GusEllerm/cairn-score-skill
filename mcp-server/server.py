"""TrustGraph MCP server.

Phase 0 scaffolding: stdio hygiene shim + minimal hello tool. See MCP-PLAN.md
(rev 5) for the full design. Subsequent phases add read tools (score, retrieve,
rank, capabilities), get_rubric, and rate.
"""

# Stdio hygiene: third-party imports may print() during initialization,
# which would corrupt the JSON-RPC frames on stdout. Redirect stdout to stderr
# across the third-party import block, then restore so the SDK's stdio_server
# can own stdout. See MCP-PLAN.md "Stdio hygiene" for rationale.
import sys

_real_stdout = sys.stdout
sys.stdout = sys.stderr

from mcp.server.fastmcp import FastMCP  # noqa: E402

sys.stdout = _real_stdout

import logging  # noqa: E402

logging.basicConfig(stream=sys.stderr, level=logging.WARNING, force=True)


mcp = FastMCP("trustgraph")


@mcp.tool()
def hello(name: str = "World") -> str:
    """Phase 0 scaffolding tool. Verifies the server is wired up correctly."""
    return f"Hello, {name}!"


def main() -> None:
    """Entry point. Runs the server over stdio JSON-RPC."""
    mcp.run()


if __name__ == "__main__":
    main()
