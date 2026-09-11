# Jac Model Studio

| Folder | What |
|---|---|
| [`jms/`](jms/README.md) | Jac ML Studio, the fullstack Jac app for dataset, train, and eval workflows |

The fine-tuning experiments (datasets, adapters, SFT playbook) live in their own repo,
[jaseci-labs/Jac_Model_Experiments](https://github.com/jaseci-labs/Jac_Model_Experiments).
`jms/studio.workspace.toml` expects it checked out next to this repo, as `../model-experiments`:

    git clone https://github.com/jaseci-labs/Jac_Model_Experiments.git ../model-experiments

Without it, JMS still runs, but registry models show as unavailable and datasets count 0.
