export function Offline() {
  return (
    <div className="flex h-screen items-center justify-center">
      <div className="rounded-lg border border-dashed border-neutral-700 bg-[#0d0d0d] p-8 text-center">
        <div className="micro-label mb-3">JAC.STUDIO — STATUS</div>
        <p className="text-lg text-neutral-200">backend offline</p>
        <p className="mt-2 font-mono text-xs text-neutral-500">
          start it with: <span className="text-neutral-300">./web_app/start.sh</span>
        </p>
        <p className="mt-4 font-mono text-[10px] text-neutral-600">retrying every 3s…</p>
      </div>
    </div>
  );
}
