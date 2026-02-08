defmodule Giulia.Tools.SearchMeaning do
  @moduledoc """
  Semantic code search tool — finds modules and functions by concept, not keyword.

  Uses the Dual-Key Embedding Strategy:
  1. Architectural Vectors (module-level) for broad discovery
  2. Surgical Vectors (function-level) for precise targeting

  Returns :error with clear message if EmbeddingServing is unavailable.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @behaviour Giulia.Tools.Registry

  @primary_key false
  embedded_schema do
    field :concept, :string
    field :top_k, :integer, default: 5
  end

  @impl true
  def name, do: "search_meaning"

  @impl true
  def description,
    do:
      "Search for code by semantic concept. Finds modules and functions by meaning, not keywords. Use when the exact name is unknown."

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        concept: %{
          type: "string",
          description: "Natural language description of what you're looking for (e.g., 'authentication logic', 'path translation')"
        },
        top_k: %{
          type: "integer",
          description: "Maximum number of function results to return (default: 5)"
        }
      },
      required: ["concept"]
    }
  end

  def changeset(params) do
    %__MODULE__{}
    |> cast(params, [:concept, :top_k])
    |> validate_required([:concept])
  end

  @impl true
  def execute(params, opts \\ [])

  def execute(%__MODULE__{} = search, opts) do
    project_path = Keyword.get(opts, :project_path) || get_project_path(opts)

    case Giulia.Intelligence.SemanticIndex.search(project_path, search.concept, search.top_k) do
      {:ok, %{modules: modules, functions: functions}} ->
        formatted = format_results(search.concept, modules, functions)
        {:ok, formatted}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(%{"concept" => _} = params, opts) do
    case parse_params(params) do
      {:ok, struct} -> execute(struct, opts)
      {:error, _} = error -> error
    end
  end

  def execute(%{concept: _} = params, opts) do
    execute(stringify_keys(params), opts)
  end

  # --- Formatting ---

  defp format_results(concept, modules, functions) do
    mod_section =
      if modules != [] do
        lines =
          modules
          |> Enum.with_index(1)
          |> Enum.map_join("\n", fn {m, i} ->
            doc = m.metadata[:moduledoc] || ""
            doc_preview = if doc != "", do: " -- #{String.slice(doc, 0, 80)}", else: ""
            "  #{i}. #{m.id} (#{m.score})#{doc_preview}"
          end)

        "Top modules for \"#{concept}\":\n#{lines}"
      else
        "No matching modules found."
      end

    func_section =
      if functions != [] do
        lines =
          functions
          |> Enum.with_index(1)
          |> Enum.map_join("\n", fn {f, i} ->
            file = f.metadata[:file] || "unknown"
            line = f.metadata[:line] || 0
            "  #{i}. #{f.id} (#{f.score}) -- #{file}:#{line}"
          end)

        "\nRelevant functions:\n#{lines}"
      else
        "\nNo matching functions found."
      end

    mod_section <> func_section
  end

  # --- Param handling ---

  defp parse_params(params) do
    changeset = changeset(params)

    if changeset.valid? do
      {:ok, Ecto.Changeset.apply_changes(changeset)}
    else
      {:error, :invalid_params}
    end
  end

  defp get_project_path(opts) do
    case Keyword.get(opts, :sandbox) do
      nil -> File.cwd!()
      sandbox -> sandbox.root
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
