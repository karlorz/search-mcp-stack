#!/usr/bin/env python3
"""Repeatable, redacted discovery and real-SDK MCP acceptance probe.

Run with the GrokSearch virtual environment. Credentials come only from the
named process environment variable, never arguments or a configuration rewrite.
"""

import argparse
import asyncio
import json
import os
import re
import urllib.error
import urllib.request


def fetch_json(url):
    with urllib.request.urlopen(url, timeout=10) as response:
        return json.loads(response.read(65536))


async def authenticated_probe(endpoint, token):
    from fastmcp import Client
    from fastmcp.client.transports import StreamableHttpTransport

    async with Client(StreamableHttpTransport(endpoint, headers={"Authorization": f"Bearer {token}"}), timeout=15) as client:
        tools = await client.list_tools()
        names = {tool.name for tool in tools}
        assert {"web_search", "web_fetch", "web_map", "get_sources"} <= names
        await client.call_tool("get_sources", {"session_id": "authorization-compatibility-probe"})
        return {"initialize": "passed", "tools_list": "passed", "tool_call": "passed", "tool_count": len(names)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--origin", default="https://search.karldigi.dev")
    parser.add_argument("--token-env", default="GROK_SEARCH_MCP_TOKEN")
    parser.add_argument("--require-auth", action="store_true")
    parser.add_argument("--require-cimd", action="store_true")
    args = parser.parse_args()
    origin = args.origin.rstrip("/")
    endpoint = origin + "/mcp"
    try:
        resource = fetch_json(origin + "/.well-known/oauth-protected-resource/mcp")
        root = fetch_json(origin + "/.well-known/oauth-protected-resource")
        authorization = fetch_json(origin + "/.well-known/oauth-authorization-server")
        assert resource["resource"] == endpoint == root["resource"]
        assert resource["authorization_servers"] == [origin]
        assert authorization["issuer"] == origin
        assert "S256" in authorization["code_challenge_methods_supported"]
        for name in ("authorization_endpoint", "token_endpoint", "registration_endpoint"):
            assert authorization[name].startswith(origin + "/")
        if args.require_cimd:
            assert authorization.get("client_id_metadata_document_supported") is True
        request = urllib.request.Request(endpoint, data=b'{"jsonrpc":"2.0","id":1,"method":"tools/list"}',
            headers={"Content-Type": "application/json", "Accept": "application/json, text/event-stream"})
        try:
            urllib.request.urlopen(request, timeout=10)
            raise AssertionError("unauthenticated request accepted")
        except urllib.error.HTTPError as error:
            assert error.code == 401
            challenge = error.headers.get("WWW-Authenticate", "")
            discovered = re.search(r'resource_metadata="([^"]+)"', challenge)
            assert discovered and fetch_json(discovered[1])["resource"] == endpoint
        summary = {"discovery": "passed", "unauthenticated_challenge": "passed",
            "cimd_advertised": authorization.get("client_id_metadata_document_supported", False)}
        token = os.environ.get(args.token_env)
        if token:
            summary["authenticated"] = asyncio.run(authenticated_probe(endpoint, token))
        elif args.require_auth:
            raise RuntimeError("required process credential unavailable")
        else:
            summary["authenticated"] = "not-run:no-process-credential"
        print(json.dumps(summary))
        return 0
    except Exception as error:
        # Exception payloads can contain request details. Report only the class.
        print(json.dumps({"status": "failed", "error_class": type(error).__name__}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
