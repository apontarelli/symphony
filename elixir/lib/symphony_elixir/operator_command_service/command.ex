defmodule SymphonyElixir.OperatorCommandService.Command do
  @moduledoc false

  defmodule Add do
    @moduledoc false

    @enforce_keys [:target_id, :target]
    defstruct [:target_id, :target]

    @type t :: %__MODULE__{target_id: String.t(), target: map()}
  end

  defmodule Patch do
    @moduledoc false

    @enforce_keys [:target_id, :changes]
    defstruct [:target_id, :changes]

    @type t :: %__MODULE__{target_id: String.t(), changes: map()}
  end

  defmodule Import do
    @moduledoc false

    @enforce_keys [:target_id, :workflow, :repo]
    defstruct [:target_id, :workflow, :repo, :connection_id, :runner_ids]

    @type t :: %__MODULE__{
            target_id: String.t(),
            workflow: Path.t(),
            repo: Path.t(),
            connection_id: String.t() | nil,
            runner_ids: %{optional(String.t()) => String.t()} | nil
          }
  end

  @type t :: Add.t() | Import.t() | Patch.t()
end
