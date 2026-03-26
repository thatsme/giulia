defmodule Giulia.Tools.TracePath do
  @moduledoc """
  Trace the shortest dependency path between two modules.

  Uses the Knowledge Graph to answer "how are these two modules connected?"
  Uses Dijkstra's algorithm via libgraph.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Giulia.Knowledge.Store

  @behaviour Giulia.Tools.Registry

  @primary_key false
  embedded_schema do
    field :from, :string
    field :to, :string
  end

  @impl true
  def name, do: "trace_path"

  @impl true
  def description, do: "Find the shortest dependency path between two modules or functions."

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        from: %{
          type: "string",
          description: "Source module or function (e.g., 'Giulia.Tools.EditFile')"
        },
        to: %{
          type: "string",
          description: "Target module or function (e.g., 'Giulia.Inference.Orchestrator')"
        }
      },
      required: ["from", "to"]
    }
  end

  def changeset(params) do
    %__MODULE__{}
    |> cast(params, [:from, :to])
    |> validate_required([:from, :to])
  end

  @spec execute(map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  @impl true
  def execute(params, opts \\ [])

  def execute(%__MODULE__{from: from, to: to}, opts) do
    project_path = opts[:project_path]
    case Store.trace_path(project_path, from, to) do
      {:ok, :no_path} ->
        {:ok, "No dependency path found between #{from} and #{to}.\nThey are in separate components of the dependency graph."}

      {:ok, path} when is_list(path) ->
        format_path(from, to, path)

      {:error, {:not_found, vertex}} ->
        {:ok, "'#{vertex}' not found in knowledge graph. Run a scan first."}
    end
  end

  def execute(%{"from" => _} = params, opts) do
    case parse_params(params) do
      {:ok, struct} -> execute(struct, opts)
      {:error, _} = error -> error
    end
  end

  def execute(%{from: _} = params, opts) do
    execute(stringify_keys(params), opts)
  end

  defp format_path(from, to, path) do
    hops = length(path) - 1

    path_display =
      path
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {vertex, idx} ->
        if idx < length(path) - 1 do
          "  #{vertex} ->"
        else
          "  #{vertex}"
        end
      end)

    info = """
    Path from #{from} to #{to} (#{hops} hop(s)):
    ================================================

    #{path_display}
    """

    {:ok, String.trim(info)}
  end

  defp parse_params(params) do
    changeset = changeset(params)
    if changeset.valid? do
      {:ok, Ecto.Changeset.apply_changes(changeset)}
    else
      {:error, :invalid_params}
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
