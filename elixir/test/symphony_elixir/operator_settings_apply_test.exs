defmodule SymphonyElixir.OperatorSettingsApplyTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{
    ControlPlane,
    HostScheduler,
    OperatorInterface,
    OperatorSettings,
    TargetContext,
    TargetRouting
  }

  alias SymphonyElixir.HostScheduler.Registry
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Linear.MetadataCache
  alias SymphonyElixir.RunAuthority
  alias SymphonyElixir.TargetRegistry.Yaml

  @moduletag :tmp_dir
  @repo Path.expand("../fixtures/target_registry/repos/symphony", __DIR__)
  @issue %Issue{
    id: "issue-1",
    identifier: "SID-900",
    title: "Routing contract",
    state: "Todo",
    team_key: "ENG",
    project_id: "project-1",
    labels: []
  }

  setup %{tmp_dir: root} do
    {repo, policy} = SymphonyElixir.TestSupport.host_repository_fixture(root, @repo)
    path = Path.join([root, "registry", "targets.yml"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Yaml.encode(registry(root, repo, policy)))

    scheduler =
      start_supervised!({HostScheduler, name: unique_name(), registry_path: path, target_supervisor: false})

    control_plane = start_supervised!({ControlPlane, name: unique_name(), config_root: root})

    interface =
      start_supervised!({OperatorInterface, name: unique_name(), config_root: root, install_log_handler: false})

    {:ok, metadata} = OperatorInterface.credentials(interface)
    credential = File.read!(metadata.token_path)

    data = %{
      teams: [%{id: "eng", key: "ENG", name: "Engineering"}],
      projects: [%{id: "project-1", slug_id: "p1", name: "Routing", team_ids: ["eng"]}],
      states: [
        %{id: "todo", name: "Todo", type: "unstarted", team_id: "eng"},
        %{id: "done", name: "Done", type: "completed", team_id: "eng"}
      ],
      labels: []
    }

    cache =
      start_supervised!({MetadataCache, name: nil, fetch_fun: fn _ -> {:ok, data} end, env_fetcher: fn _ -> "fixture-key" end})

    await_metadata(cache, %{"id" => "linear-main", "policy" => registry(root, repo, policy)["host"]["tracker_connections"]["linear-main"]})

    opts = [host_scheduler: scheduler, control_plane: control_plane, config_root: root, metadata_cache: [server: cache]]

    {:ok, loaded} = Registry.load(path)

    %{
      scheduler: scheduler,
      control_plane: control_plane,
      interface: interface,
      credential: credential,
      opts: opts,
      path: path,
      repo: repo,
      policy: policy,
      target: loaded.contexts["alpha"],
      root: root
    }
  end

  describe "settings Apply creation" do
    test "creates a paused target and never activates work", context do
      command = %{"action" => "settings_apply", "target_id" => "beta", "inputs" => %{"selections" => creation_selections(context)}}

      {request, preview} = preview!(context, command)
      assert preview.identity.mode == "create"
      assert preview.disabled_reason == nil
      assert Enum.any?(preview.consequences, &String.contains?(&1, "as paused; activation is a separate preview and confirm"))
      assert preview.proposed_state.target["configured_state"] == "paused"

      result = confirm!(context, request, preview)
      assert result.status == "completed"
      assert result.result.mode == "create"
      assert result.result.committed? == true

      {:ok, document} = Yaml.decode(File.read!(context.path))
      created = document["targets"]["beta"]
      assert created["state"] == "paused"
      refute Map.has_key?(created, "dispatch_mode")
      assert created["linear"]["scope"]["project_id"] == "project-1"
      assert created["repo"]["expected_repository"] == context.policy["project"]["repository"]
    end

    test "derives repository identity from the host, not the client", context do
      command = %{
        "action" => "settings_apply",
        "target_id" => "beta",
        "inputs" => %{"repository" => context.repo, "selections" => Map.drop(creation_selections(context), ["repo.path"])}
      }

      {request, preview} = preview!(context, command)
      result = confirm!(context, request, preview)
      assert result.status == "completed"

      {:ok, document} = Yaml.decode(File.read!(context.path))

      assert document["targets"]["beta"]["repo"] == %{
               "path" => context.repo,
               "expected_repository" => context.policy["project"]["repository"]
             }
    end

    test "an unreadable repository blocks Apply instead of pinning an unverified identity", context do
      selections = put_in(creation_selections(context), ["repo.path"], Path.join(context.root, "missing-repo"))

      command = %{"action" => "settings_apply", "target_id" => "beta", "inputs" => %{"selections" => selections}}

      assert {:error, rejection} =
               OperatorInterface.preview(context.interface, context.credential, request(context, command), context.opts)

      assert rejection.error.code == "repository_not_ready"
    end

    test "lifecycle fields are never writable through settings", context do
      for {field, value} <- [{"state", "active"}, {"dispatch_mode", "watch"}] do
        command = %{
          "action" => "settings_apply",
          "target_id" => "alpha",
          "inputs" => %{"selections" => %{field => value}}
        }

        assert {:error, rejection} =
                 OperatorInterface.preview(context.interface, context.credential, request(context, command), context.opts)

        assert rejection.error.code == "settings_field_not_editable"
        assert rejection.error.message =~ "not editable"
      end
    end

    test "creation dispatch_mode selections are rejected because Add drops them", context do
      command = %{
        "action" => "settings_apply",
        "target_id" => "beta",
        "inputs" => %{"selections" => Map.put(creation_selections(context), "dispatch_mode", "watch")}
      }

      assert {:error, rejection} =
               OperatorInterface.preview(context.interface, context.credential, request(context, command), context.opts)

      assert rejection.error.code == "settings_field_not_editable"
    end

    test "a repository input conflicting with the repo.path selection fails Apply", context do
      command = %{
        "action" => "settings_apply",
        "target_id" => "beta",
        "inputs" => %{
          "repository" => Path.join(context.root, "other-repo"),
          "selections" => creation_selections(context)
        }
      }

      assert {:error, rejection} =
               OperatorInterface.preview(context.interface, context.credential, request(context, command), context.opts)

      assert rejection.error.code == "invalid_settings_apply"
    end

    test "a selections-only repository path derives the host identity for creation", context do
      command = %{
        "action" => "settings_apply",
        "target_id" => "beta",
        "inputs" => %{"selections" => creation_selections(context)}
      }

      {request, preview} = preview!(context, command)
      result = confirm!(context, request, preview)
      assert result.status == "completed"

      {:ok, document} = Yaml.decode(File.read!(context.path))

      assert document["targets"]["beta"]["repo"] == %{
               "path" => context.repo,
               "expected_repository" => context.policy["project"]["repository"]
             }
    end

    test "creation selections for state are rejected because Apply always pauses", context do
      command = %{
        "action" => "settings_apply",
        "target_id" => "beta",
        "inputs" => %{"selections" => Map.put(creation_selections(context), "state", "active")}
      }

      assert {:error, rejection} =
               OperatorInterface.preview(context.interface, context.credential, request(context, command), context.opts)

      assert rejection.error.code == "settings_field_not_editable"
    end

    test "a target named host can be created and edited without changing shared settings", context do
      {:ok, before_document} = Yaml.decode(File.read!(context.path))

      command = %{
        "action" => "settings_apply",
        "target_id" => "host",
        "inputs" => %{"selections" => creation_selections(context)}
      }

      {request, preview} = preview!(context, command)
      assert preview.identity.mode == "create"
      result = confirm!(context, request, preview)
      assert result.status == "completed"
      assert result.result.settings.values["display_name"] == "Beta"

      command = put_in(command, ["inputs", "selections"], %{"display_name" => "Host target"})
      {request, preview} = preview!(context, command)
      assert preview.identity.mode == "update"
      result = confirm!(context, request, preview)
      assert result.status == "completed"
      assert result.result.settings.values["display_name"] == "Host target"

      {:ok, document} = Yaml.decode(File.read!(context.path))
      assert document["targets"]["host"]["display_name"] == "Host target"
      assert document["targets"]["host"]["state"] == "paused"
      assert document["host"] == before_document["host"]
    end

    test "runner tuning fields derive concrete IDs from the host runner catalog", context do
      catalog = OperatorSettings.build(context.scheduler, %{"target_id" => "beta", "selections" => %{}}, context.opts)

      reasoning = catalog.fields["runners.settings.existing.reasoning_effort"]
      assert reasoning.editable == true
      assert reasoning.type == "choice"
      assert Enum.map(reasoning.choices, & &1.value) == ["minimal", "low", "medium", "high", "xhigh"]

      assert catalog.fields["runners.settings.existing.max_turns"].type == "positive_integer"
    end
  end

  describe "settings Apply updates" do
    test "saves settings with old and new values, sources, and authoritative readback", context do
      command = %{
        "action" => "settings_apply",
        "target_id" => "alpha",
        "inputs" => %{
          "selections" => %{
            "concurrency.max_concurrent_agents" => 1,
            "runners.settings.existing.reasoning_effort" => "xhigh"
          }
        }
      }

      {request, preview} = preview!(context, command)
      assert preview.identity.mode == "update"
      assert Enum.any?(preview.consequences, &String.contains?(&1, "2 -> 1"))
      assert Enum.any?(preview.consequences, &String.contains?(&1, "lifecycle state does not change"))
      assert Enum.any?(preview.consequences, &String.contains?(&1, "pinned admission policy"))
      assert preview.proposed_state.settings.affected_targets == ["alpha"]

      result = confirm!(context, request, preview)
      assert result.status == "completed"
      assert result.result.mode == "update"
      assert result.result.settings.values["concurrency.max_concurrent_agents"] == 1
      assert result.result.settings.values["runners.settings.existing.reasoning_effort"] == "xhigh"
      assert result.result.settings.revisions["registry"] == HostScheduler.snapshot(context.scheduler).registry.generation

      catalog = OperatorSettings.build(context.scheduler, %{"target_id" => "alpha"}, context.opts)
      assert catalog.fields["concurrency.max_concurrent_agents"].selected == 1
      assert catalog.fields["concurrency.max_concurrent_agents"].source == "target"
    end

    test "runner tuning previews and reads back the inherited host value after clearing an override", context do
      field = "runners.settings.existing.model"
      {:ok, document} = Yaml.decode(File.read!(context.path))
      document = put_in(document, ["host", "runners", "existing", "model"], "host-model")
      File.write!(context.path, Yaml.encode(document))
      assert {:ok, _} = HostScheduler.reload(context.scheduler)

      catalog = OperatorSettings.build(context.scheduler, %{"target_id" => "alpha"}, context.opts)
      assert catalog.fields[field].current == nil
      assert catalog.fields[field].inherited == "host-model"
      assert catalog.fields[field].effective == "host-model"
      assert catalog.fields[field].source == "host"

      command = %{
        "action" => "settings_apply",
        "target_id" => "alpha",
        "inputs" => %{"selections" => %{field => "target-model"}}
      }

      {request, preview} = preview!(context, command)
      assert preview.proposed_state.settings.values[field] == "target-model"
      result = confirm!(context, request, preview)
      assert result.status == "completed"
      assert result.result.settings.values[field] == "target-model"

      catalog = OperatorSettings.build(context.scheduler, %{"target_id" => "alpha"}, context.opts)
      assert catalog.fields[field].current == "target-model"
      assert catalog.fields[field].inherited == "host-model"
      assert catalog.fields[field].source == "target"

      command = put_in(command, ["inputs", "selections", field], nil)
      {request, preview} = preview!(context, command)
      assert preview.proposed_state.settings.values[field] == "host-model"
      result = confirm!(context, request, preview)
      assert result.status == "completed"
      assert result.result.settings.values[field] == "host-model"

      {:ok, loaded} = Registry.load(context.path)

      assert loaded.contexts["alpha"].runner_policy["runners"]["existing"]["model"] ==
               result.result.settings.values[field]

      catalog = OperatorSettings.build(context.scheduler, %{"target_id" => "alpha"}, context.opts)
      assert catalog.fields[field].current == nil
      assert catalog.fields[field].source == "host"
    end

    test "editable-field metadata describes scope, type, provenance, revision, and editability", context do
      catalog = OperatorSettings.build(context.scheduler, %{"target_id" => "alpha"}, context.opts)

      concurrency = catalog.fields["concurrency.max_concurrent_agents"]
      assert concurrency.scope == "target"
      assert concurrency.type == "positive_integer"
      assert concurrency.editable == true
      assert concurrency.source == "target"
      assert concurrency.current == 2
      assert concurrency.effective == 2
      assert concurrency.inherited == nil
      assert concurrency.revision["registry"] == catalog.revisions["registry"]

      state = catalog.fields["state"]
      assert state.editable == false
      assert state.disabled_reason == "lifecycle_command_required"

      dispatch = catalog.fields["dispatch_mode"]
      assert dispatch.editable == false
      assert dispatch.disabled_reason == "lifecycle_command_required"

      host_field = catalog.fields["host.scheduling.algorithm"]
      assert host_field.scope == "host"
      assert host_field.editable == false
      assert host_field.disabled_reason == "host_field_read_only"

      profile = catalog.fields["repository_profile"]
      assert profile.scope == "target"
      assert profile.source == nil

      # Repository policy fields resolve through the shared layers with
      # per-field source; alpha inherits every policy leaf from host defaults.
      posture = catalog.fields["repository_policy.auto_land.posture"]
      assert posture.scope == "target"
      assert posture.editable == true
      assert posture.type == "choice"
      assert Enum.map(posture.choices, & &1.value) == ["off", "permissive", "strict"]
      assert posture.source == "host"
      assert posture.current == nil
      assert posture.inherited == "permissive"
      assert posture.effective == "permissive"

      linear_field = catalog.fields["linear.active_states"]
      assert linear_field.revision["linear"] == catalog.revisions["linear"]

      draft = OperatorSettings.build(context.scheduler, %{"selections" => %{"concurrency.max_concurrent_agents" => 3}}, context.opts)
      assert draft.fields["concurrency.max_concurrent_agents"].source == "selection"
    end

    test "open values carry explicit host-owned validation", context do
      for {path, value, reason} <- [
            {"concurrency.max_concurrent_agents", 0, "invalid_value"},
            {"worktree.root", "relative/path", "invalid_value"},
            {"linear.scope.issue_ids", ["", "SID-1"], "invalid_value"}
          ] do
        catalog =
          OperatorSettings.build(
            context.scheduler,
            %{"target_id" => "alpha", "selections" => %{path => value}},
            context.opts
          )

        assert catalog.apply_blocked
        assert catalog.fields[path].reason == reason
        assert [%{field: ^path, reason: ^reason}] = catalog.errors
      end
    end

    test "pinned active runs keep their admitted policy after a settings Apply", context do
      {:ok, authority} = admit_active_run!(context, @issue)
      pinned_hash = authority.admission.context.target.policy_hash

      command = %{
        "action" => "settings_apply",
        "target_id" => "alpha",
        "inputs" => %{"selections" => %{"concurrency.max_concurrent_agents" => 1}}
      }

      {request, preview} = preview!(context, command)
      assert confirm!(context, request, preview).status == "completed"

      {:ok, refreshed} = ControlPlane.fetch_admission(context.control_plane, "alpha", @issue.id)
      assert refreshed.context.target.policy_hash == pinned_hash

      {:ok, reloaded} = Registry.load(context.path)
      refute reloaded.contexts["alpha"].policy_hash == pinned_hash
    end
  end

  describe "shared host repository policy edits" do
    test "the host catalog exposes editable shared layers with provenance", context do
      catalog = OperatorSettings.build(context.scheduler, %{"scope" => "host"}, context.opts)

      refute catalog.apply_blocked
      assert catalog.revisions["registry"] == HostScheduler.snapshot(context.scheduler).registry.generation

      posture = catalog.fields["host.repository_defaults.auto_land.posture"]
      assert posture.scope == "host"
      assert posture.editable == true
      assert posture.type == "choice"
      assert posture.source == "host"
      assert posture.current == "permissive"
      assert posture.effective == "permissive"
      assert Enum.map(posture.choices, & &1.value) == ["off", "permissive", "strict"]
      assert posture.revision["registry"] == catalog.revisions["registry"]

      # Target paths are not part of the host catalog and fail closed.
      selection_catalog =
        OperatorSettings.build(
          context.scheduler,
          %{"scope" => "host", "selections" => %{"state" => "paused"}},
          context.opts
        )

      assert selection_catalog.apply_blocked
      assert [%{field: "state", reason: "unknown_field"}] = selection_catalog.errors
    end

    test "workflow presets and shared modules expose finite choices and retain invalid selections", context do
      for {request, prefix} <- [
            {%{"target_id" => "alpha"}, "repository_policy."},
            {%{"scope" => "host"}, "host.repository_defaults."}
          ] do
        preset = prefix <> "workflow.preset"
        modules = prefix <> "workflow.modules"
        selections = %{preset => "missing-preset", modules => ["missing-module"]}
        catalog = OperatorSettings.build(context.scheduler, Map.put(request, "selections", selections), context.opts)

        assert catalog.apply_blocked
        assert catalog.fields[preset].type == "choice"
        assert catalog.fields[preset].cardinality == "scalar"
        assert catalog.fields[modules].type == "choice"
        assert catalog.fields[modules].cardinality == "list"
        refute catalog.fields[preset].valid
        refute catalog.fields[modules].valid

        assert Enum.any?(catalog.fields[preset].choices, &(&1.value == "default" and &1.status == "available"))

        assert Enum.any?(
                 catalog.fields[preset].choices,
                 &(&1.value == "missing-preset" and &1.selected and &1.status == "stale" and &1.reason == "selection_removed")
               )

        assert Enum.any?(
                 catalog.fields[modules].choices,
                 &(&1.value == "missing-module" and &1.selected and &1.status == "stale" and &1.reason == "selection_removed")
               )
      end
    end

    test "a draft profile selection is discoverable before the profile exists", context do
      catalog =
        OperatorSettings.build(
          context.scheduler,
          %{
            "scope" => "host",
            "selections" => %{"host.repository_profiles.release.auto_land.posture" => "strict"}
          },
          context.opts
        )

      refute catalog.apply_blocked
      assert catalog.fields["host.repository_profiles.release.auto_land.posture"].editable
      assert catalog.fields["host.repository_profiles.release.auto_land.posture"].source == "selection"
    end

    test "Apply previews every affected target with old and new effective values", context do
      command = %{
        "action" => "settings_apply",
        "target_id" => "host",
        "inputs" => %{
          "scope" => "host",
          "selections" => %{
            "host.repository_defaults.auto_land.posture" => "strict",
            "host.repository_defaults.capabilities.required" => ["github_pr"]
          }
        }
      }

      {request, preview} = preview!(context, command)
      assert preview.identity.mode == "host"
      assert preview.disabled_reason == nil

      [alpha] = preview.proposed_state.settings.affected_targets
      assert alpha.target_id == "alpha"
      assert alpha.state == :paused

      posture = Enum.find(alpha.changes, &(&1.field == "auto_land.posture"))
      assert posture.before == "permissive"
      assert posture.after == "strict"
      assert posture.source == "host"

      capabilities = Enum.find(alpha.changes, &(&1.field == "capabilities.required"))
      assert capabilities.before == []
      assert capabilities.after == ["github_pr"]

      assert is_binary(alpha.revision.before)
      assert is_binary(alpha.revision.after)
      assert alpha.revision.before != alpha.revision.after

      result = confirm!(context, request, preview)
      assert result.status == "completed"
      assert result.result.mode == "host"
      assert result.result.settings.values["host.repository_defaults.auto_land.posture"] == "strict"
      assert result.result.settings.revisions["registry"] == HostScheduler.snapshot(context.scheduler).registry.generation

      {:ok, document} = Yaml.decode(File.read!(context.path))
      assert get_in(document, ["host", "repository_defaults", "auto_land", "posture"]) == "strict"
      assert get_in(document, ["host", "repository_defaults", "capabilities", "required"]) == ["github_pr"]
      refute Map.has_key?(document["targets"], "host")
    end

    test "a nil selection clears the stored default instead of dropping the request", context do
      command = %{
        "action" => "settings_apply",
        "target_id" => "host",
        "inputs" => %{"scope" => "host", "selections" => %{"host.repository_defaults.auto_land.posture" => nil}}
      }

      {request, preview} = preview!(context, command)
      result = confirm!(context, request, preview)
      assert result.status == "completed"

      {:ok, document} = Yaml.decode(File.read!(context.path))
      assert Map.has_key?(get_in(document, ["host", "repository_defaults", "auto_land"]), "required_checks")
      refute Map.has_key?(get_in(document, ["host", "repository_defaults", "auto_land"]), "posture")

      catalog = OperatorSettings.build(context.scheduler, %{"scope" => "host"}, context.opts)
      cleared = catalog.fields["host.repository_defaults.auto_land.posture"]
      assert cleared.current == nil
      assert cleared.source == nil
      assert result.result.settings.values["host.repository_defaults.auto_land.posture"] == nil
    end

    test "a target override keeps its own value while the shared layer changes", context do
      command = %{
        "action" => "settings_apply",
        "target_id" => "alpha",
        "inputs" => %{"selections" => %{"repository_policy.auto_land.posture" => "off"}}
      }

      {request, preview} = preview!(context, command)
      assert confirm!(context, request, preview).status == "completed"

      host_command = %{
        "action" => "settings_apply",
        "target_id" => "host",
        "inputs" => %{"scope" => "host", "selections" => %{"host.repository_defaults.auto_land.posture" => "strict"}}
      }

      {_request, preview} = preview!(context, host_command)
      # The target override wins, so the shared edit changes no effective leaf
      # for this target and it drops out of the affected set.
      assert preview.proposed_state.settings.affected_targets == []
    end

    test "creating a missing profile reports the target that becomes resolvable", context do
      {:ok, document} = Yaml.decode(File.read!(context.path))
      document = put_in(document, ["targets", "alpha", "repository_profile"], "new-profile")
      File.write!(context.path, Yaml.encode(document))
      assert {:ok, _} = HostScheduler.reload(context.scheduler)

      command = %{
        "action" => "settings_apply",
        "target_id" => "host",
        "inputs" => %{"scope" => "host", "selections" => %{"host.repository_profiles.new-profile.auto_land.posture" => "strict"}}
      }

      {request, preview} = preview!(context, command)

      assert [%{target_id: "alpha", resolution: %{before: false, after: true}}] =
               preview.proposed_state.settings.affected_targets

      assert confirm!(context, request, preview).status == "completed"
      assert {:ok, loaded} = Registry.load(context.path)
      assert loaded.contexts["alpha"].state == :paused
    end

    test "a changed registry fails the shared edit closed at confirmation", context do
      command = %{
        "action" => "settings_apply",
        "target_id" => "host",
        "inputs" => %{"scope" => "host", "selections" => %{"host.repository_defaults.auto_land.posture" => "strict"}}
      }

      {request, preview} = preview!(context, command)

      {:ok, document} = Yaml.decode(File.read!(context.path))
      File.write!(context.path, Yaml.encode(put_in(document, ["host", "id"], "raced-host")))
      assert {:ok, _} = HostScheduler.reload(context.scheduler)

      confirmation = Map.put(request, "confirmation_token", preview.confirmation_token)
      assert {:error, rejected} = OperatorInterface.confirm(context.interface, context.credential, confirmation)
      assert rejected.status == "rejected"
      assert rejected.error.code == "stale_generation"
      assert rejected.state_may_have_changed == false

      {:ok, document} = Yaml.decode(File.read!(context.path))
      assert get_in(document, ["host", "repository_defaults", "auto_land", "posture"]) == "permissive"
    end
  end

  describe "catalog races fail closed at confirmation" do
    test "a registry change after preview rejects the confirmation", context do
      command = %{
        "action" => "settings_apply",
        "target_id" => "beta",
        "inputs" => %{"selections" => creation_selections(context)}
      }

      {request, preview} = preview!(context, command)

      {:ok, document} = Yaml.decode(File.read!(context.path))
      File.write!(context.path, Yaml.encode(put_in(document, ["host", "id"], "raced-host")))
      assert {:ok, _} = HostScheduler.reload(context.scheduler)

      confirmation = Map.put(request, "confirmation_token", preview.confirmation_token)
      assert {:error, rejected} = OperatorInterface.confirm(context.interface, context.credential, confirmation)
      assert rejected.status == "rejected"
      assert rejected.error.code == "stale_generation"
      assert rejected.state_may_have_changed == false

      {:ok, document} = Yaml.decode(File.read!(context.path))
      refute Map.has_key?(document["targets"], "beta")
    end

    test "a concurrently created target ID fails the Add at confirmation with commit state", context do
      command = %{
        "action" => "settings_apply",
        "target_id" => "beta",
        "inputs" => %{"selections" => creation_selections(context)}
      }

      {request, preview} = preview!(context, command)

      {:ok, document} = Yaml.decode(File.read!(context.path))
      document = put_in(document, ["targets", "beta"], document["targets"]["alpha"])
      File.write!(context.path, Yaml.encode(document))
      assert {:ok, _} = HostScheduler.reload(context.scheduler)

      confirmation = Map.put(request, "confirmation_token", preview.confirmation_token)
      assert {:error, rejected} = OperatorInterface.confirm(context.interface, context.credential, confirmation)
      assert rejected.status == "rejected"
      assert rejected.error.code == "stale_generation"
      assert rejected.state_may_have_changed == false
      assert {:ok, stored} = Yaml.decode(File.read!(context.path))
      assert get_in(stored, ["targets", "beta", "display_name"]) == "Alpha"
    end

    test "preview and token bind to the exact settings request", context do
      command = %{
        "action" => "settings_apply",
        "target_id" => "alpha",
        "inputs" => %{"selections" => %{"concurrency.max_concurrent_agents" => 1}}
      }

      {request, preview} = preview!(context, command)

      tampered = put_in(request, ["command", "inputs", "selections", "concurrency.max_concurrent_agents"], 2)
      tampered = Map.put(tampered, "confirmation_token", preview.confirmation_token)
      assert {:error, rejection} = OperatorInterface.confirm(context.interface, context.credential, tampered)
      assert rejection.error.code == "confirmation_mismatch"

      confirmation = Map.put(request, "confirmation_token", preview.confirmation_token)
      assert {:error, replay} = OperatorInterface.confirm(context.interface, context.credential, confirmation)
      assert replay.error.code == "invalid_confirmation"
    end
  end

  describe "single-repository routing" do
    test "a dedicated project binding routes without labels", context do
      catalog = OperatorSettings.build(context.scheduler, %{"target_id" => "alpha"}, context.opts)
      assert catalog.routing.status == "routed"
      assert catalog.routing.repository == context.policy["project"]["repository"]
      assert catalog.routing.conflicts == []
    end

    test "overlapping team scopes on one connection are ambiguous" do
      left = entry("alpha", "team", %{"team_key" => "ENG"}, "owner/alpha")
      right = entry("beta", "team", %{"team_key" => "ENG"}, "owner/beta")
      entries = [left, right]

      assert {:error, {:routing_ambiguous, matches}} = TargetRouting.resolve_issue(entries, @issue)
      assert Enum.map(matches, & &1.target_id) == ["alpha", "beta"]

      assert {:error, :routing_missing} =
               TargetRouting.resolve_issue_for(entries, "alpha", %Issue{@issue | team_key: "OPS"})
    end

    test "broad scopes conservatively overlap narrower bindings" do
      broad = entry("watch", "query", %{"query_file" => "/tmp/q.json"}, "owner/watch")
      dedicated = entry("alpha", "project", %{"project_id" => "project-1"}, "owner/alpha")

      assert TargetRouting.scopes_potentially_overlap?(broad.scope, dedicated.scope)
      refute TargetRouting.scopes_exactly_overlap?(broad.scope, dedicated.scope)

      assert {:error, {:routing_ambiguous, _matches}} =
               TargetRouting.resolve_issue([broad, dedicated], @issue)
    end

    test "a routing preview identifies the repository and every conflict" do
      [routing] =
        [entry("alpha", "project", %{"project_id" => "project-1"}, "owner/alpha")]
        |> TargetRouting.preview()

      assert routing.status == "routed"
      assert routing.repository == "owner/alpha"
      assert routing.reason == nil

      [routed, conflicted] =
        [
          entry("alpha", "project", %{"project_id" => "project-1"}, "owner/alpha"),
          entry("beta", "project", %{"project_id" => "project-1"}, "owner/beta")
        ]
        |> TargetRouting.preview()

      assert routed.status == "ambiguous"
      assert routed.reason == "routing_ambiguous"
      assert Enum.map(routed.conflicts, & &1.target_id) == ["beta"]
      assert conflicted.status == "ambiguous"
    end

    test "statically ambiguous scopes warn and never admit silently", context do
      {:ok, document} = Yaml.decode(File.read!(context.path))
      {beta_repo, _policy} = SymphonyElixir.TestSupport.host_repository_fixture(context.root <> "-beta", @repo)
      {_, 0} = System.cmd("git", ["remote", "set-url", "origin", "https://github.com/example/beta"], cd: beta_repo)
      beta = document["targets"]["alpha"] |> put_in(["display_name"], "Beta")
      beta = put_in(beta, ["repo", "expected_repository"], "https://github.com/example/beta")
      beta = put_in(beta, ["repo", "path"], beta_repo)
      beta = put_in(beta, ["worktree", "root"], Path.join(context.root, "beta-worktrees"))
      beta = Map.put(beta, "repository_policy", %{"project" => %{"repository" => "https://github.com/example/beta"}})
      File.write!(context.path, Yaml.encode(put_in(document, ["targets", "beta"], beta)))

      assert {:ok, loaded} = Registry.load(context.path)

      for {_id, target} <- loaded.snapshot.targets do
        assert target.valid? == true, inspect(target.diagnostics)

        assert Enum.any?(
                 target.diagnostics,
                 &(&1.code == :routing_overlap and &1.severity == :warning)
               )
      end

      assert Map.keys(loaded.contexts) == ["alpha", "beta"]
    end

    test "undecidable overlaps warn without invalidating the targets", context do
      {:ok, document} = Yaml.decode(File.read!(context.path))
      beta = document["targets"]["alpha"] |> put_in(["display_name"], "Beta")
      beta = put_in(beta, ["linear", "scope"], %{"type" => "team", "team_key" => "ENG"})
      beta = put_in(beta, ["worktree", "root"], Path.join(context.root, "beta-worktrees"))
      File.write!(context.path, Yaml.encode(put_in(document, ["targets", "beta"], beta)))

      assert {:ok, loaded} = Registry.load(context.path)

      for {_id, target} <- loaded.snapshot.targets do
        assert target.valid? == true, inspect(target.diagnostics)
        assert Enum.any?(target.diagnostics, &(&1.code == :routing_overlap_possible and &1.severity == :warning))
      end

      assert Map.keys(loaded.contexts) == ["alpha", "beta"]
    end

    test "the host scheduler blocks admission when routing is ambiguous", context do
      {:ok, loaded} = Registry.load(context.path)
      alpha = overlapping_context(context.target, "alpha", "owner/alpha")
      beta = overlapping_context(context.target, "beta", "owner/beta")
      snapshot = %{loaded.snapshot | targets: Map.put(loaded.snapshot.targets, "beta", %{loaded.snapshot.targets["alpha"] | id: "beta"})}

      scheduler =
        start_supervised!(
          {HostScheduler,
           name: unique_name(),
           registry_path: "/deterministic/sid-496-routing.yml",
           registry_loader: fn _path ->
             {:ok, %{snapshot: snapshot, contexts: %{"alpha" => alpha, "beta" => beta}}}
           end,
           target_supervisor: false,
           registry_reload_interval_ms: 60_000},
          id: :routing_scheduler
        )

      worker = start_supervised!({Task, fn -> :timer.sleep(:infinity) end})
      HostScheduler.register_target(scheduler, alpha, worker)
      HostScheduler.register_target(scheduler, beta, worker)

      assert {:error, %{code: :routing_ambiguous, targets: ["alpha", "beta"]}} =
               HostScheduler.resolve_issue_routing(scheduler, "alpha", @issue)

      assert {:error, %{code: :routing_missing}} =
               HostScheduler.resolve_issue_routing(scheduler, "alpha", %Issue{@issue | team_key: "OPS"})
    end
  end

  describe "explicit issue batches" do
    setup context do
      {:ok, document} = Yaml.decode(File.read!(context.path))
      document = put_in(document, ["targets", "alpha", "state"], "active")
      document = put_in(document, ["targets", "alpha", "dispatch_mode"], "explicit")
      File.write!(context.path, Yaml.encode(document))
      assert {:ok, _} = HostScheduler.reload(context.scheduler)
      context
    end

    test "previews exact issues, repository, policy, and limits, then commits the batch", context do
      issues = [
        %Issue{@issue | id: "SID-900", identifier: "SID-900"},
        %Issue{@issue | id: "SID-901", identifier: "SID-901", title: "Second"}
      ]

      opts = Keyword.put(context.opts, :fetch_issues, fn _target, _ids -> {:ok, issues} end)

      command = %{"action" => "batch", "target_id" => "alpha", "inputs" => %{"issue_ids" => ["SID-900", "SID-901"]}}

      {request, preview} = preview!(context, command, opts)
      batch = preview.proposed_state.batch

      assert Enum.map(batch.issues, & &1.identifier) == ["SID-900", "SID-901"]
      assert batch.repository == context.policy["project"]["repository"]
      assert batch.limits.issue_batch_limit == 2
      assert batch.limits.capacity_limits["max_concurrent_agents"] == 2
      assert batch.limits.budget_limits["per_run"]["max_total_tokens"] == 1_000

      result = confirm!(context, request, preview, opts)
      assert result.status == "completed"
      assert result.result.batch.issue_ids == ["SID-900", "SID-901"]

      {:ok, document} = Yaml.decode(File.read!(context.path))
      assert get_in(document, ["targets", "alpha", "linear", "scope"]) == %{"type" => "issues", "issue_ids" => ["SID-900", "SID-901"]}

      {:ok, reloaded} = Registry.load(context.path)
      assert reloaded.contexts["alpha"].capacity_limits["issue_batch_limit"] == 2
      assert batch.policy.policy_hash == reloaded.contexts["alpha"].policy_hash
      assert batch.policy.configuration_revision == reloaded.contexts["alpha"].repo_policy["configuration_revision"]
      assert batch.limits.capacity_limits == reloaded.contexts["alpha"].capacity_limits
      assert batch.limits.budget_limits == reloaded.contexts["alpha"].budget_limits

      replacement_opts = Keyword.put(context.opts, :fetch_issues, fn _target, _ids -> {:ok, [hd(issues)]} end)
      replacement = put_in(command, ["inputs", "issue_ids"], ["SID-900"])
      {request, preview} = preview!(context, replacement, replacement_opts)
      batch = preview.proposed_state.batch
      assert batch.limits.issue_batch_limit == 1
      assert batch.limits.capacity_limits["issue_batch_limit"] == 1
      result = confirm!(context, request, preview, replacement_opts)
      assert result.status == "completed"

      {:ok, reloaded} = Registry.load(context.path)
      assert batch.policy.policy_hash == reloaded.contexts["alpha"].policy_hash
      assert batch.policy.configuration_revision == reloaded.contexts["alpha"].repo_policy["configuration_revision"]
      assert batch.limits.capacity_limits == reloaded.contexts["alpha"].capacity_limits
      assert batch.limits.budget_limits == reloaded.contexts["alpha"].budget_limits
    end

    test "an issue ID and identifier cannot inflate the batch limit", context do
      opts = Keyword.put(context.opts, :fetch_issues, fn _target, _ids -> {:ok, [@issue]} end)

      command = %{
        "action" => "batch",
        "target_id" => "alpha",
        "inputs" => %{"issue_ids" => [@issue.id, @issue.identifier]}
      }

      assert {:error, rejection} =
               OperatorInterface.preview(context.interface, context.credential, request(context, command), opts)

      assert rejection.error.code == "duplicate_batch_issue"
      assert rejection.state_may_have_changed == false
    end

    test "unknown issues fail the batch with the missing identities", context do
      opts = Keyword.put(context.opts, :fetch_issues, fn _target, _ids -> {:ok, [@issue]} end)

      command = %{"action" => "batch", "target_id" => "alpha", "inputs" => %{"issue_ids" => ["SID-900", "SID-999"]}}

      assert {:error, rejection} =
               OperatorInterface.preview(context.interface, context.credential, request(context, command), opts)

      assert rejection.error.code == "issues_not_found"
    end

    test "overlapping selections cannot bypass single-repository routing", context do
      {:ok, document} = Yaml.decode(File.read!(context.path))
      {watch_repo, _policy} = SymphonyElixir.TestSupport.host_repository_fixture(context.root <> "-watch", @repo)
      {_, 0} = System.cmd("git", ["remote", "set-url", "origin", "https://github.com/example/watch"], cd: watch_repo)
      watch = document["targets"]["alpha"] |> put_in(["display_name"], "Watch") |> put_in(["state"], "active")
      watch = put_in(watch, ["dispatch_mode"], "watch")
      watch = put_in(watch, ["linear", "scope"], %{"type" => "team", "team_key" => "ENG"})

      watch =
        put_in(watch, ["repository_policy"], %{
          "project" => %{"repository" => "https://github.com/example/watch"},
          "issue_markers" => %{"allowed_projects" => ["project-1"]}
        })

      watch = put_in(watch, ["worktree", "root"], Path.join(context.root, "watch-worktrees"))
      watch = put_in(watch, ["repo", "expected_repository"], "https://github.com/example/watch")
      watch = put_in(watch, ["repo", "path"], watch_repo)
      File.write!(context.path, Yaml.encode(put_in(document, ["targets", "watch"], watch)))
      assert {:ok, _} = HostScheduler.reload(context.scheduler)

      opts = Keyword.put(context.opts, :fetch_issues, fn _target, _ids -> {:ok, [@issue]} end)

      command = %{"action" => "batch", "target_id" => "alpha", "inputs" => %{"issue_ids" => ["SID-900"]}}

      assert {:error, rejection} =
               OperatorInterface.preview(context.interface, context.credential, request(context, command), opts)

      assert rejection.error.code == "routing_ambiguous"
    end

    test "issue identity changes between preview and confirm fail closed", context do
      issues = [
        %Issue{@issue | id: "SID-900", identifier: "SID-900"},
        %Issue{@issue | id: "SID-901", identifier: "SID-901"}
      ]

      fetch_results = start_supervised!({Agent, fn -> issues end})
      opts = Keyword.put(context.opts, :fetch_issues, fn _target, _ids -> {:ok, Agent.get(fetch_results, & &1)} end)

      command = %{"action" => "batch", "target_id" => "alpha", "inputs" => %{"issue_ids" => ["SID-900", "SID-901"]}}
      {request, preview} = preview!(context, command, opts)

      Agent.update(fetch_results, fn [first, %Issue{} = second] -> [first, %{second | id: "replacement-id"}] end)

      confirmation = Map.put(request, "confirmation_token", preview.confirmation_token)
      assert {:ok, accepted} = OperatorInterface.confirm(context.interface, context.credential, confirmation)
      result = await_result(context.interface, accepted.id)

      assert result.status == "failed"
      assert result.error.code == "batch_issues_changed"
      assert result.state_may_have_changed == false

      {:ok, document} = Yaml.decode(File.read!(context.path))
      refute get_in(document, ["targets", "alpha", "linear", "scope", "issue_ids"]) == ["SID-900", "SID-901"]
    end

    test "watch targets reject explicit batches", context do
      {:ok, document} = Yaml.decode(File.read!(context.path))
      document = put_in(document, ["targets", "alpha", "dispatch_mode"], "watch")
      File.write!(context.path, Yaml.encode(document))
      assert {:ok, _} = HostScheduler.reload(context.scheduler)

      command = %{"action" => "batch", "target_id" => "alpha", "inputs" => %{"issue_ids" => ["SID-900"]}}

      {_request, preview} = preview!(context, command)
      assert preview.disabled_reason == "explicit_target_required"
      assert preview.confirmation_token == nil
    end
  end

  defp creation_selections(context) do
    %{
      "display_name" => "Beta",
      "repo.path" => context.repo,
      "worktree.root" => Path.join(context.root, "beta-worktrees"),
      "worktree.strategy" => "per_issue",
      "linear.connection" => "linear-main",
      "linear.scope.type" => "project",
      "linear.scope.project_id" => "project-1",
      "linear.active_states" => ["Todo"],
      "linear.terminal_states" => ["Done"],
      "linear.required_labels" => [],
      "runners.allowed" => ["existing"],
      "runners.default" => "existing",
      "concurrency.max_concurrent_agents" => 1,
      "concurrency.max_concurrent_startups" => 1,
      "concurrency.max_concurrent_reviewers" => 1,
      "budgets.per_run.max_total_tokens" => 1_000,
      "budgets.daily.max_total_tokens" => 10_000,
      "budgets.weekly.max_total_tokens" => 50_000,
      "checks.pre_dispatch" => ["capability_preflight"],
      "checks.pre_handoff" => [],
      "checks.pre_publish" => [],
      "checks.pre_merge" => [],
      "scheduling.weight" => 1
    }
  end

  defp registry(root, repo, policy) do
    %{
      "version" => 1,
      "host" => %{
        "id" => "operator-test",
        "capabilities" => ["github_pr", "browser"],
        "state_root" => Path.join(root, "state"),
        "polling" => %{"interval_ms" => 30_000, "max_concurrent_target_polls" => 1},
        "capacity" => %{"max_concurrent_agents" => 4, "max_concurrent_startups" => 2, "max_concurrent_reviewers" => 1},
        "scheduling" => %{"algorithm" => "weighted_deficit_round_robin", "max_credit_rounds" => 4},
        "tracker_connections" => %{
          "linear-main" => %{
            "kind" => "linear",
            "endpoint" => "https://api.linear.app/graphql",
            "api_key" => "$LINEAR_API_KEY"
          }
        },
        "runners" => %{
          "existing" => %{
            "kind" => "codex_app_server",
            "command" => ["existing", "app-server"],
            "turn_timeout_ms" => 60_000,
            "max_concurrent_agents" => 4,
            "max_concurrent_startups" => 2
          }
        },
        "repository_defaults" =>
          Map.merge(policy, %{
            "capabilities" => %{"required" => []},
            "issue_markers" => %{"labels" => [], "allowed_projects" => []}
          })
      },
      "targets" => %{
        "alpha" => %{
          "display_name" => "Alpha",
          "state" => "paused",
          "repo" => %{"path" => repo, "expected_repository" => policy["project"]["repository"]},
          "worktree" => %{"root" => Path.join(root, "worktrees"), "strategy" => "per_issue", "hooks" => %{}},
          "linear" => %{
            "connection" => "linear-main",
            "scope" => %{"type" => "project", "project_id" => "project-1"},
            "active_states" => ["Todo"],
            "terminal_states" => ["Done"],
            "required_labels" => []
          },
          "runners" => %{"allowed" => ["existing"], "default" => "existing", "settings" => %{}},
          "concurrency" => %{
            "max_concurrent_agents" => 2,
            "max_concurrent_startups" => 1,
            "max_concurrent_reviewers" => 1,
            "by_linear_state" => %{}
          },
          "budgets" => %{
            "per_run" => %{"max_total_tokens" => 1_000},
            "daily" => %{"max_total_tokens" => 10_000},
            "weekly" => %{"max_total_tokens" => 50_000}
          },
          "checks" => %{
            "pre_dispatch" => ["capability_preflight"],
            "pre_handoff" => ["repo_validation", "quality_gate"],
            "pre_publish" => ["publish_preflight"],
            "pre_merge" => ["pr_checks", "review_feedback_sweep"]
          },
          "external_side_effects" => side_effect_gates(),
          "scheduling" => %{"weight" => 1}
        }
      }
    }
  end

  defp side_effect_gates do
    %{
      "tracker_write" => "deny",
      "vcs_publish" => "deny",
      "pull_request_write" => "deny",
      "merge" => "deny",
      "deployment" => "deny",
      "production_data" => "deny"
    }
  end

  defp entry(target_id, type, scope, repository) do
    %{
      target_id: target_id,
      connection_id: "linear-main",
      markers: SymphonyElixir.RunTarget.repo_markers(%{"allowed_projects" => ["project-1"]}),
      scope: Map.put(scope, "type", type),
      scope_type: type,
      repository: repository,
      repository_key: "slug:" <> repository,
      active?: true
    }
  end

  defp overlapping_context(base, target_id, repository) do
    %{
      base
      | target_id: target_id,
        state: :active,
        dispatch_mode: :watch,
        run_target: %{
          "scope" => %{"type" => "team", "team_key" => "ENG"},
          "required_labels" => [],
          "active_states" => ["Todo"],
          "terminal_states" => ["Done"]
        },
        tracker_connection: %{"id" => "linear-main", "policy" => %{"kind" => "linear"}},
        repo_policy: %{"manifest" => %{"project" => %{"repository" => repository}, "issue_markers" => %{"allowed_projects" => ["project-1"]}}}
    }
  end

  defp admit_active_run!(context, issue) do
    assert {:ok, policy} = TargetContext.issue_policy(context.target, issue, [])
    assert {:ok, execution_context} = SymphonyElixir.ExecutionContext.new(context.target, issue, policy: policy)
    RunAuthority.admit(context.control_plane, "owner-smoke", execution_context)
  end

  defp request(context, command) do
    {:ok, marker} = OperatorInterface.marker(context.interface)

    command =
      if get_in(command, ["inputs", "selections", "linear.connection"]) do
        catalog = OperatorSettings.build(context.scheduler, command["inputs"], context.opts)
        put_in(command, ["inputs", "linear_revision"], catalog.revisions["linear"])
      else
        command
      end

    %{
      "interface_version" => 1,
      "host_id" => marker.host_id,
      "registry_generation" => HostScheduler.snapshot(context.scheduler).registry.generation,
      "command" => command
    }
  end

  defp preview!(context, command, opts \\ []) do
    request = request(context, command)
    assert {:ok, preview} = OperatorInterface.preview(context.interface, context.credential, request, opts ++ context.opts)

    if command["action"] == "settings_apply" do
      diagnostics = get_in(preview, [:proposed_state, :registry, "diagnostics"])
      assert preview.disabled_reason == nil, inspect(diagnostics, limit: :infinity)
    end

    {request, preview}
  end

  defp confirm!(context, request, preview, opts \\ []) do
    assert {:ok, accepted} =
             OperatorInterface.confirm(
               context.interface,
               context.credential,
               Map.put(request, "confirmation_token", preview.confirmation_token)
             )

    await_result(context.interface, accepted.id, opts)
  end

  defp await_result(interface, id, opts \\ [], attempts \\ 200)

  defp await_result(_interface, _id, _opts, 0), do: flunk("command did not complete")

  defp await_result(interface, id, opts, attempts) do
    {:ok, marker} = OperatorInterface.marker(interface)
    result = Enum.find(marker.command_results, &(&1.id == id))

    if result && result.status != "accepted" do
      result
    else
      assert attempts > 0, "command did not complete"
      _ = opts
      Process.sleep(5)
      await_result(interface, id, opts, attempts - 1)
    end
  end

  defp unique_name do
    Module.concat(__MODULE__, "Server#{System.unique_integer([:positive])}")
  end

  defp await_metadata(cache, connection, attempts \\ 200)
  defp await_metadata(_cache, _connection, 0), do: flunk("metadata did not become ready")

  defp await_metadata(cache, connection, attempts) do
    case MetadataCache.get(connection, server: cache) do
      %{status: "current"} ->
        :ok

      _ ->
        Process.sleep(5)
        await_metadata(cache, connection, attempts - 1)
    end
  end
end
