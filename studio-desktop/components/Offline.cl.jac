"""Backend-offline card — ports ui/components/offline.tsx.

Purely presentational: a dashed status card shown by AppShell when the online
probe fails. AppShell owns the retry-every-3s loop and swaps this out the moment
the backend answers again."""

def:pub Offline -> JsxElement {
    return <div className="flex h-screen items-center justify-center">
        <div className="rounded-lg border border-dashed border-neutral-700 bg-[#0d0d0d] p-8 text-center">
            <div className="micro-label mb-3">JAC.STUDIO · STATUS</div>
            <p className="text-lg text-neutral-200">backend offline</p>
            <p className="mt-2 font-mono text-xs text-neutral-500">
                start it with: <span className="text-neutral-300">./start.sh</span>
            </p>
            <p className="mt-4 font-mono text-[10px] text-neutral-600">retrying every 3s…</p>
        </div>
    </div>;
}
