defmodule SymphonyElixir.Workflow.LandingAuthority do
  @moduledoc false

  @spec modules(map(), String.t()) :: [map()]
  def modules(compatibility, registry_pin) when is_map(compatibility) and is_binary(registry_pin) do
    [
      %{
        id: "auto-land-routing",
        version: "v1",
        summary: "Guarded auto-land classification before final ticket routing.",
        default?: true,
        compatibility: compatibility,
        pins: %{registry: registry_pin, module: "auto-land-routing@v1"},
        config: %{},
        prompt_sections: [],
        content: """
        Before final handoff, record structured completion evidence for host-side Auto-land route classification:
        validation checks, quality gates, scenario QA or blocked human-verification notes when relevant, product
        visual review, automated review, existing-PR feedback, sync state, issue labels, and changed_files or
        change_manifest.changed_files.

        Changed file paths must be relative, normalized workspace paths. Host validation rejects absolute paths,
        traversal, symlink escapes, generated runtime state, caches, logs, temporary app data, local secret
        files, and operator-local config.

        The host validates the evidence, publishes and links the pull request, records the final route, and ends
        the implementation worker. For dry-run auto-land, it moves the issue to Human Review. For real auto-land,
        it moves the issue to Merging after the implementation worker stops, so the host can dispatch a fresh
        landing worker. The implementation worker must not change the issue to Merging or perform delivery writes.
        """,
        description: "Host-side auto-land classification and dedicated landing dispatch"
      },
      %{
        id: "land-merge",
        version: "v1",
        summary: "Dedicated approved PR landing worker.",
        default?: true,
        compatibility: compatibility,
        pins: %{registry: registry_pin, module: "land-merge@v1"},
        config: %{},
        prompt_sections: [],
        content: """
        Run this module only when the prompt's `Current status` is `Merging`. The host dispatches this dedicated
        landing worker only after it has published and linked the implementation pull request. Locate that
        existing pull request and branch. Do not create a new branch, bookmark, or pull request.

        Confirm that the pinned merge gate permits landing. Inspect mergeability, required checks, and all
        review feedback. If the pull request conflicts with the delivery target, sync the existing branch,
        resolve conflicts, revalidate, and push that branch.

        Poll checks and review feedback until all blocking signals are clear. Merge only when checks are green,
        actionable feedback is resolved, and target policy still allows the merge. After merge, move the issue
        to Done. If any gate cannot pass, record the blocker and leave the issue in Merging.
        """,
        description: "Dedicated approved PR landing worker"
      }
    ]
  end
end
