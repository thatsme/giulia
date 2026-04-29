defmodule Giulia.MCP.Dispatch.Search do
  @moduledoc """
  MCP dispatch handlers for the `search_*` tool family.
  """

  import Giulia.MCP.Dispatch.Helpers

  alias Giulia.Core.{PathMapper, PathSandbox}
  alias Giulia.Intelligence.SemanticIndex
  alias Giulia.Tools.SearchCode

  @spec text(map()) :: {:ok, term()} | {:error, String.t()}
  def text(args) do
    with {:ok, pattern} <- require_param(args, "pattern") do
      path = args["path"]
      resolved = if path, do: PathMapper.resolve_path(path), else: nil
      sandbox = if resolved, do: PathSandbox.new(resolved), else: nil
      result = SearchCode.execute(pattern, sandbox)
      {:ok, result}
    end
  end

  @spec semantic(map()) :: {:ok, map()} | {:error, String.t()}
  def semantic(args) do
    with {:ok, path} <- require_path(args),
         {:ok, concept} <- require_param(args, "concept") do
      top_k = parse_int(args["top_k"], 5)

      case SemanticIndex.search(path, concept, top_k) do
        {:ok, results} ->
          {:ok, %{results: results, count: length(results), concept: concept}}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  @spec semantic_status(map()) :: {:ok, term()} | {:error, String.t()}
  def semantic_status(args) do
    with {:ok, path} <- require_path(args) do
      {:ok, SemanticIndex.status(path)}
    end
  end
end
