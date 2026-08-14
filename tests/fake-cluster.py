#!/usr/bin/env python3
"""
fake-cluster.py — canned Elasticsearch / OpenSearch responses for testing.

Lets the end-to-end test exercise the real code path (preflight, every
collector, report generation, audit chain) without touching a live cluster.

Usage:
    fake-cluster.py --port 9200 --flavor es8
    fake-cluster.py --port 9201 --flavor opensearch --version 3.3.2
"""

import argparse
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

# A source that exercises several distinct finding paths at once:
# blocking (esql, eql), translate (sql, ilm, flattened), rebuild (ml).
ES8_FIXTURES = {
    "/": {
        "name": "fake-es",
        "cluster_name": "ops",
        "version": {"number": "8.13.0", "build_flavor": "default"},
    },
    "/_xpack/usage": {
        "sql": {"available": True, "enabled": True,
                "queries": {"_all": {"total": 4210}}},
        "eql": {"available": True, "enabled": True,
                "queries": {"_all": {"total": 87}}},
        "esql": {"available": True, "enabled": True,
                 "queries": {"_all": {"total": 12}}},
        "watcher": {"available": True, "enabled": True,
                    "count": {"active": 6, "total": 9}},
        "transform": {"available": True, "enabled": True,
                      "transforms": {"_all": 3}},
        "ml": {"available": True, "enabled": True,
               "jobs": {"_all": {"count": 5}},
               "data_frame_analytics_jobs": {"_all": {"count": 0}},
               "inference": {"trained_models": {"_all": {"count": 2}}}},
        "ccr": {"available": True, "enabled": True, "follower_indices_count": 0},
        "graph": {"available": True, "enabled": False},
        "runtime_fields": {"available": True, "enabled": True,
                           "field_types": [{"name": "keyword", "count": 11}]},
        "vectors": {"available": True, "enabled": True,
                    "dense_vector_fields_count": 3,
                    "sparse_vector_fields_count": 0},
        "data_streams": {"available": True, "enabled": True, "data_streams": 14},
        "ilm": {"available": True, "enabled": True, "policy_count": 22},
        "slm": {"available": True, "enabled": True, "policy_count": 2},
        "searchable_snapshots": {"available": True, "enabled": True,
                                 "indices_count": 0},
        "rollup": {"available": True, "enabled": False},
        "fleet": {"available": True, "enabled": True, "agents": {"total": 42}},
    },
    "/_all/_mapping": {
        "app-logs-000001": {
            "mappings": {
                "properties": {
                    "@timestamp": {"type": "date"},
                    "message": {"type": "text"},
                    "labels": {"type": "flattened"},
                    "embedding": {"type": "dense_vector", "dims": 384},
                    "host": {"type": "constant_keyword", "value": "a"},
                    "count": {"type": "unsigned_long"},
                }
            }
        }
    },
    "/_enrich/policy": {"policies": [{"config": {}}, {"config": {}}]},
    "/_ilm/policy": {"logs": {}, "metrics": {}},
    "/_slm/policy": {"nightly": {}},
    "/_transform": {"count": 3, "transforms": []},
    "/_data_stream": {"data_streams": [{"name": "logs-a"}, {"name": "logs-b"}]},
    "/_ingest/pipeline": {
        "enrich-hosts": {"processors": [{"enrich": {"policy_name": "hosts"}}]},
        "classify": {"processors": [{"inference": {"model_id": "m1"}}]},
    },
    "/_security/role": {
        "analyst": {"indices": [{"names": ["logs-*"],
                                 "query": '{"term":{"tenant":"a"}}'}]},
        "reader": {"indices": [{"names": ["*"]}]},
    },
    "/_cluster/health": {"status": "green"},
}

OPENSEARCH_FIXTURES = {
    "/": {
        "name": "fake-os",
        "cluster_name": "ops-new",
        "version": {"number": "3.3.2", "distribution": "opensearch"},
    },
    "/_cluster/health": {"status": "green"},
}


def make_handler(fixtures):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            path = self.path.split("?")[0]
            if path in fixtures:
                self._send(200, fixtures[path])
            else:
                self._send(404, {"error": "not found", "path": path})

        def _send(self, code, payload):
            body = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass  # keep test output clean

    return Handler


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--flavor", choices=["es8", "opensearch"], required=True)
    ap.add_argument("--version")
    args = ap.parse_args()

    fixtures = dict(ES8_FIXTURES if args.flavor == "es8" else OPENSEARCH_FIXTURES)
    if args.version:
        root = dict(fixtures["/"])
        root["version"] = dict(root["version"], number=args.version)
        fixtures["/"] = root

    HTTPServer(("127.0.0.1", args.port), make_handler(fixtures)).serve_forever()


if __name__ == "__main__":
    main()
