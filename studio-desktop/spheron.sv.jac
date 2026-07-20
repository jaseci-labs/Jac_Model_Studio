"""studio - Spheron GPU cloud integration (REST API).

Wraps the Spheron AI REST API (https://docs.spheron.network/api-reference):
verify auth + balance, search GPU offers, deploy instances, poll status,
ssh url, and terminate. There is no Python SDK, so every call is a plain
HTTPS request via stdlib urllib — the `vastai` dependency this replaced is
gone, and nothing replaces it. Auth is a single `Authorization: Bearer <key>`
header; the key comes from the caller's stored SpheronCred (encrypted at rest
via crypto.sv.jac) or the shared SPHERON_API_KEY env var.

API shape notes that drove the design:
  * No exec / logs / start / stop / reboot endpoints. A deployment goes
    deploying → running → terminated|failed. To run a command on an instance
    you bake it into cloudInit.runcmd at deploy time — that is what the
    dispatch bridge does (dispatch_training_job deploys a fresh instance with
    the rendered training command in runcmd).
  * Deployment ids are STRINGS, not ints like Vast's contract ids. The client
    surface uses str throughout.
  * spend guardrails are preserved (SPHERON_MAX_CONCURRENT / _DAILY_BUDGET_USD
    / _MAX_HOURLY) so the budget logic from vast.sv.jac carries over.

Checker notes (jaclang 0.16.1): urllib responses are untyped, so every SDK
response arrives as `any`. We normalize into fresh dict literals (whose value
side is untyped and so accepts `any`) rather than typed View objects — same
trick inference.loaded_info() / models.warm_model() and the old vast module
use to side-step the E1001 any-boundary rule. Every endpoint guards its HTTP
call and returns {ok:bool, error:str,...}; ok=True means the API call
succeeded.
"""

import os;
import datetime;
import json;
import re;
import shlex;
import from urllib.request { Request, urlopen }
import from urllib.error { HTTPError, URLError }
import from urllib.parse { quote as urlquote }
import audit;
import crypto;
import jobs;
import backends;
import workspace;
import from uuid { uuid4 }

"""Per-user Spheron API key. Lives on the caller's OWN root, so each tenant's
key (and the deployments it controls / the spend it accrues) is private to
them. Falls back to the shared SPHERON_API_KEY env var when no user key is
set, so a single-admin deploy still works without every user bringing a key."""
node SpheronCred {
    has api_key: str = "",   # encrypted at rest via crypto.encrypt (see crypto.sv.jac)
        label: str = "",
        set_at: str = "";
}

"""Tracks deployments this user created (required when falling back to a
shared key, so the INSTANCES list can be filtered to the caller's own)."""
node SpheronDeployment {
    has deployment_id: str = "",
        offer_id: str = "",
        hourly_rate: float = 0.0,
        gpu_type: str = "",
        gpu_count: int = 0,
        provider: str = "",
        region: str = "",
        created_at: str = "",
        terminated_at: str = "";
}

"""A training job dispatched to a fresh Spheron instance via cloud-init."""
node SpheronDispatch {
    has did: str = "",
        deployment_id: str = "",
        name: str = "",
        mode: str = "",
        backend: str = "",
        inner_cmd: str = "",
        status: str = "running",
        started: str = "",
        finished: str = "",
        message: str = "";
}

def _base_url() -> str {
    return os.environ.get("SPHERON_API_URL", "https://app.spheron.ai").rstrip("/");
}

def _max_concurrent() -> int {
    try {
        return int(str(os.environ.get("SPHERON_MAX_CONCURRENT", "2")));
    } except Exception {
        return 2;
    }
}

def _daily_budget_usd() -> float {
    try {
        return float(str(os.environ.get("SPHERON_DAILY_BUDGET_USD", "50")));
    } except Exception {
        return 50.0;
    }
}

"""Caps any single deployment's hourlyRate ($/hr total for the whole instance)."""
def _max_hourly() -> float {
    try {
        return float(str(os.environ.get("SPHERON_MAX_HOURLY", "3.0")));
    } except Exception {
        return 3.0;
    }
}

def _active_deployments() -> list {
    out: list = [];
    for d in [root -->][?:SpheronDeployment] {
        if not d.terminated_at { out.append(d); }
    }
    return out;
}

