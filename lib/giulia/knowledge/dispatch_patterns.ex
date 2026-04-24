defmodule Giulia.Knowledge.DispatchPatterns do
  @moduledoc """
  Loads runtime-dispatch pattern definitions from
  `priv/config/dispatch_patterns.json` and extracts {Module, function, arity}
  entry points from a target project based on those patterns.

  The config file declares a list of patterns, each with a `type`:

  - `text_match` — walk files matching `file_glob`, extract MFAs via
    `call_regex` capture groups. Example: Mix Release overlay shell
    scripts calling `<app> eval Module.function`.

  - `use_based_function_regex` — find modules that `use`/`@behaviour`
    one of the named `behaviours`, then exempt any function in those
    modules whose name matches `function_regex` with the given `arity`.
    Example: ExMachina `*_factory/0` functions dispatched by name.

  Adding or tuning a pattern is a JSON edit plus a daemon restart —
  no code change.
  """

  require Logger

  @config_file "config/dispatch_patterns.json"

  @doc """
  Return the full parsed config. Reads from Giulia's priv directory
  once per call; caller can memoize if needed.
  """
  @spec load() :: map()
  def load do
    path = Path.join(:code.priv_dir(:giulia) |> to_string(), @config_file)

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, map} ->
            map

          {:error, reason} ->
            Logger.warning("DispatchPatterns: invalid JSON at #{path}: #{inspect(reason)}")
            %{}
        end

      {:error, reason} ->
        Logger.warning("DispatchPatterns: cannot read #{path}: #{inspect(reason)}")
        %{}
    end
  end

  @doc """
  Walk the target project for all configured dispatch patterns and
  return the union of discovered {module, function_name, arity}
  entries. Pattern types requiring AST data (`use_based_function_regex`)
  use the supplied `all_asts` + `all_functions`; file-text types
  (`text_match`) re-read files from disk under `project_path`.
  """
  @spec entry_points(String.t(), map(), [map()]) ::
          MapSet.t({String.t(), String.t(), non_neg_integer()})
  def entry_points(project_path, all_asts, all_functions) do
    patterns = load()["patterns"] || []

    patterns
    |> Enum.reduce(MapSet.new(), fn pattern, acc ->
      entries = scan_pattern(pattern, project_path, all_asts, all_functions)
      Enum.reduce(entries, acc, &MapSet.put(&2, &1))
    end)
  end

  # Dispatch to the pattern-type-specific scanner.
  defp scan_pattern(%{"type" => "text_match"} = p, project_path, _asts, _funcs) do
    scan_text_match(project_path, p)
  end

  defp scan_pattern(%{"type" => "use_based_function_regex"} = p, _path, asts, funcs) do
    scan_use_based(asts, funcs, p)
  end

  defp scan_pattern(%{"type" => "meta_macro_using_apply"} = p, _path, asts, _funcs) do
    if Map.get(p, "enabled", true), do: scan_meta_macro_using_apply(asts), else: []
  end

  defp scan_pattern(pattern, _path, _asts, _funcs) do
    Logger.warning(
      "DispatchPatterns: unknown pattern type #{inspect(Map.get(pattern, "type"))} " <>
        "in entry #{inspect(Map.get(pattern, "id"))} — skipped."
    )

    []
  end

  # --- text_match ---
  defp scan_text_match(project_path, pattern) do
    with {:ok, glob} <- Map.fetch(pattern, "file_glob"),
         {:ok, regex_src} <- Map.fetch(pattern, "call_regex"),
         {:ok, regex} <- Regex.compile(regex_src, "m"),
         {:ok, arity} <- Map.fetch(pattern, "arity"),
         {:ok, capture} <- Map.fetch(pattern, "capture") do
      mod_idx = capture["module"]
      fn_idx = capture["function"]

      project_path
      |> Path.join(glob)
      |> Path.wildcard()
      |> Enum.flat_map(fn file ->
        case File.read(file) do
          {:ok, body} ->
            regex
            |> Regex.scan(body)
            |> Enum.map(fn captures ->
              {Enum.at(captures, mod_idx), Enum.at(captures, fn_idx), arity}
            end)

          _ ->
            []
        end
      end)
    else
      :error -> []
      {:error, _} -> []
    end
  end

  # --- use_based_function_regex ---
  defp scan_use_based(all_asts, all_functions, pattern) do
    with {:ok, behaviours} <- Map.fetch(pattern, "behaviours"),
         {:ok, regex_src} <- Map.fetch(pattern, "function_regex"),
         {:ok, regex} <- Regex.compile(regex_src),
         {:ok, arity} <- Map.fetch(pattern, "arity") do
      behaviour_set = MapSet.new(behaviours)
      matching_modules = modules_using(all_asts, behaviour_set)

      all_functions
      |> Enum.filter(fn f ->
        f.arity == arity and
          MapSet.member?(matching_modules, f.module) and
          Regex.match?(regex, to_string(f.name))
      end)
      |> Enum.map(fn f -> {f.module, to_string(f.name), f.arity} end)
    else
      _ -> []
    end
  end

  # Collect the set of module names declared in files that `use` or
  # `@behaviour` any of the named behaviour modules.
  defp modules_using(all_asts, behaviour_set) do
    all_asts
    |> Enum.flat_map(fn {_path, data} ->
      imports = data[:imports] || []

      uses_any =
        Enum.any?(imports, fn imp ->
          imp.type in [:use, :behaviour] and
            MapSet.member?(behaviour_set, imp.module)
        end)

      if uses_any, do: Enum.map(data[:modules] || [], & &1.name), else: []
    end)
    |> MapSet.new()
  end

  # --- meta_macro_using_apply ---
  #
  # Two-pass: (1) parse every source file, detect modules whose
  # `defmacro __using__(arg)` body contains `apply(__MODULE__, arg, [])`.
  # (2) re-scan the parsed ASTs for `use <detected_mod>, :atom` call
  # sites, emitting `{detected_mod, atom, 0}` exemptions.
  defp scan_meta_macro_using_apply(all_asts) do
    parsed = parse_sources_concurrently(all_asts)
    meta_modules = detect_meta_modules(parsed)

    if MapSet.size(meta_modules) == 0 do
      []
    else
      find_meta_callers(parsed, all_asts, meta_modules)
    end
  end

  defp parse_sources_concurrently(all_asts) do
    all_asts
    |> Task.async_stream(
      fn {path, _} ->
        with {:ok, content} <- File.read(path),
             {:ok, ast} <- Sourceror.parse_string(content) do
          {path, ast}
        else
          _ -> nil
        end
      end,
      max_concurrency: System.schedulers_online(),
      timeout: 15_000
    )
    |> Enum.reduce(%{}, fn
      {:ok, {path, ast}}, acc -> Map.put(acc, path, ast)
      _, acc -> acc
    end)
  end

  # Walk each AST tracking the enclosing-module stack. At each
  # `defmacro __using__` clause whose body contains a matching apply,
  # record the current enclosing module's full name.
  defp detect_meta_modules(parsed) do
    parsed
    |> Enum.reduce(MapSet.new(), fn {_path, ast}, acc ->
      {_, {found, _stack}} =
        Macro.traverse(
          ast,
          {acc, []},
          fn node, {set, stack} ->
            case defmodule_name_from_node(node) do
              {:ok, local} ->
                full = join_stack(stack, local)
                new_set =
                  if module_body_has_meta_using?(node),
                    do: MapSet.put(set, full),
                    else: set

                {node, {new_set, [full | stack]}}

              :skip ->
                {node, {set, stack}}
            end
          end,
          fn node, {set, stack} ->
            case defmodule_name_from_node(node) do
              {:ok, _} ->
                case stack do
                  [_ | rest] -> {node, {set, rest}}
                  [] -> {node, {set, []}}
                end

              :skip ->
                {node, {set, stack}}
            end
          end
        )

      found
    end)
  end

  defp defmodule_name_from_node({:defmodule, _, [{:__aliases__, _, parts} | _]})
       when is_list(parts) do
    {:ok, parts |> Enum.map(&safe_atom_to_string/1) |> Enum.join(".")}
  end

  defp defmodule_name_from_node(_), do: :skip

  defp join_stack([], local), do: local
  defp join_stack([top | _], local), do: "#{top}.#{local}"

  defp safe_atom_to_string(part) when is_atom(part), do: Atom.to_string(part)
  defp safe_atom_to_string({:__MODULE__, _, _}), do: "__MODULE__"
  defp safe_atom_to_string({atom, _, _}) when is_atom(atom), do: Atom.to_string(atom)
  defp safe_atom_to_string(other), do: inspect(other)

  # Inspect the defmodule's body for any `defmacro __using__(arg)` clause
  # where `arg` is a real variable (not `_`) and the clause body contains
  # `apply(__MODULE__, arg, [])` (empty-list arg-list — arity 0).
  defp module_body_has_meta_using?({:defmodule, _, args}) do
    body = module_body(args)

    {_, found} =
      Macro.traverse(
        body,
        false,
        fn node, acc ->
          {node, acc or defmacro_using_matches?(node)}
        end,
        fn node, acc -> {node, acc} end
      )

    found
  end

  defp module_body_has_meta_using?(_), do: false

  defp module_body([_aliases, kw]), do: get_do(kw)
  defp module_body(_), do: nil

  # Extract the `do:` value from either standard Elixir AST
  # (`[do: body]`) or Sourceror's wrapped form
  # (`[{{:__block__, _, [:do]}, body}]`).
  defp get_do([{{:__block__, _, [:do]}, body} | _]), do: body
  defp get_do([do: body]), do: body
  defp get_do(kw) when is_list(kw), do: Keyword.get(kw, :do)
  defp get_do(_), do: nil

  # Match:
  #   defmacro __using__(arg) do apply(__MODULE__, arg, []) end
  # or with a guard:
  #   defmacro __using__(arg) when is_atom(arg), do: apply(__MODULE__, arg, [])
  defp defmacro_using_matches?({:defmacro, _, [head, body_kw]}) do
    with arg when is_atom(arg) and arg != :_ <- using_arg_name(head),
         body when not is_nil(body) <- get_do(body_kw) do
      body_has_apply_dispatch?(body, arg)
    else
      _ -> false
    end
  end

  defp defmacro_using_matches?(_), do: false

  # An empty-list literal under Sourceror may appear as `[]` directly
  # or as `{:__block__, _, [[]]}`.
  defp empty_list_literal?([]), do: true
  defp empty_list_literal?({:__block__, _, [[]]}), do: true
  defp empty_list_literal?(_), do: false

  defp using_arg_name({:__using__, _, [{arg, _, _}]}) when is_atom(arg), do: arg

  defp using_arg_name({:when, _, [{:__using__, _, [{arg, _, _}]}, _guard]})
       when is_atom(arg),
       do: arg

  defp using_arg_name(_), do: nil

  defp body_has_apply_dispatch?(body, arg_name) do
    {_, found} =
      Macro.traverse(
        body,
        false,
        fn
          {:apply, _, [{:__MODULE__, _, _}, {^arg_name, _, _}, args_list]} = node, acc ->
            {node, acc or empty_list_literal?(args_list)}

          node, acc ->
            {node, acc}
        end,
        fn node, acc -> {node, acc} end
      )

    found
  end

  # For each parsed AST, walk for `use <detected_meta>, :atom` calls and
  # emit `{meta_mod, atom_str, 0}` triples. Resolves the module alias via
  # the caller file's alias_map (from already-extracted imports).
  defp find_meta_callers(parsed, all_asts, meta_modules) do
    asts_by_path = Map.new(all_asts, fn {path, data} -> {path, data} end)

    parsed
    |> Enum.flat_map(fn {path, ast} ->
      alias_map = build_alias_map(Map.get(asts_by_path, path) || %{})
      walk_use_callers(ast, alias_map, meta_modules)
    end)
  end

  defp build_alias_map(data) do
    (data[:imports] || [])
    |> Enum.filter(fn imp -> imp.type == :alias end)
    |> Map.new(fn imp ->
      short = imp.module |> String.split(".") |> List.last()
      {short, imp.module}
    end)
  end

  defp walk_use_callers(ast, alias_map, meta_modules) do
    {_, found} =
      Macro.traverse(
        ast,
        [],
        fn
          {:use, _, [{:__aliases__, _, parts}, second_arg]} = node, acc ->
            case unwrap_atom(second_arg) do
              {:ok, atom_name} ->
                resolved = resolve_alias(parts, alias_map)

                if MapSet.member?(meta_modules, resolved) do
                  {node, [{resolved, Atom.to_string(atom_name), 0} | acc]}
                else
                  {node, acc}
                end

              :skip ->
                {node, acc}
            end

          node, acc ->
            {node, acc}
        end,
        fn node, acc -> {node, acc} end
      )

    found
  end

  # Second arg of `use Mod, :atom` may appear raw (standard AST) or
  # wrapped by Sourceror as `{:__block__, _, [:atom]}`.
  defp unwrap_atom(atom) when is_atom(atom) and atom != :_, do: {:ok, atom}
  defp unwrap_atom({:__block__, _, [atom]}) when is_atom(atom) and atom != :_, do: {:ok, atom}
  defp unwrap_atom(_), do: :skip

  defp resolve_alias(parts, alias_map) do
    segs = Enum.map(parts, &safe_atom_to_string/1)

    case segs do
      [first | rest] ->
        case Map.get(alias_map, first) do
          nil -> Enum.join(segs, ".")
          full -> Enum.join([full | rest], ".")
        end

      [] ->
        ""
    end
  end
end
