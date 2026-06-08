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

      case SearchCode.execute(%{"pattern" => pattern}, sandbox: sandbox) do
        {:ok, output} -> {:ok, output}
        {:error, :invalid_params} -> {:error, "Invalid search parameters"}
      end
    end
  end

  @spec semantic(map()) :: {:ok, map()} | {:error, String.t()}
  def semantic(args) do
    # Readiness via the shared edge; coercion + the canonical result shape live
    # in Search.Facade, shared with REST. This adopts the reshaped agent-facing
    # form (modules/functions with file/line/score, count = total) — replacing
    # the raw-struct shape MCP emitted before.
    case Giulia.Daemon.Edge.resolve_ready(args) do
      {:error, :missing_path} ->
        {:error, "Missing required parameter: path"}

      {:not_ready, info} ->
        {:error, Giulia.Daemon.Edge.not_ready_message(info)}

      {:ok, path} ->
        case Giulia.Search.Facade.semantic(path, args) do
          {:ok, result} -> {:ok, result}
          {:error, :missing_concept} -> {:error, "Missing required parameter: concept (or q)"}
          {:error, reason} when is_binary(reason) -> {:error, reason}
          {:error, reason} -> {:error, inspect(reason)}
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