"""Rough daily spend estimate: sum(hourly_rate * 24) for active deployments
created today."""
def _today_spend_estimate() -> float {
    today = datetime.datetime.now(datetime.UTC).date().isoformat();
    total = 0.0;
    # Iterate the graph directly so `d` is typed SpheronDeployment (the helper
    # returns an untyped list, which would leave d.hourly_rate Unknown here).
    for d in [root -->][?:SpheronDeployment] {
        if not d.terminated_at and str(d.created_at).startswith(today) {
            total += float(d.hourly_rate) * 24.0;
        }
    }
    return total;
}

def _guard_create(hourly_rate: float) -> str {
    if hourly_rate > _max_hourly() {
        return f"hourly_rate {hourly_rate} exceeds max {_max_hourly()}";
    }
    if len(_active_deployments()) >= _max_concurrent() {
        return "concurrent deployment cap reached";
    }
    est = _today_spend_estimate() + hourly_rate * 24.0;
    if est > _daily_budget_usd() {
        return f"daily budget exceeded (est ${est:.2f})";
    }
    return "";
}

"""When using a shared key, only deployments recorded on the caller's root
are operable (terminate / detail / dispatch refresh). With a user key, the
Spheron account itself scopes visibility."""
def _owns_deployment(id: str) -> bool {
    if _key_source() == "user" { return True; }
    for d in [root -->][?:SpheronDeployment] {
        if d.deployment_id == id and not d.terminated_at { return True; }
    }
    return False;
}

def _mark_terminated(id: str) -> None {
    for d in [root -->][?:SpheronDeployment] {
        if d.deployment_id == id {
            d.terminated_at = _now();
        }
    }
}

def _now() -> str {
    return datetime.datetime.now(datetime.UTC).replace(tzinfo=None).isoformat() + "Z";
}

"""The caller's stored SpheronCred, or None. Caller's root only (multi-tenant)."""
def _user_cred() -> SpheronCred | None {
    cr = [root -->][?:SpheronCred];
    return cr[0] if len(cr) > 0 else None;
}

"""Resolve the API key: caller's stored key wins, else shared env, else None.
The stored key is decrypted here — the only point it exists in plaintext,
inside the request that spends on it."""
def _api_key() -> str {
    c = _user_cred();
    if c is not None and c.api_key { return str(crypto.decrypt(c.api_key)); }
    return os.environ.get("SPHERON_API_KEY", "");
}

"""Which source the resolved key comes from — drives the credential badge."""
def _key_source() -> str {
    c = _user_cred();
    if c is not None and c.api_key { return "user"; }
    if os.environ.get("SPHERON_API_KEY", "") { return "shared"; }
    return "none";
}

"""True if the caller has a user key OR SPHERON_API_KEY is set — drives the
'connected' badge without a network call. (Spheron has no SDK keyfile.)"""
def _configured() -> bool {
    c = _user_cred();
    if c is not None and c.api_key { return True; }
    return bool(os.environ.get("SPHERON_API_KEY", ""));
}

"""Safe dict getter: o[k] if present else default. Keeps any-typed API dicts
from throwing on missing keys (deployment schemas vary across providers)."""
def _f(o: any, k: str, fallback: any = None) -> any {
    try {
        return o[k];
    } except Exception {
        return fallback;
    }
}

"""One HTTPS call against the Spheron API. Returns parsed JSON (dict/list) or
raises RuntimeError with the API's error message. `query` is url-encoded into
the query string; `body` (dict) is JSON-encoded. Auth header added when a key
is resolved. Timeout is generous (30s) because deploy/list can be slow."""
def _request(method: str, path: str, query: dict = {}, body: any = None) -> any {
    url = _base_url() + path;
    if len(query) > 0 {
        parts: list[str] = [];
        for k in query {
            parts.append(urlquote(str(k)) + "=" + urlquote(str(query[k])));
        }
        url = url + "?" + "&".join(parts);
    }
    headers: dict = {"Accept": "application/json"};
    key = _api_key();
    if key { headers["Authorization"] = "Bearer " + key; }
    data: any = None;
    if body is not None {
        data = json.dumps(body).encode("utf-8");
        headers["Content-Type"] = "application/json";
    }
    req: any = None;
    req = Request(url, data=data, method=method, headers=headers);
    try {
        resp: any = None;
        resp = urlopen(req, timeout=30);  # jac:ignore[E1053]  # req is a Request built above; any-typed only because urllib is untyped
        raw = str(resp.read().decode("utf-8"));
        resp.close();
        return json.loads(raw) if raw else {};
    } except HTTPError as e {
        raw = str(e.read().decode("utf-8", errors="replace"));
        msg = raw;
        try {
            j = json.loads(raw);
            if isinstance(j, dict) {
                msg = str(_f(j, "error", _f(j, "message", raw)));
            }
        } except Exception {}
        if not msg { msg = "HTTP " + str(e.code); }
        raise RuntimeError(msg);
    } except URLError as e {
        reason = getattr(e, "reason", str(e));
        raise RuntimeError(str(reason));
    }
}

