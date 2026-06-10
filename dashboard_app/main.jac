"""DataGeneration training dashboard - entry point.

Server endpoints are registered here (the plain `import from services.*`
blocks); the client UI mounts from the `cl { }` block. Adding any new .sv.jac
endpoint means adding its functions + obj types to a registry import below.
"""

import from services.runs { RunSummary, RunMetrics, CompareResult, list_runs, get_run_metrics, compare_runs }
import from services.jobs { JobStatus, Session, start_training, stop_training, job_status, run_builder, builder_status, list_sessions }
import from services.dataset { DatasetStats, FileStat, FileRef, DataRow, dataset_stats, list_dataset_files, sample_rows, add_examples, dataset_rows }

cl {
    import "./global.css";
    import from .components.AppShell { AppShell }

    def:pub app() -> JsxElement {
        return <AppShell />;
    }
}
