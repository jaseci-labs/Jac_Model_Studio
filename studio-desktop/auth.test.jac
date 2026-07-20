"""studio - unit tests for auth.sv.jac local-mode flag.

local_mode() drives the client auth gate: True (start.sh sets JAC_LOCAL_USER)
auto-provisions a local session, False (start_prod.sh) shows the login screen.
Annex file — pairs with auth.sv.jac. Run with `jac test auth.sv.jac`.
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