"""Normalize a raw deployment dict (from GET /api/deployments[/id]) into a
stable client-facing shape. Field names mirror the old vast _instance_view so
the Cloud section's labels keep working (id/label/image/cur_state/gpu_name/
num_gpus/dph_total/ssh_addr)."""
def _deployment_view(o: any) -> dict {
    return {
        "id": str(_f(o, "id", "")),
        "label": str(_f(o, "name", "")),
        "image": str(_f(o, "operatingSystem", "")),
        "cur_state": str(_f(o, "status", "")),
        "status_msg": str(_f(o, "status", "")),
        "gpu_name": str(_f(o, "gpuType", "")),
        "num_gpus": int(str(_f(o, "gpuCount", 0))),
        "dph_total": float(str(_f(o, "hourlyRate", _f(o, "originalHourlyRate", 0.0)))),
        "ssh_addr": str(_f(o, "sshCommand", "")),
        "ports": str(_f(o, "sshPort", "")),
        "machine_id": str(_f(o, "providerId", _f(o, "provider", "")))
    };
}

"""Store or replace the caller's Spheron API key on their own root. Subsequent
spheron_* calls then attribute spend to the caller's OWN Spheron account.
Never echoes the key back. Returns {ok, source, error}."""
def set_spheron_key(api_key: str, label: str = "") -> dict {
    k = api_key.strip();
    if not k { return {"ok": False, "source": _key_source(), "error": "empty key"}; }
    enc = crypto.encrypt(k);
    existing = _user_cred();
    if existing is not None {
        existing.api_key = enc;
        existing.label = label;
        existing.set_at = _now();
    } else {
        root ++> SpheronCred(api_key=enc, label=label, set_at=_now());
    }
    return {"ok": True, "source": "user", "error": ""};
}

"""Delete the caller's stored key (falls back to the shared env key)."""
def clear_spheron_key() -> dict {
    c = _user_cred();
    if c is not None { del c; }
    return {"ok": True, "source": _key_source(), "error": ""};
}

"""Credential status for the Spheron badge — never returns the key itself.
{has_user_key, label, source: user|shared|none, configured}."""
def spheron_credential_status() -> dict {
    c = _user_cred();
    return {
        "has_user_key": c is not None and bool(c.api_key),
        "label": c.label if c is not None else "",
        "source": _key_source(),
        "configured": _configured()
    };
}

"""Verify the API key + account balance (one cheap GET /api/balance plus the
teams list for the current-team id). Returns
{ok, configured, balance, currency, team_id, team_name, error}. ok=True means
the key authenticated against Spheron. This is the connection-health endpoint."""
def spheron_status() -> dict {
    if not _configured() {
        return {
            "ok": False, "configured": False,
            "balance": 0.0, "currency": "USD",
            "team_id": "", "team_name": "",
            "error": "SPHERON_API_KEY not set and no per-user key stored"
        };
    }
    try {
        b: any = _request("GET", "/api/balance");
        teams: any = _request("GET", "/api/teams");
        # /api/balance returns {teams: [{teamId, teamName, balance, isCurrentTeam, ...}]}
        bal = 0.0;
        tid = "";
        tname = "";
        bteams = _f(b, "teams", []);
        if isinstance(bteams, list) and len(bteams) > 0 {
            first: any = bteams[0];
            bal = float(str(_f(first, "balance", 0.0)));
            tid = str(_f(first, "teamId", ""));
            tname = str(_f(first, "teamName", ""));
        }
        # teams list gives the current team id too — prefer it when balance
        # response didn't mark one.
        if not tid and isinstance(teams, list) and len(teams) > 0 {
            tid = str(_f(teams[0], "id", ""));
            tname = str(_f(teams[0], "name", ""));
        }
        return {
            "ok": True, "configured": True,
            "balance": bal,
            "currency": str(_f(b, "currency", "USD")),
            "team_id": tid, "team_name": tname,
            "error": ""
        };
    } except Exception as e {
        return {
            "ok": False, "configured": True,
            "balance": 0.0, "currency": "USD",
            "team_id": "", "team_name": "",
            "error": str(e)
        };
    }
}

