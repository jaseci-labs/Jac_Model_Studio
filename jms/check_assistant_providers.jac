"""studio - self-check for assistant.sv.jac (OpenAI key support + unified
provider listing).

Run with `JAC_LOCAL_USER=1 jac run check_assistant_providers.jac` from jms/.
Exercises assistant_providers() shape (mlx/claude/openai) and the OpenAI key
set/clear round trip (resolved_openai_key is server-internal so it is only
asserted in-process here, never returned by an endpoint). Prints OK on
success.
"""

import from assistant {
    assistant_providers, set_openai_key, clear_openai_key, resolved_openai_key
}

with entry {
    before = assistant_providers();
    providers = before["providers"];
    assert len(providers) == 3, providers;
    ids = [p["id"] for p in providers];
    assert "mlx" in ids, ids;
    assert "claude" in ids, ids;
    assert "openai" in ids, ids;

    openai_before = [p for p in providers if p["id"] == "openai"][0];
    assert openai_before["configured"] == False, openai_before;

    set_result = set_openai_key("sk-test123");
    assert set_result["ok"] == True, set_result;

    after = assistant_providers();
    openai_after = [p for p in after["providers"] if p["id"] == "openai"][0];
    assert openai_after["configured"] == True, openai_after;
    assert resolved_openai_key() == "sk-test123", resolved_openai_key();

    clear_result = clear_openai_key();
    assert clear_result["ok"] == True, clear_result;

    after_clear = assistant_providers();
    openai_cleared = [p for p in after_clear["providers"] if p["id"] == "openai"][0];
    assert openai_cleared["configured"] == False, openai_cleared;

    print("OK");
}
