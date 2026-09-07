defmodule SymphonyElixir.OperatorSettingsApply do
  @moduledoc """
  Host-owned writer for target settings and shared host repository policy.

  Converts authoritative settings field selections into an Add or Patch
  command for one target, or a HostPatch for the shared repository policy
  layers when the request scope is `host`. The scope is always explicit:
  `inputs["scope"]` is `"host"` or `"target"` (the default), and `target_id`
  stays opaque to this writer, so a target literally named `host` is edited
  like any other target. Host scope rides the HostPatch envelope, whose
  action-specific sentinel target ID is `host`. Creation always produces a
  paused target; updates never touch lifecycle fields, which belong to the
  separate Activate/Pause/Drain/Retire preview-and-confirm commands. Nothing
  here activates work.
  """

  alias SymphonyElixir.{HostScheduler, OperatorRepositoryInspection, OperatorSettings}
  alias SymphonyElixir.OperatorCommandService.Command
  alias SymphonyElixir.TargetRegistry.{Composition, FileStore, RepositoryPolicy, Schema, Yaml}

  # Matches OperatorCommandService's host patch envelope sentinel.
  @host_target_id "host"

  @enforce_keys [
    :mode,
    :target_id,
    :command,
    :settings_request,
    :linear_revision,
    :fingerprint,
    :values,
    :affected
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          mode: :create | :update | :host,
          target_id: String.t(),
          command: Command.Add.t() | Command.Patch.t() | Command.HostPatch.t(),
          settings_request: map(),
          linear_revision: String.t() | nil,
          fingerprint: String.t(),
          values: map(),
          affected: [map()]
        }

  @max_selections 256

  @doc """
  Builds the registry command a settings Apply will confirm.

  `inputs["scope"]` selects `"host"` (shared repository policy layers, riding
  the HostPatch envelope sentinel target ID `host`) or `"target"` (the
  default; `target_id` names an existing target to update or a new one to
  create, and the literal ID `host` is an ordinary target). Returns the
  composed command plus a fingerprint that confirmation must reproduce
  exactly.
  """
  @spec build(GenServer.server(), String.t(), map(), keyword()) ::
          {:ok, t()} | {:error, map()}
  def build(scheduler, target_id, inputs, opts) when is_binary(target_id) and is_map(inputs) do
    selections = selections(inputs)
    repository = repository(inputs)
    linear_revision = linear_revision(inputs)

    with {:ok, scope} <- request_scope(inputs),
         host? = scope == "host",
         :ok <- enforce_host_envelope(host?, target_id),
         :ok <- validate_selections(selections),
         :ok <- reject_host_repository(host?, repository),
         {:ok, snapshot} <- verified_snapshot(scheduler),
         exists? <- not host? and Map.has_key?(snapshot["targets"], target_id),
         settings_request = %{
           "target_id" => if(host?, do: @host_target_id, else: if(exists?, do: target_id)),
           "scope" => scope,
           "repository" => repository,
           "selections" => selections,
           "linear_revision" => linear_revision
         },
         catalog = OperatorSettings.build(scheduler, settings_request, opts),
         :ok <- ensure_editable_selections(catalog, selections),
         :ok <- ensure_applicable(catalog),
         {:ok, command} <-
           compose_command(target_id, host?, exists?, snapshot, selections, repository),
         {:ok, fingerprint} <- fingerprint(command) do
      {:ok,
       %__MODULE__{
         mode: mode(host?, exists?),
         target_id: target_id,
         command: command,
         settings_request: settings_request,
         linear_revision: catalog.revisions["linear"],
         fingerprint: fingerprint,
         values: authoritative_values(catalog),
         affected: if(host?, do: host_affected_targets(snapshot, selections), else: [])
       }}
    end
  end

  def build(_scheduler, _target_id, _inputs, _opts),
    do: {:error, %{code: :invalid_settings_apply, state_may_have_changed: false}}

  @doc """
  Confirmation-time fail-closed recheck.

  The settings catalog is rebuilt from current host state; a stale registry,
  changed connection, removed choice, or invalid lifecycle change must fail
  here even when it was only display-visible at preview time.
  """
  @spec verify(GenServer.server(), t(), keyword()) :: :ok | {:error, map()}
  def verify(scheduler, %__MODULE__{} = prepared, opts) do
    host? = prepared.mode == :host

    catalog = OperatorSettings.build(scheduler, prepared.settings_request, opts)

    with :ok <- ensure_editable_selections(catalog, prepared.settings_request["selections"]),
         :ok <- ensure_applicable(catalog),
         {:ok, snapshot} <- verified_snapshot(scheduler),
         {:ok, command} <-
           compose_command(
             prepared.target_id,
             host?,
             prepared.mode == :update,
             snapshot,
             prepared.settings_request["selections"],
             prepared.settings_request["repository"]
           ),
         {:ok, fingerprint} <- fingerprint(command) do
      cond do
        command_identity(command) != command_identity(prepared.command) or
            fingerprint != prepared.fingerprint ->
          {:error, %{code: :settings_apply_changed, state_may_have_changed: false}}

        prepared.linear_revision != nil and catalog.revisions["linear"] != prepared.linear_revision ->
          {:error, %{code: :settings_catalog_stale, state_may_have_changed: false}}

        true ->
          :ok
      end
    end
  end

  @doc """
  Authoritative post-Apply values and revisions read back from the host.

  The readback reuses the prepared Apply's scope, so a target literally named
  `host` reads back its own target settings while a host-scope Apply reads
  back the shared layers.
  """
  @spec readback(GenServer.server(), t(), keyword()) :: {:ok, map()} | {:error, map()}
  def readback(scheduler, %__MODULE__{mode: mode, target_id: target_id}, opts)
      when mode in [:create, :update, :host] do
    scope = if(mode == :host, do: "host", else: "target")
    catalog = OperatorSettings.build(scheduler, %{"target_id" => target_id, "scope" => scope, "selections" => %{}}, opts)

    if catalog.status == "current" do
      {:ok,
       %{
         target_id: target_id,
         values: authoritative_values(catalog),
         revisions: catalog.revisions,
         routing: catalog.routing
       }}
    else
      {:error, %{code: :settings_readback_unavailable, reason: catalog.reason, state_may_have_changed: true}}
    end
  end

  # A settings Apply composes only the fields the catalog declares editable,
  # so unknown or non-writable paths never reach the registry document.
  defp validate_selections(selections) when is_map(selections) do
    cond do
      map_size(selections) > @max_selections ->
        {:error, %{code: :invalid_settings_apply, detail: "too_many_selections", state_may_have_changed: false}}

      not Enum.all?(selections, fn {path, _value} -> is_binary(path) and String.valid?(path) end) ->
        {:error, %{code: :invalid_settings_apply, detail: "invalid_selection_path", state_may_have_changed: false}}

      true ->
        :ok
    end
  end

  defp validate_selections(_selections),
    do: {:error, %{code: :invalid_settings_apply, detail: "invalid_selections", state_may_have_changed: false}}

  # Shared host layers carry no repository identity of their own.
  defp reject_host_repository(true, nil), do: :ok

  defp reject_host_repository(true, _repository),
    do: {:error, %{code: :invalid_settings_apply, detail: "invalid_repository", state_may_have_changed: false}}

  defp reject_host_repository(false, _repository), do: :ok

  defp selections(%{"selections" => selections}) when is_map(selections), do: selections
  defp selections(%{"selections" => nil}), do: %{}
  defp selections(_inputs), do: nil

  defp repository(%{"repository" => repository}) when is_binary(repository), do: repository
  defp repository(%{"repository" => nil}), do: nil
  defp repository(inputs), do: if(Map.has_key?(inputs, "repository"), do: :invalid, else: nil)

  defp linear_revision(%{"linear_revision" => revision}) when is_binary(revision), do: revision
  defp linear_revision(%{"linear_revision" => nil}), do: nil
  defp linear_revision(inputs), do: if(Map.has_key?(inputs, "linear_revision"), do: :invalid, else: nil)

  # The edit scope is explicit and never inferred from a target ID: `host`
  # edits the shared repository policy layers, `target` (the default) edits
  # one ordinary target, whatever it is named.
  defp request_scope(%{"scope" => "host"}), do: {:ok, "host"}
  defp request_scope(%{"scope" => "target"}), do: {:ok, "target"}
  defp request_scope(%{"scope" => nil}), do: {:ok, "target"}

  defp request_scope(%{"scope" => _other}),
    do: {:error, %{code: :invalid_settings_apply, detail: "invalid_scope", state_may_have_changed: false}}

  defp request_scope(_inputs), do: {:ok, "target"}

  # Host scope rides the HostPatch envelope, whose action-specific sentinel
  # target ID is `host`; any other envelope ID with host scope is ambiguous
  # and fails closed instead of diverting a real target.
  defp enforce_host_envelope(true, @host_target_id), do: :ok

  defp enforce_host_envelope(true, _other_target_id),
    do: {:error, %{code: :invalid_settings_apply, detail: "host_scope_target_id", state_may_have_changed: false}}

  defp enforce_host_envelope(false, _target_id), do: :ok

  defp mode(true = _host?, _exists?), do: :host
  defp mode(false, exists?), do: if(exists?, do: :update, else: :create)

  # Reads the registry under the generation the scheduler verified so the
  # composed command and the settings catalog describe the same document.
  defp verified_snapshot(scheduler) do
    snapshot = HostScheduler.snapshot(scheduler)

    case snapshot[:registry] do
      %{verified?: true, path: path, generation: generation} when is_binary(path) ->
        case registry_state(path, generation) do
          {:ok, state} -> {:ok, state}
          :error -> {:error, %{code: :registry_stale, state_may_have_changed: false}}
        end

      _unverified ->
        {:error, %{code: :registry_unverified, state_may_have_changed: false}}
    end
  catch
    :exit, _reason -> {:error, %{code: :host_unavailable, state_may_have_changed: false}}
  end

  defp registry_state(path, generation) do
    with {:ok, %{bytes: bytes, generation: ^generation}} <- FileStore.read(path),
         {:ok, document} <- Yaml.decode(bytes),
         {:ok, validated} <- Schema.validate(document, registry_path: path) do
      targets =
        Map.new(validated.targets || %{}, fn {id, target} ->
          {id, %{configured: target.configured, configured_state: target.configured_state}}
        end)

      {:ok, %{"host" => validated.host || %{}, "targets" => targets}}
    else
      _changed -> :error
    end
  end

  defp ensure_applicable(catalog) do
    if catalog.apply_blocked do
      {:error,
       %{
         code: :settings_apply_blocked,
         errors: catalog.errors,
         reason: catalog.reason,
         state_may_have_changed: false
       }}
    else
      :ok
    end
  end

  # Lifecycle and host-owned fields are visible in the catalog but writable
  # only through their own commands; a settings selection for them is an error.
  defp ensure_editable_selections(catalog, selections) do
    uneditable =
      selections
      |> Enum.flat_map(fn {path, _value} ->
        case Map.get(catalog.fields, path) do
          %{editable: false} = field ->
            [%{field: path, reason: field.disabled_reason || "not_editable"}]

          %{editable: true} ->
            []

          _missing ->
            [%{field: path, reason: "unknown_field"}]
        end
      end)
      |> Enum.sort_by(& &1.field)

    if uneditable == [] do
      :ok
    else
      {:error, %{code: :settings_field_not_editable, errors: uneditable, state_may_have_changed: false}}
    end
  end

  # Host-scope selections compose exactly the two shared repository policy
  # layers; every other host section stays authoritative and untouched.
  defp compose_command(_target_id, true = _host?, _exists?, _snapshot, selections, _repository) do
    changes = OperatorSettings.host_changes(selections || %{})

    if changes == %{} do
      {:error, %{code: :settings_selection_required, state_may_have_changed: false}}
    else
      {:ok, %Command.HostPatch{changes: changes}}
    end
  end

  defp compose_command(target_id, false, exists?, snapshot, selections, repository) do
    document = OperatorSettings.selection_document(selections || %{})
    configured = get_in(snapshot, ["targets", target_id, "configured"]) || %{}
    snapshot = Map.put(snapshot, "configured_target", OperatorSettings.draft_configured(configured, selections || %{}))

    with {:ok, document} <- apply_repository_identity(target_id, exists?, document, snapshot, repository) do
      settings_command(target_id, exists?, document)
    end
  end

  defp settings_command(_target_id, true, document) when map_size(document) == 0,
    do: {:error, %{code: :settings_selection_required, state_may_have_changed: false}}

  defp settings_command(target_id, true, document),
    do: {:ok, %Command.Patch{target_id: target_id, changes: document}}

  defp settings_command(target_id, false, document) do
    target = document |> Map.put("state", "paused") |> Map.put_new("external_side_effects", %{})
    {:ok, %Command.Add{target_id: target_id, target: target}}
  end

  # One canonical repository input: a request-level repository path and a
  # repo.path selection must agree, and the host derives the pinned identity
  # for every new or changed path so catalog, command, and confirmation all
  # bind the same repository.
  defp apply_repository_identity(target_id, exists?, document, snapshot, repository) do
    selected = get_in(document, ["repo", "path"])
    current = get_in(snapshot, ["targets", target_id, "configured", "repo", "path"])

    cond do
      not is_nil(selected) and not is_nil(repository) and selected != repository ->
        {:error, %{code: :invalid_settings_apply, detail: "repository_conflict", state_may_have_changed: false}}

      exists? and (selected || repository) in [nil, current] ->
        {:ok, document}

      true ->
        inspect_repository_identity(document, selected || repository, snapshot)
    end
  end

  # A repository selection makes the host, not the client, derive the identity
  # the registry will pin; an unreadable or mismatched repository blocks Apply.
  defp inspect_repository_identity(document, path, snapshot) when is_binary(path) and path != "" do
    host = Map.get(snapshot, "host", %{})
    configured = Map.get(snapshot, "configured_target", document)

    with {:ok, policy, _sources} <- RepositoryPolicy.resolve(host, configured),
         expected when is_binary(expected) <- get_in(policy, ["project", "repository"]),
         repo = Map.merge(Map.get(configured, "repo") || %{}, %{"path" => path, "expected_repository" => expected}),
         %{state: "ready"} = inspection <-
           OperatorRepositoryInspection.inspect(path, host: host, configured: Map.put(configured, "repo", repo)) do
      repo = Map.get(document, "repo") || %{}
      {:ok, Map.put(document, "repo", Map.merge(repo, %{"path" => inspection.path, "expected_repository" => expected}))}
    else
      %{reason: reason, blockers: blockers} ->
        {:error, %{code: :repository_not_ready, reason: reason, blockers: blockers, state_may_have_changed: false}}

      _ ->
        {:error, %{code: :repository_not_ready, reason: "repository_policy_invalid", state_may_have_changed: false}}
    end
  end

  defp inspect_repository_identity(_document, _invalid, _snapshot),
    do: {:error, %{code: :invalid_settings_apply, detail: "invalid_repository", state_may_have_changed: false}}

  # Every registry target whose resolved repository policy changes under the
  # proposed shared layers, with the composed old and new value of each edited
  # leaf, where the new value comes from, and the policy revision the change
  # produces. Shared edits recompose targets; admitted runs stay pinned.
  defp host_affected_targets(snapshot, selections) do
    host = Map.get(snapshot, "host", %{})
    proposed_host = OperatorSettings.draft_host_layers(host, selections || %{})
    rels = OperatorSettings.policy_fields() |> Map.keys() |> Enum.sort()

    snapshot["targets"]
    |> Enum.sort()
    |> Enum.flat_map(fn {target_id, target} ->
      before_policy = resolved_policy(host, target.configured)
      after_policy = resolved_policy(proposed_host, target.configured)
      changes = policy_leaf_changes(rels, before_policy, after_policy, proposed_host, target.configured)

      if before_policy == after_policy do
        []
      else
        [
          %{
            target_id: target_id,
            repository_profile: Map.get(target.configured, "repository_profile"),
            state: target.configured_state,
            changes: changes,
            resolution: %{before: not is_nil(before_policy), after: not is_nil(after_policy)},
            revision: %{before: policy_revision(before_policy), after: policy_revision(after_policy)}
          }
        ]
      end
    end)
  end

  defp resolved_policy(host, configured) do
    case RepositoryPolicy.resolve(host, configured) do
      {:ok, policy, _sources} -> policy
      {:error, _reason} -> nil
    end
  end

  defp policy_leaf_changes(rels, before_policy, after_policy, proposed_host, configured) do
    Enum.flat_map(rels, fn rel ->
      before_value = leaf(before_policy, rel)
      after_value = leaf(after_policy, rel)

      if before_value == after_value do
        []
      else
        [
          %{
            field: rel,
            before: before_value,
            after: after_value,
            source: policy_leaf_source(proposed_host, configured, rel)
          }
        ]
      end
    end)
  end

  # Where the composed after-value wins from: the target override, the
  # selected profile, or the shared host defaults.
  defp policy_leaf_source(host, configured, rel) do
    profile = Map.get(configured, "repository_profile")
    profiles = default_map(Map.get(host, "repository_profiles"))

    cond do
      leaf_present?(Map.get(configured, "repository_policy"), rel) -> "target"
      is_binary(profile) and leaf_present?(Map.get(profiles, profile), rel) -> "profile"
      leaf_present?(Map.get(host, "repository_defaults"), rel) -> "host"
      true -> nil
    end
  end

  defp policy_revision(nil), do: nil

  defp policy_revision(policy) do
    case Composition.canonical_hash(policy) do
      {:ok, revision} -> revision
      _unhashable -> nil
    end
  end

  defp leaf(policy, rel) when is_map(policy), do: get_in(policy, String.split(rel, "."))
  defp leaf(_policy, _rel), do: nil

  defp leaf_present?(policy, rel) do
    String.split(rel, ".")
    |> Enum.reduce_while({true, policy}, fn key, {true, nested} ->
      if is_map(nested) and Map.has_key?(nested, key),
        do: {:cont, {true, Map.get(nested, key)}},
        else: {:halt, {false, nil}}
    end)
    |> elem(0)
  end

  defp default_map(map) when is_map(map), do: map
  defp default_map(_other), do: %{}

  defp fingerprint(command) do
    case Composition.canonical_hash(%{"command" => public_command(command)}) do
      {:ok, hash} ->
        {:ok, hash}

      {:error, :not_json_safe} ->
        {:error, %{code: :invalid_settings_apply, detail: "non_canonical_selections", state_may_have_changed: false}}
    end
  end

  defp public_command(%Command.Add{target_id: target_id, target: target}),
    do: %{"action" => "add", "target_id" => target_id, "target" => target}

  defp public_command(%Command.Patch{target_id: target_id, changes: changes}),
    do: %{"action" => "patch", "target_id" => target_id, "changes" => changes}

  defp public_command(%Command.HostPatch{changes: changes}),
    do: %{"action" => "host_patch", "target_id" => @host_target_id, "changes" => changes}

  defp command_identity(%Command.Add{target_id: target_id}), do: {:add, target_id}
  defp command_identity(%Command.Patch{target_id: target_id}), do: {:patch, target_id}
  defp command_identity(%Command.HostPatch{}), do: {:host_patch, @host_target_id}

  defp authoritative_values(catalog) do
    catalog.fields
    |> Enum.filter(fn {_path, field} -> field.scope in ["target", "host"] end)
    |> Map.new(fn {path, field} -> {path, Map.get(field, :effective, field.selected)} end)
  end
end