"""List configured GPU providers (public, no auth needed). Returns
{ok, providers:[str], error}."""
def spheron_providers() -> dict {
    try {
        rows: any = _request("GET", "/api/providers");
        out: list[str] = [];
        if isinstance(rows, list) {
            for p in rows { out.append(str(p)); }
        }
        return {"ok": True, "providers": out, "error": ""};
    } except Exception as e {
        return {"ok": False, "providers": [], "error": str(e)};
    }
}

"""Search rentable GPU offers (GET /api/gpu-offers). `search` filters by GPU
model (e.g. "rtx-4090"); `instance_type` is 'SPOT' | 'DEDICATED' | 'CLUSTER'
(case-insensitive); `limit`/`page` paginate (defaults 10/1); `sort_by`/
`sort_order` sort. Returns {ok, count, offers:[...], error}. Each offer is
flattened from the offers[] entries under each gpu-type group:
{id(offerId), gpu_name, num_gpus, dph_total, cpu_cores, cpu_ram, gpu_ram,
space, provider, region, instance_type, available, gpu_type}."""
def search_gpus(
    search: str = "",
    instance_type: str = "",
    limit: int = 10,
    page: int = 1,
    sort_by: str = "popularity",
    sort_order: str = "asc"
) -> dict {
    try {
        query: dict = {"limit": str(limit), "page": str(page), "sortBy": sort_by, "sortOrder": sort_order};
        if search { query["search"] = search; }
        if instance_type { query["instanceType"] = instance_type.upper(); }
        res: any = _request("GET", "/api/gpu-offers", query=query);
        out: list[dict] = [];
        data = _f(res, "data", []);
        if isinstance(data, list) {
            for grp in data {
                offers = _f(grp, "offers", []);
                if not isinstance(offers, list) { continue; }
                for o in offers {
                    out.append({
                        "id": str(_f(o, "offerId", "")),
                        "gpu_name": str(_f(o, "name", _f(grp, "displayName", ""))),
                        "gpu_type": str(_f(o, "gpuType", _f(grp, "gpuType", ""))),
                        "num_gpus": int(str(_f(o, "gpuCount", 0))),
                        "dph_total": float(str(_f(o, "price", _f(o, "spot_price", 0.0)))),
                        "cpu_cores": int(str(_f(o, "vcpus", 0))),
                        "cpu_ram": float(str(_f(o, "memory", 0.0))),
                        "gpu_ram": float(str(_f(o, "gpu_memory", 0.0))),
                        "space": float(str(_f(o, "storage", 0.0))),
                        "provider": str(_f(o, "provider", "")),
                        "region": str(_f(o, "region", "")),
                        "instance_type": str(_f(o, "instanceType", "")),
                        "available": bool(_f(o, "available", False)),
                        "os_options": list(_f(o, "os_options", []))
                    });
                }
            }
        }
        return {"ok": True, "count": len(out), "offers": out, "error": ""};
    } except Exception as e {
        return {"ok": False, "count": 0, "offers": [], "error": str(e)};
    }
}

"""Deploy an instance (POST /api/deployments). `offer_id` comes from
search_gpus (the offerId); the rest are Spheron-required deployment fields.
`ssh_key_id` references a key uploaded via add_spheron_ssh_key (or the
dashboard); if empty, you must pass ssh_public_key inline at the dashboard
level — this wrapper requires one or the other. Returns
{ok, deployment_id, raw, error} — deployment_id is the new deployment's id."""
def create_gpu_instance(
    offer_id: str,
    gpu_type: str,
    gpu_count: int,
    region: str,
    operating_system: str,
    instance_type: str,
    hourly_rate: float,
    ssh_key_id: str = "",
    ssh_public_key: str = "",
    provider: str = "spheron-ai",
    name: str = "",
    cloud_init: dict = {}
) -> dict {
    if not ssh_key_id and not ssh_public_key {
        return {"ok": False, "deployment_id": "", "raw": {}, "error": "ssh_key_id or ssh_public_key required"};
    }
    # Reserve BEFORE the API call: _active_deployments()/_today_spend_estimate()
    # count any SpheronDeployment with an empty terminated_at, so the reservation
    # node (deployment_id="" until the POST lands) is included in a concurrent
    # request's guard. This shrinks the check-then-act window from the whole
    # multi-second API round-trip down to two adjacent graph ops. A concurrent
    # create is denied on the reservation it can see rather than racing past a
    # stale spend estimate. The reservation is deleted if the API call fails.
    guard_err = _guard_create(hourly_rate);
    if guard_err {
        audit.log("spheron_create_denied", {"offer_id": offer_id, "reason": guard_err});
        return {"ok": False, "deployment_id": "", "raw": {}, "error": guard_err};
    }
    resv = root ++> SpheronDeployment(
        deployment_id="", offer_id=offer_id, hourly_rate=hourly_rate,
        gpu_type=gpu_type, gpu_count=gpu_count, provider=provider,
        region=region, created_at=_now()
    );
    body: dict = {
        "provider": provider,
        "offerId": offer_id,
        "gpuType": gpu_type,
        "gpuCount": gpu_count,
        "region": region,
        "operatingSystem": operating_system,
        "instanceType": instance_type.upper(),
        "name": name
    };
    if ssh_key_id { body["sshKeyId"] = ssh_key_id; }
    else { body["ssh_public_key"] = ssh_public_key; }
    if len(cloud_init) > 0 { body["cloudInit"] = cloud_init; }
    try {
        res: any = _request("POST", "/api/deployments", body=body);
        did = str(_f(res, "id", ""));
        resv.deployment_id = did;
        audit.log("spheron_create", {
            "deployment_id": did, "offer_id": offer_id,
            "hourly_rate": hourly_rate, "provider": provider
        });
        return {"ok": True, "deployment_id": did, "raw": res, "error": ""};
    } except Exception as e {
        del resv;   # release the reservation so it stops counting against the budget
        audit.log("spheron_create_failed", {"offer_id": offer_id, "error": str(e)});
        return {"ok": False, "deployment_id": "", "raw": {}, "error": str(e)};
    }
}

