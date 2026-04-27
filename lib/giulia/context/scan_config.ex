defmodule Giulia.Context.ScanConfig do
  @moduledoc """
  Runtime-loaded scan configuration — lists the directories within a
  target project that Giulia walks for Elixir source files.

  Config lives in `priv/config/scan_defaults.json` (inside Giulia's
  install, NOT the analyzed codebase). Adding a new source root is a
  JSON edit + daemon restart; no code change.
  """

  require Logger

  @config_file "config/scan_defaults.json"

  @doc """
  Return the list of relative directory paths to scan in a target
  project. Resolution order:

  1. Read `priv/config/scan_defaults.json`, return its `source_roots`
     list if well-formed.
  2. On any read/parse failure, log an error and return `["lib"]`
     as a minimal safe fallback (every Mix project has lib/).
  """
  @spec source_roots() :: [String.t()]
  def source_roots do
    case read_config() do
      %{"source_roots" => roots} when is_list(roots) and roots != [] ->
        Enum.filter(roots, &is_binary/1)

      other ->
        Logger.error(
          "Giulia.Context.ScanConfig: priv/config/scan_defaults.json " <>
            "missing or malformed (got: #{inspect(other)}). Falling back to [\"lib\"]."
        )

        ["lib"]
    end
  end

  @doc """
  Expand `source_roots/0` (config defaults) UNIONED with any paths
  extracted from the target project's `mix.exs` `elixirc_paths/1`
  clauses. Drops entries that don't exist on disk. Returns absolute
  paths pointing at either directories (to be walked) or individual
  .ex/.exs files (to be included as-is). The caller distinguishes
  with `File.dir?/1`.

  `mix.exs` is authoritative when present: Elixir projects can declare
  non-standard compile roots (e.g. `extra/lib`, generated dirs) in
  per-env clauses; taking the union across all clauses gives the
  broadest scan that matches what the project actually compiles.
  """
  @spec absolute_roots(String.t()) :: [String.t()]
  def absolute_roots(project_path) do
    config_roots = source_roots()
    mix_roots = mix_exs_roots(project_path)

    (config_roots ++ mix_roots)
    |> Enum.uniq()
    |> Enum.map(&Path.join(project_path, &1))
    |> Enum.filter(&File.exists?/1)
  end

  @doc """
  Parse the target project's `mix.exs` for `def`/`defp elixirc_paths`
  clauses and return the union of all string paths referenced. Works
  across the standard Mix idiom of env-dispatched clauses, e.g.

      defp elixirc_paths(:test), do: ["lib", "test/support"]
      defp elixirc_paths(_), do: ["lib"]

  Returns `[]` if `mix.exs` is missing or unparseable.
  """
  @spec mix_exs_roots(String.t()) :: [String.t()]
  def mix_exs_roots(project_path) do
    mix_path = Path.join(project_path, "mix.exs")

    with true <- File.regular?(mix_path),
         {:ok, content} <- File.read(mix_path),
         {:ok, ast} <- Sourceror.parse_string(content) do
      extract_elixirc_paths(ast)
    else
      _ -> []
    end
  end

  @doc """
  Returns `true` when the target project's `mix.exs` declares an
  `application/0` callback whose return value contains a `:mod` entry
  (i.e. the project is an OTP application with a top-level supervision
  tree, e.g. `def application, do: [mod: {MyApp.Application, []}]`).

  Returns `false` for library-shaped projects (no `:mod`, or no
  `application/0` clause at all) and for any project where `mix.exs`
  cannot be read or parsed. The library/app distinction drives the
  `:library_public_api` dead-code category — public functions in a
  library are exported for external consumers the static analyzer
  cannot see, so dead-code residuals on `def`s in libraries are
  honestly classified rather than reported as bugs.
  """
  @spec application_mod?(String.t()) :: boolean()
  def application_mod?(project_path) do
    mix_path = Path.join(project_path, "mix.exs")

    with true <- File.regular?(mix_path),
         {:ok, content} <- File.read(mix_path),
         {:ok, ast} <- Sourceror.parse_string(content) do
      detect_application_mod(ast)
    else
      _ -> false
    end
  end

  @doc """
  Returns the configured list of directories from which
  `POST /api/index/enrichment` will accept a `payload_path`. Entries
  may be absolute (`/tmp`) or project-relative (`tmp`, `_build`).
  Project-relative entries are resolved against the caller's project
  path before validation.

  Defaults from `priv/config/scan_defaults.json` `enrichment_payload_roots`;
  falls back to `["/tmp", "/var/tmp"]` if the key is missing or
  malformed (avoids accepting arbitrary paths if the config is
  damaged).
  """
  @spec enrichment_payload_roots() :: [String.t()]
  def enrichment_payload_roots do
    case read_config() do
      %{"enrichment_payload_roots" => roots} when is_list(roots) and roots != [] ->
        Enum.filter(roots, &is_binary/1)

      _ ->
        ["/tmp", "/var/tmp"]
    end
  end

  @doc """
  Validates that `payload_path` falls under one of the allowed roots
  for the given project. Returns `:ok` or `{:error, :path_not_allowed}`.

  Allowed roots are the absolute entries plus each project-relative
  entry resolved against `project_path`. Symlink resolution is
  intentionally NOT performed — the allowlist applies to the raw
  caller-supplied path so a malicious symlink in `/tmp` cannot
  smuggle in `/etc/passwd`.
  """
  @spec validate_enrichment_payload_path(String.t(), String.t()) ::
          :ok | {:error, :path_not_allowed}
  def validate_enrichment_payload_path(payload_path, project_path)
      when is_binary(payload_path) and is_binary(project_path) do
    expanded = Path.expand(payload_path)

    allowed_roots =
      enrichment_payload_roots()
      |> Enum.map(fn root ->
        if Path.type(root) == :absolute do
          Path.expand(root)
        else
          Path.expand(Path.join(project_path, root))
        end
      end)

    if Enum.any?(allowed_roots, fn root -> path_under?(expanded, root) end) do
      :ok
    else
      {:error, :path_not_allowed}
    end
  end

  defp path_under?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  # Walk the mix.exs AST for every `def`/`defp elixirc_paths(_)` clause
  # and collect string literals appearing in its body. Union them across
  # all clauses. Tolerates the Sourceror wrapping of string literals in
  # `{:__block__, _, [value]}`.
  defp extract_elixirc_paths(ast) do
    {_, paths} =
      Macro.traverse(
        ast,
        [],
        fn
          {def_type, _, [{:elixirc_paths, _, _args}, body_kw]} = node, acc
          when def_type in [:def, :defp] ->
            body = get_do_value(body_kw)
            {node, acc ++ extract_string_literals(body)}

          node, acc ->
            {node, acc}
        end,
        fn node, acc -> {node, acc} end
      )

    paths |> Enum.uniq()
  end

  defp get_do_value([{{:__block__, _, [:do]}, body} | _]), do: body
  defp get_do_value(do: body), do: body
  defp get_do_value(kw) when is_list(kw), do: Keyword.get(kw, :do)
  defp get_do_value(_), do: nil

  defp extract_string_literals(nil), do: []

  defp extract_string_literals(node) do
    {_, strings} =
      Macro.traverse(
        node,
        [],
        fn
          {:__block__, _, [s]} = n, acc when is_binary(s) -> {n, [s | acc]}
          s = _binary, acc when is_binary(s) -> {s, [s | acc]}
          n, acc -> {n, acc}
        end,
        fn n, a -> {n, a} end
      )

    strings
  end

  defp read_config do
    path = Path.join(:code.priv_dir(:giulia) |> to_string(), @config_file)

    with {:ok, content} <- File.read(path),
         {:ok, map} <- Jason.decode(content) do
      map
    else
      {:error, reason} -> reason
    end
  end

  # Walk every `def`/`defp application` clause and return true if any
  # body contains the atom literal `:mod` as a keyword key. Sourceror
  # represents atom keyword keys as bare atoms in 2-tuples — we just
  # look for the atom `:mod` anywhere in the application/0 body, which
  # is sufficient: the only legal place for `:mod` in mix.exs's
  # application keyword is the OTP-mod entry.
  defp detect_application_mod(ast) do
    {_, found?} =
      Macro.traverse(
        ast,
        false,
        fn
          {def_type, _, [{:application, _, _args}, body_kw]} = node, acc
          when def_type in [:def, :defp] ->
            {node, acc or body_contains_mod?(get_do_value(body_kw))}

          node, acc ->
            {node, acc}
        end,
        fn node, acc -> {node, acc} end
      )

    found?
  end

  defp body_contains_mod?(nil), do: false

  defp body_contains_mod?(body) do
    {_, found?} =
      Macro.traverse(
        body,
        false,
        fn
          :mod = n, _acc -> {n, true}
          n, acc -> {n, acc}
        end,
        fn n, a -> {n, a} end
      )

    found?
  end
end
