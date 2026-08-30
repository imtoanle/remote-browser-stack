# Superpowers engineering records

Files under this directory are design and execution records captured while the initial stack was developed with the Superpowers workflow.

They are **historical engineering artifacts, not a live project-management checklist**. Individual `- [ ]` markers preserve the original execution plan and should not be interpreted as currently open work after the corresponding implementation has landed.

For current project behavior, use these sources in order:

1. `README.md` — supported deployment and operator workflow.
2. `docs/security.md` — current security model and invariants.
3. `.github/workflows/ci.yml` and `tests/` — executable verification contract.
4. the latest pull-request head and its CI status — completion evidence.

Historical specs are useful for understanding why architectural choices were made, including the move from Debian Chromium to Google Chrome Stable and the evolution of the browser sandbox policy.