"""All your deployments (GET /api/deployments). `status` filters: 'active'
(running/deploying), 'inactive' (terminated/failed), or a specific status.
Returns {ok, instances:[...], error}. Each is normalized via _deployment_view."""
def spheron_instances(status: str = "") -> dict {
    try {
        query: dict = {};
        if status { query["status"] = status; }
        rows: any = _request("GET", "/api/deployments", query=query);
        out: list[dict] = [];
        if isinstance(rows, list) {
            for o in rows {
                did = str(_f(o, "id", ""));
                if _key_source() != "user" and not _owns_deployment(did) { continue; }
                out.append(_deployment_view(o));
            }
        }
        return {"ok": True, "instances": out, "error": ""};
    } except Exception as e {
        return {"ok": False, "instances": [], "error": str(e)};
    }
}

"""One deployment by id — polling-friendly (call on a timer to watch
deploying → running). Returns {ok, instance, error}."""
def spheron_instance(id: str) -> dict {
    if not _owns_deployment(id) {
        return {"ok": False, "instance": {}, "error": "deployment not owned by caller"};
    }
    try {
        o: any = _request("GET", "/api/deployments/" + urlquote(id));
        if not isinstance(o, dict) {
            return {"ok": False, "instance": {}, "error": "deployment " + id + " not found"};
        }
        if not str(_f(o, "id", "")) {
            return {"ok": False, "instance": {}, "error": "deployment " + id + " not found"};
        }
        return {"ok": True, "instance": _deployment_view(o), "error": ""};
    } except Exception as e {
        return {"ok": False, "instance": {}, "error": str(e)};
    }
}

"""SSH connection string for a running deployment (pulled from the deployment
detail's sshCommand). Returns {ok, ssh, scp, error}. scp is derived best-
effort from ssh (Spheron doesn't expose a separate scp url). Use `ssh` once
the deployment status is 'running' (boot is typically 30-60s)."""
def spheron_ssh(id: str) -> dict {
    if not _owns_deployment(id) {
        return {"ok": False, "ssh": "", "scp": "", "error": "deployment not owned by caller"};
    }
    try {
        o: any = _request("GET", "/api/deployments/" + urlquote(id));
        ssh = str(_f(o, "sshCommand", ""));
        scp = "";
        if ssh {
            # 'ssh user@host' -> 'scp ... user@host:'; best-effort derivation.
            scp = ssh.replace("ssh ", "scp ", 1) + ":";
        }
        return {"ok": True, "ssh": ssh, "scp": scp, "error": ""};
    } except Exception as e {
        return {"ok": False, "ssh": "", "scp": "", "error": str(e)};
    }
}

