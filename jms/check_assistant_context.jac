"""studio - self-check for assistant.sv.jac (Task A2: full-app-state context
bundle).

Run with `JAC_LOCAL_USER=1 jac run check_assistant_context.jac` from jms/.
Creates a throwaway JMS project so the PROJECTS section has real data to show,
asserts `assistant_context()` returns a non-empty str under the
`_MAX_GROUND_CHARS` cap (~31000 to allow for the "…(truncated)" marker),
containing the WORKSPACES section header, the seeded JMS "MAIN" workspace,
and the throwaway project's name — then prints the first 800 chars so the
digest shape is visible in the run output, and cleans up the project.
"""

import from assistant { assistant_context }
import from jms_projects { create_project, delete_project }

with entry {
    pv = create_project("Assistant Ctx Probe", "coding-agent");

    digest = assistant_context();
    assert isinstance(digest, str), "assistant_context() must return a str";
    assert len(digest) > 0, "digest is empty";
    assert len(digest) < 31000, f"digest too large: {len(digest)} chars";
    assert "WORKSPACES" in digest, "no WORKSPACES section header in digest";
    assert "MAIN" in digest, "seeded JMS workspace 'MAIN' missing from digest";
    assert pv.name in digest, "throwaway project name missing from digest";

    print(digest[:800]);
    print("...");
    print(f"digest length: {len(digest)} chars");

    delete_project(pv.pid, False);
    print("OK");
}
