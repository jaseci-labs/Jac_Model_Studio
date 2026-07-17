"""DATA section (workspace 02 RL/GRPO) — read-only RL training-data browser.

Ports the RL half of the old blended Data section: the SFT gold / GRPO reward-task
/ python→jac / synthetic / splits sources (02-rl-grpo/dataset/…, via
rl_dataset_files/rl_dataset_rows in data.sv.jac) rendered through the shared
RowBrowser. No pipeline/add-examples here — those are 01-only.
"""

sv import from ...data { rl_dataset_files, rl_dataset_rows, FileRefView, DataRowView }
import from ..shared.Field { Segmented }
import from ..shared.RowBrowser { RowBrowser }

glob RL_SOURCES: list[str] = ["SFT", "GRPO", "conversion", "synthetic", "splits"];

def:pub RlData -> JsxElement {
    has rlSource: str = "SFT",
        files: list = [],
        path: str = "",
        rows: list = [],
        offset: int = 0,
        total: int = 0,
        expanded: int = -1;

    # `src`/`p`/`off` passed explicitly — reading state right after setting it
    # returns the stale value (React writes are async).
    async def _fetch(src: str, p: str, off: int) -> None {
        r = await rl_dataset_rows(src, p, off, 25);
        rows = list(r["rows"]);
        total = int(r["total"]);
    }

    async def _loadSource(src: str) -> None {
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
        await _loadSource("SFT");
    }

    return <div className="flex h-full min-w-0 flex-1 flex-col">
        <div className="flex items-center justify-between border-b border-neutral-800 px-4 py-2.5">
            <span className="micro-label">DATA · RL TRAINING SETS (read-only)</span>
            <span className="micro-label text-neutral-600">02-rl-grpo/dataset</span>
        </div>
        <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4">
            <div className="flex flex-wrap items-center gap-2">
                <span className="micro-label text-neutral-600">SOURCE</span>
                <Segmented options={RL_SOURCES} value={rlSource} onSet={lambda v: str { switchSource(v); }} />
            </div>
            <div className="stat-line text-neutral-600">RL training data (read-only) — SFT gold · GRPO reward tasks · python→jac · synthetic · splits. See RL_FINDINGS.md.</div>
            <RowBrowser
                files={files} path={path} rows={rows} offset={offset}
                total={total} expanded={expanded}
                onOpen={openFile} onToggle={toggleRow}
                onPrev={prevPage} onNext={nextPage}
            />
        </div>
    </div>;
}