"""Check whether a deployment has met its minimum runtime and can be safely
terminated (GET /api/deployments/{id}/can-terminate). Returns
{ok, can_terminate, runtime, time_remaining, minimum_runtime, error}."""
def can_terminate_gpu_instance(id: str) -> dict {
    if not _owns_deployment(id) {
        return {"ok": False, "can_terminate": False, "error": "deployment not owned by caller"};
    }
    try {
        o: any = _request("GET", "/api/deployments/" + urlquote(id) + "/can-terminate");
        return {
            "ok": True,
            "can_terminate": bool(_f(o, "canTerminate", False)),
            "runtime": int(str(_f(o, "runtime", 0))),
            "time_remaining": int(str(_f(o, "timeRemaining", 0))),
            "minimum_runtime": int(str(_f(o, "minimumRuntime", 0))),
            "error": ""
        };
    } except Exception as e {
        return {"ok": False, "can_terminate": False, "error": str(e)};
    }
}

"""Rename a deployment (PATCH /api/deployments/{id}). Only the name is mutable.
Returns {ok, instance, error}."""
def rename_gpu_instance(id: str, name: str) -> dict {
    if not _owns_deployment(id) {
        return {"ok": False, "instance": {}, "error": "deployment not owned by caller"};
    }
    try {
        o: any = _request("PATCH", "/api/deployments/" + urlquote(id), body={"name": name});
        return {"ok": True, "instance": _deployment_view(o), "error": ""};
    } except Exception as e {
        return {"ok": False, "instance": {}, "error": str(e)};
    }
}

"""Terminate a deployment (DELETE /api/deployments/{id}). Stops ALL billing.
Returns {ok, action, id, result, error}."""
def destroy_gpu_instance(id: str) -> dict { return _lifecycle("destroy", id); }

def _lifecycle(action: str, id: str) -> dict {
    if not _owns_deployment(id) {
        audit.log("spheron_denied", {"action": action, "deployment_id": id});
        return {
            "ok": False, "action": action, "id": id,
            "result": {}, "error": "deployment not owned by caller"
        };
    }
    # Spheron only supports terminate (no stop/start/reboot). can-terminate
    # is checked first so we surface the minimum-runtime reason instead of a
    # raw 400 from the DELETE.
    if action == "destroy" {
        chk = can_terminate_gpu_instance(id);
        if bool(chk["ok"]) and not bool(chk["can_terminate"]) {
            remain = int(str(chk["time_remaining"]));
            return {
                "ok": False, "action": action, "id": id, "result": chk,
                "error": f"minimum runtime not met ({remain}s remaining)"
            };
        }
    }
    try {
        res: any = _request("DELETE", "/api/deployments/" + urlquote(id));
        _mark_terminated(id);
        audit.log("spheron_" + action, {"deployment_id": id});
        return {"ok": True, "action": action, "id": id, "result": res, "error": ""};
    } except Exception as e {
        return {"ok": False, "action": action, "id": id, "result": {}, "error": str(e)};
    }
}

# ---------------------------------------------------------------------------
# SSH keys (GET / POST /api/ssh-keys)
# ---------------------------------------------------------------------------

"""List the caller's uploaded SSH keys (GET /api/ssh-keys). Returns
{ok, keys:[{id, name, fingerprint, created_at}], error}."""
def spheron_ssh_keys() -> dict {
    try {
        rows: any = _request("GET", "/api/ssh-keys");
        out: list[dict] = [];
        if isinstance(rows, list) {
            for o in rows {
                out.append({
                    "id": str(_f(o, "id", "")),
                    "name": str(_f(o, "name", "")),
                    "fingerprint": str(_f(o, "fingerprint", "")),
                    "created_at": str(_f(o, "createdAt", ""))
                });
            }
        }
        return {"ok": True, "keys": out, "error": ""};
    } except Exception as e {
        return {"ok": False, "keys": [], "error": str(e)};
    }
}

"""Upload a new SSH public key (POST /api/ssh-keys). Required before deploying
unless you pass an inline ssh_public_key at deploy time. Returns
{ok, key_id, error}."""
def add_spheron_ssh_key(name: str, public_key: str) -> dict {
    if not name.strip() or not public_key.strip() {
        return {"ok": False, "key_id": "", "error": "name and public_key required"};
    }
    try {
        o: any = _request("POST", "/api/ssh-keys", body={"name": name, "publicKey": public_key.strip()});
        return {"ok": True, "key_id": str(_f(o, "id", "")), "error": ""};
    } except Exception as e {
        return {"ok": False, "key_id": "", "error": str(e)};
    }
}

# ---------------------------------------------------------------------------
# Cloud dispatch — deploy a fresh instance with the training command baked
# into cloudInit.runcmd (bridge jobs ↔ spheron). Spheron has no exec/logs API,
# so a dispatch IS a new deployment; status tracks the VM (deploying/running/
# terminated/failed), and the user SSHes in to inspect job output.
# ---------------------------------------------------------------------------

