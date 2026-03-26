defmodule Giulia.Tools.SearchCode do
  @moduledoc """
  Search for patterns in project source files.

  State-first: reads the file list from ETS (populated by the Indexer),
  never touches the filesystem to discover files. Disk I/O only happens
  when reading file contents for matching.

  By default, searches only first-party code already indexed by the scanner.
  Pass `include_deps: true` to also search dependency source files.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Giulia.Core.PathSandbox

  @behaviour Giulia.Tools.Registry

  @primary_key false
  embedded_schema do
    field :pattern, :string
    field :file_pattern, :string, default: "*.ex"
    field :case_sensitive, :boolean, default: false
    field :include_deps, :boolean, default: false
    field :max_results, :integer, default: 20
  end

  @impl true
  @spec name() :: String.t()
  def name, do: "search_code"

  @impl true
  @spec description() :: String.t()
  def description, do: "Search for a pattern in project source files. Returns matching lines with file paths."

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      properties: %{
        pattern: %{
          type: "string",
          description: "Text or regex pattern to search for"
        },
        file_pattern: %{
          type: "string",
          description: "Glob pattern for files to search (default: '*.ex')"
        },
        case_sensitive: %{
          type: "boolean",
          description: "Case-sensitive search (default: false)"
        },
        include_deps: %{
          type: "boolean",
          description: "Include deps/ in search (default: false). Never includes _build/."
        },
        max_results: %{
          type: "integer",
          description: "Maximum number of results (default: 20)"
        }
      },
      required: ["pattern"]
    }
  end

  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(params) do
    %__MODULE__{}
    |> cast(params, [:pattern, :file_pattern, :case_sensitive, :include_deps, :max_results])
    |> validate_required([:pattern])
  end

  @impl true
  @spec execute(map() | %__MODULE__{}, keyword()) :: {:ok, String.t()} | {:error, :invalid_params}
  def execute(params, opts \\ [])

  def execute(%__MODULE__{} = search, opts) do
    sandbox = get_sandbox(opts)
    matcher = compile_matcher(search.pattern, search.case_sensitive)

    # State-first: file list comes from ETS, not disk
    files = filter_by_extension(Giulia.Context.Store.get_project_files(sandbox.root), search.file_pattern)

    # Parallel search across all cores with early termination
    results =
      files
      |> Task.async_stream(
        &search_file(&1, matcher, sandbox.root),
        max_concurrency: System.schedulers_online(),
        ordered: false,
        timeout: 30_000
      )
      |> Stream.flat_map(fn
        {:ok, matches} -> matches
        {:exit, _reason} -> []
      end)
      |> Enum.take(search.max_results)

    if results == [] do
      {:ok, "No matches found for '#{search.pattern}'"}
    else
      formatted = Enum.map_join(results, "\n", fn {file, line_num, line} ->
        "#{file}:#{line_num}: #{String.trim(line)}"
      end)
      {:ok, formatted}
    end
  end

  def execute(%{"pattern" => _} = params, opts) do
    case parse_params(params) do
      {:ok, struct} -> execute(struct, opts)
      {:error, _} = error -> error
    end
  end

  def execute(%{pattern: _} = params, opts) do
    execute(stringify_keys(params), opts)
  end

  # --- File search ---

  defp search_file(file_path, matcher, root) do
    case File.read(file_path) do
      {:ok, content} ->
        relative_path = Path.relative_to(file_path, root)

        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} -> match_line(line, matcher) end)
        |> Enum.map(fn {line, num} -> {relative_path, num, line} end)

      {:error, _} ->
        []
    end
  end

  # --- File list filtering ---

  defp filter_by_extension(files, "*"), do: files
  defp filter_by_extension(files, "*.*"), do: files

  defp filter_by_extension(files, pattern) do
    exts = exts_from_pattern(pattern)

    if exts == [] do
      files
    else
      Enum.filter(files, fn f -> Path.extname(f) in exts end)
    end
  end

  defp exts_from_pattern("*" <> ext), do: [ext]
  defp exts_from_pattern("*.{" <> rest) do
    rest |> String.trim_trailing("}") |> String.split(",") |> Enum.map(&("." <> &1))
  end
  defp exts_from_pattern(_), do: []

  # --- Pattern compilation ---

  defp compile_matcher(pattern, case_sensitive) do
    if regex_pattern?(pattern) do
      opts = if case_sensitive, do: [], else: [:caseless]
      case Regex.compile(pattern, Enum.join(opts)) do
        {:ok, regex} -> {:regex, regex}
        {:error, _} -> literal_matcher(pattern, case_sensitive)
      end
    else
      literal_matcher(pattern, case_sensitive)
    end
  end

  defp literal_matcher(pattern, true), do: {:literal_cs, pattern}
  defp literal_matcher(pattern, false), do: {:literal, String.downcase(pattern)}

  defp regex_pattern?(pattern) do
    String.contains?(pattern, ["\\", "^", "$", "*", "+", "?", "{", "[", "(", "|", "."])
  end

  defp match_line(line, {:regex, regex}), do: Regex.match?(regex, line)
  defp match_line(line, {:literal_cs, pattern}), do: :binary.match(line, pattern) != :nomatch
  defp match_line(line, {:literal, downcased}), do: :binary.match(String.downcase(line), downcased) != :nomatch

  # --- Param handling ---

  defp parse_params(params) do
    changeset = changeset(params)
    if changeset.valid? do
      {:ok, Ecto.Changeset.apply_changes(changeset)}
    else
      {:error, :invalid_params}
    end
  end

  defp get_sandbox(opts) do
    case Keyword.get(opts, :sandbox) do
      nil -> PathSandbox.new(File.cwd!())
      sandbox -> sandbox
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
