"""Top-level shell: glass nav bar + client routes (Monitor / Train / Ingest)."""

import from "@jac/runtime" { Router, Routes, Route, Navigate, Link, useLocation }
import from .MonitorPage { MonitorPage }
import from .HistoryPage { HistoryPage }
import from .TrainPage { TrainPage }
import from .IngestPage { IngestPage }
import from .DatasetPage { DatasetPage }

def:pub NavLink(dest: str, label: str, path: str) -> JsxElement {
    return <Link to={dest} className={"dg-navlink dg-active" if path == dest else "dg-navlink"}>{label}</Link>;
}

def:pub NavBar() -> JsxElement {
    path: str = str(useLocation()["pathname"]);
    return <nav className="dg-nav">
        <span className="dg-brand"><span className="dg-brand-dot"></span>DataGen</span>
        <NavLink dest="/monitor" label="Monitor" path={path} />
        <NavLink dest="/history" label="History" path={path} />
        <NavLink dest="/train" label="Train" path={path} />
        <NavLink dest="/ingest" label="Ingest" path={path} />
        <NavLink dest="/dataset" label="Dataset" path={path} />
        <span className="dg-spacer"></span>
        <span className="dg-faint">local · mlx</span>
    </nav>;
}

def:pub AppShell() -> JsxElement {
    return <Router>
        <div className="dg-app">
            <NavBar />
            <Routes>
                <Route path="/" element={<Navigate to="/monitor" replace={True} />} />
                <Route path="/monitor" element={<MonitorPage />} />
                <Route path="/history" element={<HistoryPage />} />
                <Route path="/train" element={<TrainPage />} />
                <Route path="/ingest" element={<IngestPage />} />
                <Route path="/dataset" element={<DatasetPage />} />
            </Routes>
        </div>
    </Router>;
}
