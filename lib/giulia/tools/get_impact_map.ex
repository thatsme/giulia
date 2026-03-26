defmodule Giulia.Tools.GetImpactMap do
  @moduledoc """
  Impact analysis tool — shows what depends on a module and what it depends on.

  Uses the Knowledge Graph to answer "if I change X, what breaks?"
  No file reading required — queries the in-memory graph directly.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Giulia.Knowledge.Store

  @behaviour Giulia.Tools.Registry

  @primary_key false
  embedded_schema do
    field :module, :string
    field :depth, :integer, default: 2
  end

  @impl true
  def name, do: "get_impact_map"

  @impl true
  def description, do: "Show what depends on a module and what it depends on. Use for change impact analysis."

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        module: %{
          type: "string",
          description: "Full module name (e.g., 'Giulia.Tools.EditFile')"
        },
        depth: %{
          type: "integer",
          description: "How deep to traverse the dependency graph (default: 2)"
        }
      },
      required: ["module"]
    }
  end

  def changeset(params) do
    %__MODULE__{}
    |> cast(params, [:module, :depth])
    |> validate_required([:module])
  end

  @spec execute(map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  @impl true
  def execute(params, opts \\ [])

  def execute(%__MODULE__{module: module, depth: depth}, opts) do
    project_path = opts[:project_path]
    case Store.impact_map(project_path, module, depth || 2) do
      {:ok, impact} ->
        format_impact_map(impact)

      {:error, {:not_found, vertex_id, suggestions, density}} ->
        sparse_warning = if density.sparse do
          "\n\nWARNING: Knowledge Graph is SPARSE (#{density.vertices} vertices, #{density.edges} edges). " <>
          "This usually means the project hasn't been scanned yet. Try running /scan in the project root."
        else
          ""
        end

        if suggestions != [] do
          {:ok, "Module '#{vertex_id}' not found. Similar modules in the graph:\n" <>
            Enum.map_join(suggestions, "\n", &"  - #{&1}") <>
            "\n\nTry one of these module names instead." <> sparse_warning}
        else
          {:ok, "Module '#{vertex_id}' not found in knowledge graph. " <>
            "No similar modules found." <> sparse_warning}
        end

      # Legacy format without density info
      {:error, {:not_found, vertex_id, suggestions}} ->
        if suggestions != [] do
          {:ok, "Module '#{vertex_id}' not found. Similar:\n#{Enum.map_join(suggestions, "\n", &"  - #{&1}")}"}
        else
          {:ok, "Module '#{vertex_id}' not found in knowledge graph. Run a scan first."}
        end
    end
  end

  def execute(%{"module" => _} = params, opts) do
    case parse_params(params) do
      {:ok, struct} -> execute(struct, opts)
      {:error, _} = error -> error
    end
  end

  def execute(%{module: _} = params, opts) do
    execute(stringify_keys(params), opts)
  end

  defp format_impact_map(%{vertex: vertex, upstream: upstream, downstream: downstream, function_edges: func_edges, depth: depth}) do
    upstream_section =
      if upstream == [] do
        "  (none — no dependencies)"
      else
        Enum.map_join(upstream, "\n", fn {mod, d} ->
          indicator = if d == 1, do: "direct", else: "depth #{d}"
          "  - #{mod} (#{indicator})"
        end)
      end

    downstream_section =
      if downstream == [] do
        "  (none — nothing depends on this)"
      else
        Enum.map_join(downstream, "\n", fn {mod, d} ->
          indicator = if d == 1, do: "direct", else: "depth #{d}"
          "  - #{mod} (#{indicator})"
        end)
      end

    func_section =
      if func_edges == [] do
        ""
      else
        "\nFUNCTIONS (call graph):\n" <>
        Enum.map_join(func_edges, "\n", fn {func_name, targets} ->
          target_list = Enum.join(targets, ", ")
          "  - #{func_name} -> #{target_list}"
        end)
      end

    downstream_direct = Enum.count(downstream, fn {_mod, d} -> d == 1 end)

    info = """
    Impact Map for #{vertex} (depth: #{depth})
    ================================================

    UPSTREAM (what I depend on):
    #{upstream_section}

    DOWNSTREAM (what depends on me):
    #{downstream_section}
    #{func_section}

    If you modify this module, #{downstream_direct} module(s) may be directly affected.
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
