"use client";
import { useEffect, useLayoutEffect, useRef } from "react";

export function usePoll(fn: () => void | Promise<void>, ms: number, active: boolean) {
  const fnRef = useRef(fn);
  useLayoutEffect(() => { fnRef.current = fn; });
  useEffect(() => {
    if (!active) return;
    let stopped = false;
    const run = () => { if (!stopped && document.visibilityState !== "hidden") void fnRef.current(); };
    run();
    const t = setInterval(run, ms);
    const onVis = () => { if (document.visibilityState === "visible") run(); };
    document.addEventListener("visibilitychange", onVis);
    return () => { stopped = true; clearInterval(t); document.removeEventListener("visibilitychange", onVis); };
  }, [ms, active]);
}
