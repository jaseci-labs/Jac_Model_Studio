#!/usr/bin/env python3
"""Fake Spheron REST API for local dev/testing of spheron.sv.jac + supervisor.py.

Implements the endpoints (paths/shapes copied from studio-desktop/spheron.sv.jac):
  GET    /api/gpu-offers                       -> {"data":[{gpuType, displayName, offers:[...]}]}
  POST   /api/deployments                      -> deployment dict (has "id")
  GET    /api/deployments                      -> [deployment, ...]
  GET    /api/deployments/{id}                 -> deployment dict
  GET    /api/deployments/{id}/can-terminate   -> {canTerminate, runtime, timeRemaining, minimumRuntime}
  DELETE /api/deployments/{id}                 -> {"id":..., "status":"terminated"}
  GET    /api/ssh-keys                         -> [{id, name, fingerprint, createdAt}, ...]
  POST   /api/ssh-keys                         -> {id, name, fingerprint, createdAt}
  GET    /api/balance                          -> {"teams":[{teamId, teamName, balance, isCurrentTeam}]}
  GET    /api/teams                            -> [{id, name}, ...]
  GET    /api/providers                        -> [str, ...]

Behavior: a new deployment starts "provisioning" and flips to "running" after
FAKE_BOOT_SECS (env, default 5) with sshCommand "ssh <current-user>@127.0.0.1".
DELETE marks it terminated. All state is in-memory. Requests are logged to
stdout. Requires an Authorization header (any Bearer token accepted).

Usage: python3 fake_spheron.py [--port 7077]
"""

import argparse
import getpass
import json
import os
import re
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

FAKE_BOOT_SECS = float(os.environ.get("FAKE_BOOT_SECS", "5"))

DEPLOYMENTS = {}   # id -> dict
_NEXT_ID = [1]
SSH_KEYS = {}      # id -> dict
_NEXT_KEY_ID = [1]

FAKE_OFFERS = {
    "data": [
        {
            "gpuType": "rtx4090",
            "displayName": "RTX 4090",
            "offers": [
                {
                    "offerId": "offer-4090-1",
                    "name": "RTX 4090",
                    "gpuType": "rtx4090",
                    "gpuCount": 1,
                    "price": 0.35,
                    "vcpus": 16,
                    "memory": 64.0,
                    "gpu_memory": 24.0,
                    "storage": 200.0,
                    "provider": "spheron-ai",
                    "region": "us-east",
                    "instanceType": "DEDICATED",
                    "available": True,
                    "os_options": ["ubuntu22.04"],
                }
            ],
        },
        {
            "gpuType": "a100",
            "displayName": "A100 80GB",
            "offers": [
                {
                    "offerId": "offer-a100-1",
                    "name": "A100 80GB",
                    "gpuType": "a100",
                    "gpuCount": 1,
                    "price": 1.45,
                    "vcpus": 32,
                    "memory": 128.0,
                    "gpu_memory": 80.0,
                    "storage": 500.0,
                    "provider": "spheron-ai",
                    "region": "us-west",
                    "instanceType": "SPOT",
                    "available": True,
                    "os_options": ["ubuntu22.04"],
                }
            ],
        },
    ]
}


def _dep_view(d):
    """Deployment dict as returned by GET /api/deployments[/id]. Status flips
    provisioning -> running after FAKE_BOOT_SECS; running deployments carry
    sshCommand (the field spheron.sv.jac and supervisor.py read)."""
    out = dict(d)
    if out["status"] == "provisioning" and time.time() - out["_created"] >= FAKE_BOOT_SECS:
        out["status"] = "running"
        d["status"] = "running"
    if out["status"] == "running" and not out.get("sshCommand"):
        ssh = "ssh %s@127.0.0.1" % getpass.getuser()
        out["sshCommand"] = ssh
        d["sshCommand"] = ssh
    out.pop("_created", None)
    return out


