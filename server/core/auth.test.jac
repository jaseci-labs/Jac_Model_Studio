"""studio - unit tests for auth.sv.jac local-mode flag.

local_mode() drives the client auth gate: True (start.sh sets JAC_LOCAL_USER)
auto-provisions a local session, False (start_prod.sh) shows the login screen.
Annex file — pairs with auth.sv.jac. Run with `jac test server/core/auth.test.jac`.
"""

import os;

test "local_mode is True when JAC_LOCAL_USER is set" {
    os.environ["JAC_LOCAL_USER"] = "1";
    assert local_mode();
    del os.environ["JAC_LOCAL_USER"];
}

test "local_mode is False when JAC_LOCAL_USER is unset (production)" {
    os.environ.pop("JAC_LOCAL_USER", None);
    assert not local_mode();
}

test "local_mode is False when JAC_LOCAL_USER is empty" {
    os.environ["JAC_LOCAL_USER"] = "";
    assert not local_mode();
    del os.environ["JAC_LOCAL_USER"];
}

test "local_mode is False for explicit off values like 0 / false / no" {
    # bool("0") is True: an operator writing JAC_LOCAL_USER=0 to DISABLE local
    # mode turned on local_session() — a passwordless token for a fixed user.
    for v in ["0", "false", "False", "no", "off", " "] {
        os.environ["JAC_LOCAL_USER"] = v;
        assert not local_mode(), v;
    }
    for v in ["1", "true", "yes", "on"] {
        os.environ["JAC_LOCAL_USER"] = v;
        assert local_mode(), v;
    }
    del os.environ["JAC_LOCAL_USER"];
}
