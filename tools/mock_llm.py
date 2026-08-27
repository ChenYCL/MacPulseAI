#!/usr/bin/env python3
"""本地 mock LLM 服务器：同时实现 OpenAI /chat/completions 与 Anthropic /v1/messages。

用途：在无真实 API Key 的情况下验证 MacPulse 的完整 HTTP 链路。
请求体会追加记录到 /tmp/macpulse_mock_llm.log。
用法：python3 tools/mock_llm.py [port]
"""
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG_PATH = "/tmp/macpulse_mock_llm.log"

MOCK_MD = """## 总体判断

已收到 **{N} 个进程** 的快照（mock 服务返回）。系统处于高负载状态，多个进程占用接近或超过单核满载。

## 进程解读

- **node**：JavaScript/Node.js 运行时。多个 node 同时打满 CPU 通常是失控的开发服务器、构建任务或死循环脚本。
- **kernel_task**：系统核心进程，负责硬件调度与温控，出现高占用往往是替其他组件"挡枪"，🔴 不要终止。
- **WindowServer**：macOS 图形合成服务，终止会导致注销，🔴 高危。

## 建议

1. 🟢 逐个终止多余的 node 进程（先确认没有未保存的工作）。
2. 🟡 如 node 属于你正在调试的会话，建议在终端正常 Ctrl-C 而不是强制退出。
3. 🔴 不要终止 kernel_task / WindowServer 等系统进程。

> 本结果来自本地 mock 服务，仅用于验证链路，非真实模型输出。"""


def count_processes(payload: dict) -> int:
    try:
        if "messages" in payload:
            content = payload["messages"][-1]["content"]
        else:
            content = ""
        return len(re.findall(r'"pid"', content)) or content.count('"pid"')
    except Exception:
        return 0


class Handler(BaseHTTPRequestHandler):
    def _log(self, body: bytes) -> None:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write("=== %s ===\n%s\n---\n" % (self.path, body.decode("utf-8", "replace")))

    def _reply(self, obj: dict) -> None:
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        self._log(body)
        try:
            payload = json.loads(body)
        except Exception:
            payload = {}
        n = count_processes(payload)
        text = MOCK_MD.replace("{N}", str(max(n, 1)))

        if self.path.endswith("/chat/completions"):
            self._reply({
                "id": "mock-chat-1",
                "object": "chat.completion",
                "model": payload.get("model", "mock"),
                "choices": [{
                    "index": 0,
                    "finish_reason": "stop",
                    "message": {"role": "assistant", "content": text},
                }],
            })
        elif self.path.endswith("/v1/messages") or self.path.endswith("/messages"):
            self._reply({
                "id": "msg_mock_1",
                "type": "message",
                "role": "assistant",
                "model": payload.get("model", "mock"),
                "content": [{"type": "text", "text": text}],
                "stop_reason": "end_turn",
            })
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
    server = HTTPServer(("127.0.0.1", port), Handler)
    print(f"mock LLM listening on http://127.0.0.1:{port} (log: {LOG_PATH})")
    server.serve_forever()
