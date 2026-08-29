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
        Before final routing, run Auto-land route classification with the current workflow policy,
        issue labels, validation evidence, PR checks, structured PR feedback sweep, automated review result, and
        sync result.

        Record structured completion evidence for the handoff route classifier: validation checks,
        quality gates, scenario QA or blocked human-verification notes when relevant, product visual
        review evidence when selected, automated review, structured PR feedback sweep, route
        classification, sync evidence, issue labels, changed_files or change_manifest.changed_files,
        and any project-specific required auto-land checks. Changed file paths must be relative,
        normalized workspace paths; host validation rejects absolute paths, traversal, symlink escapes,
        generated runtime state, caches, logs, temporary app data, local secret files, and
        operator-local config. Record the selected handoff route in the workpad. When a PR exists, also
        record the decision in a PR handoff comment or existing PR handoff location.

        Treat dry-run auto-land as a visibility route: record that Symphony selected dry-run
        auto-land, move the issue to Human Review for visibility, and do not merge. Treat real
        auto-land as guarded landing only when the project explicitly sets `auto_land.dry_run: false`
        and all required evidence is present; route the issue to Merging so the existing land flow
        performs final check/review polling and the merge. If the decision selects human_review,
        rework, or blocked, move the issue to the selected state after recording diagnostics.
        """,
        description: "Guarded auto-land classification before final ticket routing"
      },
      %{
        id: "land-merge",
        version: "v1",
        summary: "Approved PR landing and merge loop.",
        default?: true,
        compatibility: compatibility,
        pins: %{registry: registry_pin, module: "land-merge@v1"},
        config: %{},
        prompt_sections: [],
        content: """
        When the issue reaches Merging, locate the attached PR, confirm local validation is green, and
        inspect mergeability. If the PR conflicts with the delivery target, sync, resolve conflicts,
        revalidate, and push the update.

        Poll checks and review feedback until all blocking signals are clear. If checks fail, inspect
        logs, fix the issue, commit, push, and restart the watch. Merge only when checks are green,
        actionable feedback is resolved, and the target policy allows the merge. After merge, move the
        issue to Done.
        """,
        description: "Approved PR landing and merge loop"
      }
    ]
  end
end
