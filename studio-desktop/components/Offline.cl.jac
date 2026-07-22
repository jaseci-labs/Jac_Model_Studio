"""Backend-offline card — ports ui/components/offline.tsx.

Purely presentational: a dashed status card shown by AppShell when the online
probe fails. AppShell owns the retry-every-3s loop and swaps this out the moment
the backend answers again."""

def:pub Offline -> JsxElement {
    return <div className="flex h-screen items-center justify-center">
        <div className="exp-panel !border-dashed p-8 text-center">
            <div className="micro-label mb-3">JAC.STUDIO · STATUS</div>
            <p className="exp-display text-2xl">backend offline</p>
            <p className="mt-2 font-mono text-xs text-muted-foreground">
                start it with: <span className="text-foreground/80">./start.sh</span>
            </p>
            <p className="mt-4 font-mono text-[10px] text-muted-foreground/80">retrying every 3s…</p>
        </div>
    </div>;
}
