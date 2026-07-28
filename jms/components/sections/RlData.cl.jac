"""DATA section (workspace 02 RL/GRPO) — read-only RL training-data browser.

Ports the RL half of the old blended Data section: the SFT gold / GRPO reward-task
/ python→jac / synthetic / splits sources (02-rl-grpo/dataset/…, via
rl_dataset_files/rl_dataset_rows in data.sv.jac) rendered through the shared
RowBrowser. No pipeline/add-examples here — those are 01-only.
"""

sv import from ...data { rl_sources, rl_dataset_files, rl_dataset_rows, FileRefView, DataRowView }
import from ..shared.Field { Segmented }
import from ..shared.RowBrowser { RowBrowser }

# The source picker list is fetched from the server (data.rl_sources, backed by
# studio.workspace.toml) on mount — no client-side duplicate of the source axis.

def:pub RlData -> JsxElement {
    has rlSource: str = "SFT",
        files: list = [],
        path: str = "",
        rows: list = [],
        offset: int = 0,
        total: int = 0,
        expanded: int = -1,
        sources: list = [],
        loadErr: str = "";

    # `src`/`p`/`off` passed explicitly — reading state right after setting it
    # returns the stale value (React writes are async).
    async def _fetch(src: str, p: str, off: int) -> None {
        try {
            r = await rl_dataset_rows(src, p, off, 25);
            rows = list(r["rows"]);
            total = int(r["total"]);
        } except Exception as e {
            rows = []; total = 0;
            loadErr = "rows failed · " + str(e);
        }
    }

    async def _loadSource(src: str) -> None {
        try {
            fs = await rl_dataset_files(src);
            files = fs;
            expanded = -1;
            offset = 0;
            if len(list(fs)) > 0 {
                path = str(fs[0].path);
                await _fetch(src, str(fs[0].path), 0);
            } else {
                path = ""; rows = []; total = 0;
            }
        } except Exception as e {
            files = []; path = ""; rows = []; total = 0;
            loadErr = "file list failed · " + str(e);
        }
    }

    async def switchSource(s: str) -> None {
        rlSource = s;
        await _loadSource(s);
    }

    async def openFile(p: str) -> None {
        path = p;
        offset = 0;
        expanded = -1;
        await _fetch(rlSource, p, 0);
    }

    def toggleRow(idx: int) -> None {
        expanded = -1 if expanded == idx else idx;
    }

    async def prevPage -> None {
        if offset > 0 {
            noff = max(0, offset - 25);
            offset = noff;
            expanded = -1;
            await _fetch(rlSource, path, noff);
        }
    }

    async def nextPage -> None {
        if offset + len(rows) < total {
            noff = offset + 25;
            offset = noff;
            expanded = -1;
            await _fetch(rlSource, path, noff);
        }
    }

    async can with entry {
        try {
            # Locals, not the `has` fields: a `has` write lowers to a useState
            # setter, so reading `sources`/`rlSource` back on the next line
            # returned the pre-update closure value (jac check W3041) and the
            # server's first source was never selected.
            srcs = await rl_sources();
            sources = srcs;
            pick = rlSource;
            if len(list(srcs)) > 0 {
                pick = str(srcs[0]);
                rlSource = pick;
            }
            await _loadSource(pick);
        } except Exception as e {
            # Un-.catch()ed before: the rejection vanished and the browser sat
            # on an empty file list that looked like a slow load.
            loadErr = "RL dataset failed to load · " + str(e);
        }
    }

    return <div className="flex h-full min-w-0 flex-1 flex-col">
        <div className="flex items-center justify-between border-b border-border px-4 py-2.5">
            <span className="micro-label">DATA · RL TRAINING SETS (read-only)</span>
            <span className="micro-label text-muted-foreground/80">02-rl-grpo/dataset</span>
        </div>
        {loadErr and <div key="rlerr" className="border-b border-border px-4 py-1.5">
            <span className="stat-line" style={{"color": "var(--danger)"}}>{loadErr}</span>
        </div>}
        <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4">
            <div className="flex flex-wrap items-center gap-2">
                <span className="micro-label text-muted-foreground/80">SOURCE</span>
                <Segmented options={sources} value={rlSource} onSet={lambda (v: str) { switchSource(v); }} />
            </div>
            <div className="stat-line text-muted-foreground/80">RL training data (read-only) — SFT gold · GRPO reward tasks · python→jac · synthetic · splits. See RL_FINDINGS.md.</div>
            <RowBrowser
                files={files} path={path} rows={rows} offset={offset}
                total={total} expanded={expanded}
                onOpen={openFile} onToggle={toggleRow}
                onPrev={prevPage} onNext={nextPage}
            />
        </div>
    </div>;
}
