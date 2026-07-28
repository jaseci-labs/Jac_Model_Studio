"""Gallery — repo figures rendered verbatim. The experiments already save their
graphs (matplotlib pngs under results/); this browses those dirs and shows the
files as-is instead of re-deriving charts. Dir chips → image grid → click to
enlarge. `prefix` scopes the dir list to one workspace's artifacts."""

sv import from ...gallery { list_galleries, gallery_images }
import from .Chip { Chip }
import from .EmptyState { EmptyState }

def:pub Gallery(prefix: str = "") -> JsxElement {
    has dirs: list = [],
        selected: str = "",
        images: list = [],
        loading: bool = False,
        loadedOnce: bool = False,
        zoom: any = None;

    async def openDir(d: str) -> None {
        selected = d;
        loading = True;
        images = [];
        try {
            imgs = await gallery_images(rel_dir=d);
            images = list(imgs);
        } except Exception { }
        loading = False;
    }

    async can with entry {
        try {
            all = await list_galleries();
            mine: list = [];
            for g in all {
                if not prefix or str(g["dir"]).startswith(prefix) { mine.append(g); }
            }
            dirs = mine;
            if len(mine) > 0 {
                await openDir(str(mine[0]["dir"]));
            }
        } except Exception { }
        loadedOnce = True;
    }

    def _short(d: str) -> str {
        return d[len(prefix):].lstrip("/") if prefix and d.startswith(prefix) else d;
    }

    # `dirs` is empty on the very first render too (the mount fetch has not
    # resolved yet) — without loadedOnce this flashed "NO SAVED FIGURES" at
    # every mount before the real answer arrived.
    if len(dirs) == 0 {
        return <div className="relative exp-panel p-3 pt-4">
            <span className="micro-label absolute -top-2 left-3 bg-background px-2">FIGURES · from repo</span>
            {if not loadedOnce {
                <EmptyState key="pending" label="LOADING FIGURES" pulse={True} />
                skip;
            }}
            {if loadedOnce {
                <EmptyState key="empty" label="NO SAVED FIGURES" hint={"no image dirs under " + (prefix if prefix else "the artifact roots")} />
                skip;
            }}
        </div>;
    }

    return <div className="relative exp-panel p-3 pt-4">
        <span className="micro-label absolute -top-2 left-3 bg-background px-2">FIGURES · from repo · verbatim</span>
        <div className="mb-3 flex flex-wrap gap-1">
            {for g in dirs {
                <Chip
                    key={str(g["dir"])}
                    onClick={lambda (e: MouseEvent) { openDir(str(g["dir"])); }}
                    selected={selected == str(g["dir"])}
                    className="px-2 font-mono text-[10px]"
                >
                    {_short(str(g["dir"]))} · {str(g["count"])}
                </Chip>
            }}
        </div>
        {if loading {
            <EmptyState key="loading" label="LOADING FIGURES" pulse={True} />
            skip;
        }}
        {if not loading and len(images) > 0 {
            <div key="grid" className="grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-3">
                {for im in images {
                    <div key={str(im["name"])} className="flex flex-col gap-1">
                        {if str(im["b64"]) {
                            <img
                                key="img"
                                src={"data:" + str(im["mime"]) + ";base64," + str(im["b64"])}
                                alt={str(im["name"])}
                                title={str(im["name"]) + " · click to enlarge"}
                                role="button"
                                tabIndex={0}
                                onClick={lambda (e: MouseEvent) { zoom = im; }}
                                onKeyDown={lambda (e: KeyboardEvent) {
                                    if e.key == "Enter" or e.key == " " { e.preventDefault(); zoom = im; }
                                }}
                                style={{"background": "var(--surface-strong)"}}
                                className="exp-hoverable w-full cursor-zoom-in rounded-lg border border-border"
                            />
                            skip;
                        }}
                        {if not str(im["b64"]) {
                            <div key="stub" className="stat-line rounded-md border border-dashed border-input p-3">{str(im["name"])} · {str(im["note"])}</div>
                            skip;
                        }}
                        <span className="stat-line truncate">{str(im["name"])}</span>
                    </div>
                }}
            </div>
            skip;
        }}
        <div className="stat-line mt-3 text-muted-foreground/70">source: {selected} · rendered exactly as saved by the training/eval scripts</div>
        {zoom and <div
            role="button"
            tabIndex={0}
            aria-label="close figure"
            onClick={lambda (e: MouseEvent) { zoom = None; }}
            onKeyDown={lambda (e: KeyboardEvent) {
                if e.key == "Enter" or e.key == " " or e.key == "Escape" { e.preventDefault(); zoom = None; }
            }}
            className="fixed inset-0 z-50 flex cursor-zoom-out items-center justify-center bg-background/90 p-8"
        >
            <div className="flex max-h-full max-w-5xl flex-col gap-2">
                <img src={"data:" + str(zoom["mime"]) + ";base64," + str(zoom["b64"])} alt={str(zoom["name"])} style={{"background": "var(--surface-strong)"}} className="max-h-[85vh] w-auto rounded-md border border-border object-contain" />
                <span className="stat-line text-center">{str(zoom["name"])} · click anywhere to close</span>
            </div>
        </div>}
    </div>;
}
