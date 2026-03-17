defmodule Giulia.AST.Parser do
  @moduledoc """
  Low-level Sourceror parsing — shared by Processor, Analysis, and other AST modules.

  Extracted from Processor (Build 138) to break the Analysis <-> Processor
  dependency cycle. Both modules now depend on Parser instead of each other.
  """

  @type ast :: Macro.t()
  @type parse_result :: {:ok, ast(), String.t()} | {:error, term()}

  @doc """
  Parse Elixir source code using Sourceror.
  Returns {:ok, ast, source} or {:error, reason}.
  """
  @spec parse(String.t()) :: parse_result()
  def parse(source) when is_binary(source) do
    case Sourceror.parse_string(source) do
      {:ok, ast} -> {:ok, ast, source}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Parse a file from disk.
  """
  @spec parse_file(String.t()) :: parse_result()
  def parse_file(path) do
    with {:ok, source} <- File.read(path),
         true <- String.valid?(source),
         {:ok, ast} <- Sourceror.parse_string(source) do
      {:ok, ast, source}
    else
      false -> {:error, :invalid_utf8}
      error -> error
    end
  end
end
