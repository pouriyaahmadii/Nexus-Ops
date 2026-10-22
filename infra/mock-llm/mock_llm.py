#!/usr/bin/env python3
"""
Mock LLM Service for NexusOps Demo Mode
Returns deterministic responses based on input keywords.
Supports OpenAI-compatible /v1/chat/completions endpoint.
"""

import json
import os
import random
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

PORT = int(os.getenv("PORT", "8080"))
FAILURE_RATE = float(os.getenv("MOCK_FAILURE_RATE", "0.2"))  # 20% random failures

# Deterministic classifications based on keywords
CLASSIFICATIONS = {
    "refund": {"intent": "refund_request", "risk": "high", "reply": "I understand you'd like a refund. Let me check our policy and process this for you."},
    "billing": {"intent": "billing_inquiry", "risk": "medium", "reply": "I can help with your billing question. Could you provide your account number?"},
    "cancel": {"intent": "account_deletion", "risk": "high", "reply": "I'm sorry to hear you want to cancel. Let me assist with the account closure process."},
    "delete": {"intent": "data_deletion", "risk": "high", "reply": "I'll help you delete the requested data. Please confirm the specific records."},
    "legal": {"intent": "legal_request", "risk": "high", "reply": "Thank you for your legal inquiry. Our legal team will review and respond within 5 business days."},
    "complaint": {"intent": "complaint", "risk": "medium", "reply": "I apologize for the inconvenience. Let me escalate this to our support team."},
    "general": {"intent": "general_inquiry", "risk": "low", "reply": "Thank you for contacting us. How can I assist you today?"},
}

def classify(text: str) -> dict:
    """Deterministic classification based on keywords."""
    text_lower = text.lower()
    for keyword, result in CLASSIFICATIONS.items():
        if keyword in text_lower:
            return result
    return CLASSIFICATIONS["general"]

def count_tokens(text: str) -> int:
    """Rough token count: ~4 chars per token."""
    return max(1, len(text) // 4)

class MockHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status": "ok", "mode": "mock"}')
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        if self.path not in ("/v1/chat/completions", "/chat/completions"):
            self.send_response(404)
            self.end_headers()
            return

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8")
        
        try:
            request = json.loads(body)
        except json.JSONDecodeError:
            self.send_response(400)
            self.end_headers()
            return

        # Extract user message
        messages = request.get("messages", [])
        user_content = ""
        for msg in messages:
            if msg.get("role") == "user":
                user_content = msg.get("content", "")
                break

        # Deterministic seed from content for reproducible "random" failures
        seed = hash(user_content) % 10000
        random.seed(seed)
        
        # Inject occasional failures for demo
        should_fail = random.random() < FAILURE_RATE
        
        if should_fail:
            # Return 500 error
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            error_response = {
                "error": {
                    "message": "Mock LLM service error (injected for demo)",
                    "type": "server_error",
                    "code": "mock_failure"
                }
            }
            self.wfile.write(json.dumps(error_response).encode())
            random.seed()  # Reset seed
            return

        # Get classification
        classification = classify(user_content)
        
        # Simulate processing delay
        time.sleep(0.1)

        # Build response
        prompt_tokens = count_tokens(user_content)
        completion_text = classification["reply"]
        completion_tokens = count_tokens(completion_text)
        
        response = {
            "id": f"mock-{seed}",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": request.get("model", "mock-model"),
            "choices": [{
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": completion_text
                },
                "finish_reason": "stop"
            }],
            "usage": {
                "prompt_tokens": prompt_tokens,
                "completion_tokens": completion_tokens,
                "total_tokens": prompt_tokens + completion_tokens,
                "prompt_tokens_details": {
                    "cached_tokens": 0
                }
            },
            "mock_metadata": {
                "classification": classification,
                "seed": seed
            }
        }

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(response).encode())
        random.seed()  # Reset seed

    def log_message(self, format, *args):
        # Suppress default log messages
        pass

if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", PORT), MockHandler)
    print(f"Mock LLM server starting on port {PORT}...", flush=True)
    server.serve_forever()