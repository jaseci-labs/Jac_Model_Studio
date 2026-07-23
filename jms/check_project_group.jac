import from jms_projects { create_project, list_projects, delete_project, update_project }
with entry {
    a = create_project("b2-test-a", "uc", "g1");
    b = create_project("b2-test-b", "uc", "");
    g1 = list_projects("g1");
    allp = list_projects("");
    none = list_projects("nope");
    assert any([str(x.group_id) == "g1" for x in g1]), "g1 filter";
    assert all([str(x.group_id) == "g1" for x in g1]), "g1 only";
    assert len(allp) >= 2, "all >= 2";
    assert len(none) == 0, "nope empty";
    assert str(a.group_id) == "g1", "view carries group_id";
    # cleanup
    delete_project(a.pid, False);
    delete_project(b.pid, False);
    print("B2 CHECK OK");
}