class Handler(BaseHTTPRequestHandler):
    server_version = "FakeSpheron/1.0"

    def log_message(self, fmt, *args):
        print("[fake_spheron] %s %s" % (self.address_string(), fmt % args), flush=True)

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _auth_ok(self):
        if not self.headers.get("Authorization", "").strip():
            self._send(401, {"error": "missing Authorization header"})
            return False
        return True

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            return json.loads(raw.decode() or "{}")
        except ValueError:
            return {}

    # -- routes --------------------------------------------------------------
    def do_GET(self):
        if not self._auth_ok():
            return
        path = self.path.split("?")[0].rstrip("/")
        if path == "/api/gpu-offers":
            return self._send(200, FAKE_OFFERS)
        if path == "/api/balance":
            return self._send(200, {"teams": [{"teamId": "t1", "teamName": "fake",
                                               "balance": 100.0, "isCurrentTeam": True}]})
        if path == "/api/teams":
            return self._send(200, [{"id": "t1", "name": "fake"}])
        if path == "/api/providers":
            return self._send(200, ["spheron-ai"])
        if path == "/api/ssh-keys":
            return self._send(200, list(SSH_KEYS.values()))
        if path == "/api/deployments":
            return self._send(200, [_dep_view(d) for d in DEPLOYMENTS.values()])
        m = re.match(r"^/api/deployments/([^/]+)/can-terminate$", path)
        if m:
            d = DEPLOYMENTS.get(m.group(1))
            if not d:
                return self._send(404, {"error": "deployment not found"})
            runtime = int(time.time() - d["_created"])
            return self._send(200, {"canTerminate": True, "runtime": runtime,
                                    "timeRemaining": 0, "minimumRuntime": 0})
        m = re.match(r"^/api/deployments/([^/]+)$", path)
        if m:
            d = DEPLOYMENTS.get(m.group(1))
            if not d:
                return self._send(404, {"error": "deployment not found"})
            return self._send(200, _dep_view(d))
        self._send(404, {"error": "no such endpoint: %s" % path})

    def do_POST(self):
        if not self._auth_ok():
            return
        path = self.path.split("?")[0].rstrip("/")
        if path == "/api/ssh-keys":
            body = self._body()
            kid = "fake-key-%d" % _NEXT_KEY_ID[0]
            _NEXT_KEY_ID[0] += 1
            k = {
                "id": kid,
                "name": body.get("name", ""),
                "fingerprint": "aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99",
                "createdAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            }
            SSH_KEYS[kid] = k
            print("[fake_spheron] added ssh key %s (%s)" % (kid, k["name"]), flush=True)
            return self._send(200, k)
        if path == "/api/deployments":
            body = self._body()
            did = "fake-dep-%d" % _NEXT_ID[0]
            _NEXT_ID[0] += 1
            d = {
                "id": did,
                "name": body.get("name", ""),
                "status": "provisioning",
                "provider": body.get("provider", "spheron-ai"),
                "offerId": body.get("offerId", ""),
                "gpuType": body.get("gpuType", ""),
                "gpuCount": body.get("gpuCount", 1),
                "region": body.get("region", ""),
                "operatingSystem": body.get("operatingSystem", "ubuntu22.04"),
                "instanceType": body.get("instanceType", "DEDICATED"),
                "hourlyRate": 0.35,
                "sshCommand": "",
                "sshPort": "22",
                "providerId": "fake-provider-1",
                "createdAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "_created": time.time(),
            }
            DEPLOYMENTS[did] = d
            print("[fake_spheron] created deployment %s (boots in %.1fs)" % (did, FAKE_BOOT_SECS),
                  flush=True)
            return self._send(200, _dep_view(d))
        self._send(404, {"error": "no such endpoint: %s" % path})

    def do_PATCH(self):
        if not self._auth_ok():
            return
        m = re.match(r"^/api/deployments/([^/]+)$", self.path.split("?")[0].rstrip("/"))
        if m and m.group(1) in DEPLOYMENTS:
            DEPLOYMENTS[m.group(1)]["name"] = self._body().get("name", "")
            return self._send(200, _dep_view(DEPLOYMENTS[m.group(1)]))
        self._send(404, {"error": "deployment not found"})

    def do_DELETE(self):
        if not self._auth_ok():
            return
        m = re.match(r"^/api/deployments/([^/]+)$", self.path.split("?")[0].rstrip("/"))
        if m:
            d = DEPLOYMENTS.get(m.group(1))
            if not d:
                return self._send(404, {"error": "deployment not found"})
            d["status"] = "terminated"
            print("[fake_spheron] DELETE deployment %s -> terminated" % m.group(1), flush=True)
            return self._send(200, {"id": d["id"], "status": "terminated"})
        self._send(404, {"error": "no such endpoint"})


def main():
    ap = argparse.ArgumentParser(description="Fake Spheron API server")
    ap.add_argument("--port", type=int, default=7077)
    args = ap.parse_args()
    srv = HTTPServer(("127.0.0.1", args.port), Handler)
    print("[fake_spheron] listening on http://127.0.0.1:%d (FAKE_BOOT_SECS=%s)"
          % (args.port, FAKE_BOOT_SECS), flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