def _remote_root(scope: str) -> str {
    cfg = workspace.spheron_remote_config();
    if scope == "data" {
        return str(cfg.get("remote_data_root", os.environ.get("SPHERON_REMOTE_DATA_ROOT", "/workspace/data")));
    }
    if scope == "studio" {
        return str(cfg.get("remote_studio_root", os.environ.get("SPHERON_REMOTE_STUDIO_ROOT", "/workspace/studio-desktop")));
    }
    return str(cfg.get("remote_workspace_root", os.environ.get("SPHERON_REMOTE_WORKSPACE_ROOT", "/workspace")));
}

def _remote_run_dir(name: str) -> str {
    return f"$HOME/studio-runs/{name}";
}

def _export_env(env: dict) -> str {
    parts: list[str] = [];
    for k in env {
        parts.append(f"export {shlex.quote(str(k))}={shlex.quote(str(env[k]))}");
    }
    if len(parts) == 0 { return "true"; }
    return " && ".join(parts);
}

"""Build the cloud-init runcmd entry: mkdir run dir, cd into the remote root,
export env, then nohup the rendered command detached with an __EXIT__ marker
appended to the run log. Returned as a single shell string (one runcmd entry)
so cloud-init runs it atomically at boot."""
def _remote_launch_cmd(rendered: dict, name: str, mode: str) -> str {
    remote_cwd = _remote_root(str(rendered.get("cwd_scope", "data")));
    run_dir = _remote_run_dir(name);
    runlog = f"{run_dir}/run-{mode}.log";
    inner = str(rendered["cmd"]);
    env_part = _export_env(dict(rendered["env"]));
    wrapped = inner + f'; echo "__EXIT__ $?" >> {runlog}';
    return (
        f"mkdir -p {shlex.quote(run_dir)} && "
        f"cd {shlex.quote(remote_cwd)} && "
        f"{env_part} && "
        f"nohup bash -lc {shlex.quote(wrapped)} >> {shlex.quote(run_dir + '/train.log')} 2>&1 & "
        f"echo DISPATCH_PID:$!"
    );
}

def _find_dispatch(did: str) -> SpheronDispatch | None {
    for d in [root -->][?:SpheronDispatch] {
        if d.did == did { return d; }
    }
    return None;
}

"""Map a Spheron deployment status onto a dispatch status. Spheron has no
job-exit signal via API (no exec/logs), so we can only track the VM: once the
VM is 'running' we presume the job launched; 'failed' / 'terminated*' close
the dispatch."""
def _dispatch_status_from(deployment_status: str) -> str {
    s = deployment_status.lower();
    if s == "failed" { return "failed"; }
    if s == "terminated" or s == "terminated-provider" { return "done"; }
    return "running";
}

"""Poll the backing deployment and refresh dispatch status. Spheron exposes no
log tail, so log_tail is always '' — the UI tells the user to SSH in."""
def _refresh_dispatch(d: SpheronDispatch) -> dict {
    if d.status == "done" or d.status == "failed" or d.status == "stopped" {
        return _dispatch_view(d, "");
    }
    inst = spheron_instance(d.deployment_id);
    if not bool(inst["ok"]) {
        # Deployment gone (terminated/expired) -> mark done.
        d.status = "done";
        d.finished = _now();
        d.message = str(inst["error"]);
        return _dispatch_view(d, "");
    }
    dep_status = str(_f(inst["instance"], "cur_state", ""));
    mapped = _dispatch_status_from(dep_status);
    if mapped != "running" and d.status == "running" {
        d.status = mapped;
        d.finished = _now();
        d.message = f"deployment {dep_status}";
    } elif d.status == "running" {
        d.message = f"deployment {dep_status} · SSH in to inspect job output";
    }
    return _dispatch_view(d, "");
}

def _dispatch_view(d: SpheronDispatch, log_tail: str) -> dict {
    return {
        "id": d.did,
        "deployment_id": d.deployment_id,
        "name": d.name,
        "mode": d.mode,
        "backend": d.backend,
        "status": d.status,
        "started": d.started,
        "finished": d.finished,
        "message": d.message,
        "inner_cmd": d.inner_cmd,
        "log_tail": log_tail
    };
}

