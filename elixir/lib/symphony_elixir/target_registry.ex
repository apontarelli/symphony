defmodule SymphonyElixir.TargetRegistry do
  @moduledoc false

  @type generation :: <<_::56, _::_*8>>

  defmodule Error do
    @moduledoc false

    @enforce_keys [:code, :message]
    defstruct [:code, :message, :path]

    @type t :: %__MODULE__{
            code: atom(),
            message: String.t(),
            path: String.t() | nil
          }
  end

  defmodule Diagnostic do
    @moduledoc false

    @enforce_keys [:severity, :scope, :path, :code, :message]
    defstruct [:severity, :scope, :path, :code, :message]

    @type severity :: :error | :warning | :info
    @type scope :: :registry | :host | {:target, term()}
    @type t :: %__MODULE__{
            severity: severity(),
            scope: scope(),
            path: String.t(),
            code: atom(),
            message: String.t()
          }
  end

  defmodule Target do
    @moduledoc false

    @enforce_keys [
      :id,
      :configured,
      :configured_state,
      :effective_state,
      :dispatch_mode,
      :valid?,
      :diagnostics
    ]
    defstruct [
      :id,
      :configured,
      :configured_state,
      :effective_state,
      :dispatch_mode,
      :repo_manifest,
      :effective_policy,
      :policy_hash,
      valid?: false,
      diagnostics: []
    ]

    @type configured_state :: :paused | :active | :draining | :retired | nil | {:unknown, String.t()}
    @type dispatch_mode :: :explicit | :watch | nil | {:unknown, String.t()}
    @type t :: %__MODULE__{
            id: term(),
            configured: map(),
            configured_state: configured_state(),
            effective_state: :paused | :active | :draining | :retired,
            dispatch_mode: dispatch_mode(),
            valid?: boolean(),
            repo_manifest: map() | nil,
            effective_policy: map() | nil,
            policy_hash: String.t() | nil,
            diagnostics: [SymphonyElixir.TargetRegistry.Diagnostic.t()]
          }
  end

  defmodule Snapshot do
    @moduledoc false

    @enforce_keys [:version, :globally_valid?, :host, :targets, :diagnostics]
    defstruct [
      :version,
      :path,
      :source_hash,
      :generation,
      :host,
      globally_valid?: false,
      targets: %{},
      diagnostics: []
    ]

    @type t :: %__MODULE__{
            version: 1,
            path: Path.t() | nil,
            source_hash: SymphonyElixir.TargetRegistry.generation() | nil,
            generation: SymphonyElixir.TargetRegistry.generation() | nil,
            globally_valid?: boolean(),
            host: map() | nil,
            targets: %{term() => SymphonyElixir.TargetRegistry.Target.t()},
            diagnostics: [SymphonyElixir.TargetRegistry.Diagnostic.t()]
          }
  end
end
