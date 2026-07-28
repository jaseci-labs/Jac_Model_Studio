"""studio - self-check for jms_workspaces.sv.jac (lean JMS workspace model).

Run with `JAC_LOCAL_USER=1 jac run check_jms_workspaces.jac` from jms/.
Exercises the seed -> list -> create -> update -> delete round trip against
the real per-user graph (root ++> JmsWorkspace) through the public endpoints
only (seeding happens implicitly inside `jms_ui_layout`, same as
workspace.sv.jac's `ui_layout` seeds `Workspace`). Prints OK on success.
"""

import from jms_workspaces {
    jms_ui_layout, create_jms_workspace, update_jms_workspace,
    delete_jms_workspace, reorder_jms_workspaces
}

with entry {
    layout = jms_ui_layout();
    assert len(layout["workspaces"]) >= 1, layout;
    base_count = len(layout["workspaces"]);
    base_ids = list(layout["workspace_ids"]);

    after_create = create_jms_workspace("Test WS", "ws02");
    assert len(after_create["workspaces"]) == base_count + 1, after_create;
    new_ids = [i for i in list(after_create["workspace_ids"]) if i not in base_ids];
    assert len(new_ids) == 1, new_ids;
    new_id = str(new_ids[0]);

    after_update = update_jms_workspace(new_id, "Renamed WS", "ws03");
    found = False;
    for w in after_update["workspaces"] {
        if w.id == new_id {
            assert w.label == "Renamed WS", w.label;
            assert w.accent == "ws03", w.accent;
            found = True;
        }
    }
    assert found, "updated workspace present in refreshed layout";

    # reorder is a no-op safety check: pushing the new workspace to the front
    # should not change the total count.
    reordered = reorder_jms_workspaces([new_id] + base_ids);
    assert len(reordered["workspaces"]) == base_count + 1, reordered;

    after_delete = delete_jms_workspace(new_id);
    assert len(after_delete["workspaces"]) == base_count, after_delete;
    remaining_ids = list(after_delete["workspace_ids"]);
    assert new_id not in remaining_ids, remaining_ids;

    print("OK");
}