"""Dispatch a training job by deploying a fresh Spheron instance with the
rendered command baked into cloudInit.runcmd.

Renders the job via backends.render(), wraps it into a detached nohup one-
liner, embeds it as the deployment's cloudInit.runcmd, and records a
SpheronDispatch node linked to the new deployment for polling. Spheron has no
exec API, so this deploys a NEW instance per dispatch (offer fields required).

Returns {ok, dispatch, error}."""
def dispatch_training_job(
    offer_id: str,
    gpu_type: str,
    gpu_count: int,
    region: str,
    operating_system: str,
    instance_type: str,
    hourly_rate: float,
    name: str,
    mode: str,
    ssh_key_id: str = "",
    ssh_public_key: str = "",
    model_id: str = "",
    opts: dict = {},
    backend: str = "",
    provider: str = "spheron-ai"
) -> dict {
    if not jobs.safe(name) { return {"ok": False, "dispatch": {}, "error": "invalid name"}; }
    if name in workspace.excluded_run_dirs() {
        return {"ok": False, "dispatch": {}, "error": "reserved name"};
    }
    if mode != "sft" and mode != "dpo" {
        return {"ok": False, "dispatch": {}, "error": "mode must be sft|dpo"};
    }
    if mode == "sft" {
        if not model_id or not jobs.safe(model_id, allow_slash=True) {
            return {"ok": False, "dispatch": {}, "error": "invalid model_id"};
        }
    }
    if not ssh_key_id and not ssh_public_key {
        return {"ok": False, "dispatch": {}, "error": "ssh_key_id or ssh_public_key required"};
    }

    bk = backend if backend else "spheron_gpu";
    try {
        rendered = backends.render({
            "backend": bk,
            "method": mode,
            "vars": {"run_name": shlex.quote(name), "model_id": shlex.quote(model_id)},
            "opts": opts
        });
    } except Exception as e {
        return {"ok": False, "dispatch": {}, "error": str(e)};
    }

    runcmd = _remote_launch_cmd(rendered, name, mode);
    cloud_init: dict = {"runcmd": [runcmd]};

    deploy = create_gpu_instance(
        offer_id=offer_id, gpu_type=gpu_type, gpu_count=gpu_count,
        region=region, operating_system=operating_system,
        instance_type=instance_type, hourly_rate=hourly_rate,
        ssh_key_id=ssh_key_id, ssh_public_key=ssh_public_key,
        provider=provider, name=name, cloud_init=cloud_init
    );
    if not bool(deploy["ok"]) {
        return {"ok": False, "dispatch": {}, "error": str(deploy["error"])};
    }
    deployment_id = str(deploy["deployment_id"]);

    did = str(uuid4());
    ignored: list = list(rendered.get("ignored_opts", []));
    msg = ("ignored opts: " + ", ".join(sorted(ignored))) if ignored else "deploying";
    d = root ++> SpheronDispatch(
        did=did, deployment_id=deployment_id, name=name, mode=mode,
        backend=str(rendered["backend"]), inner_cmd=str(rendered["cmd"]),
        status="running", started=_now(), message=msg
    );
    audit.log("spheron_dispatch", {
        "dispatch_id": did, "deployment_id": deployment_id,
        "name": name, "mode": mode, "backend": bk
    });
    return {"ok": True, "dispatch": _dispatch_view(d, ""), "error": ""};
}

"""All dispatches recorded for the caller (newest first)."""
def list_spheron_dispatches() -> dict {
    rows: list[dict] = [];
    for d in [root -->][?:SpheronDispatch] {
        rows.append(_refresh_dispatch(d));
    }
    rows.sort(key=lambda r: dict -> str { return str(r["started"]); }, reverse=True);
    return {"dispatches": rows};
}

"""Poll one dispatch by id — refreshes status from the backing deployment."""
def get_spheron_dispatch(did: str) -> dict {
    d = _find_dispatch(did);
    if d is None { return {"ok": False, "dispatch": {}, "error": "not found"}; }
    return {"ok": True, "dispatch": _refresh_dispatch(d), "error": ""};
}

"""Best-effort stop: terminate the backing deployment (Spheron has no exec,
so we can't pkill — we tear down the VM, which ends the job)."""
def stop_spheron_dispatch(did: str) -> dict {
    d = _find_dispatch(did);
    if d is None { return {"ok": False, "dispatch": {}, "error": "not found"}; }
    if d.status == "running" {
        term = destroy_gpu_instance(d.deployment_id);
        d.status = "stopped";
        d.finished = _now();
        d.message = "deployment terminated" if bool(term["ok"]) else f"terminate failed: {str(term['error'])}";
        audit.log("spheron_dispatch_stop", {"dispatch_id": did, "deployment_id": d.deployment_id});
    }
    return {"ok": True, "dispatch": _dispatch_view(d, ""), "error": ""};
}
