defmodule Giulia.Tools.TestReferences do
  @moduledoc """
  Reference-based test-coverage detection.

  Replaces the file-naming `has_test_file?/2` heuristic for the
  `has_test` signal in heatmap / unprotected_hubs. The previous detector
  matched `lib/foo.ex` → `test/foo_test.exs` by path convention, which
  classified every module integration-tested under a different test
  filename as untested — inflating yellow zones on libraries that follow
  the (idiomatic) Elixir convention of one large protocol-level test
  file per concern.

  This module instead walks every `*_test.exs` file under the project's
  `test/` directory, parses it with Sourceror, and collects every project
  module *referenced* via:

    - `alias Mod.Name` (single + multi-form `alias Mod.{A, B}`)
    - `use Mod.Name[, opts]`
    - `import Mod.Name[, opts]`
    - `require Mod.Name[, opts]`
    - `@behaviour Mod.Name`
    - Fully-qualified function calls `Mod.Name.f(args)`
    - Struct literals `%Mod.Name{...}`
    - MFA tuples `{Mod.Name, :fn, args}`
    - Function captures `&Mod.Name.fn/N`
    - Bare 3-arg calls with module-shape arg1 (Task.start_link form)

  Universal: relies only on the standard Mix `test/**/*_test.exs`
  convention (no per-codebase config). Works on any project that follows
  it. The `RunTests.find_test_file/2` file-naming detector is preserved
  separately because it answers a different question — *which test
  file should mix run when I want to test this module?* — that does
  require path correspondence.

  The set is computed lazily per call. For the metrics path, it's
  computed once at the start of `heatmap_with_coupling` and reused
  for every module check.
  """

  require Logger

  @doc """
  Collect every project module name referenced from any `*_test.exs`
  file under `<project_path>/test/`. Returns a `MapSet` of fully-
  qualified module name strings.
  """
  @spec referenced_modules(String.t()) :: MapSet.t()
  def referenced_modules(project_path) when is_binary(project_path) do
    walk_test_files(project_path, MapSet.new(), &collect_from_ast/2)
  end

  @doc """
  Collect every fully-qualified function reference from any `*_test.exs`
  file under `<project_path>/test/`. Returns a `MapSet` of
  `"Mod.Name.fn/N"` strings. Only references whose arity is determinable
  at parse time are included — bare module references, captures with
  variable arity, and MFA tuples with non-literal arg lists are skipped.

  Used by `Giulia.Knowledge.DeadCodeClassifier` to mark dead-code
  candidates as `:test_only` when their only reachability signal is a
  test file.
  """
  @spec referenced_functions(String.t()) :: MapSet.t()
  def referenced_functions(project_path) when is_binary(project_path) do
    walk_test_files(project_path, MapSet.new(), &collect_functions_from_ast/2)
  end

  defp walk_test_files(project_path, init_acc, collector) do
    test_root = Path.join(project_path, "test")

    if File.dir?(test_root) do
      test_root
      |> Path.join("**/*_test.exs")
      |> Path.wildcard()
      |> Enum.reduce(init_acc, fn path, acc ->
        case File.read(path) do
          {:ok, source} ->
            case Sourceror.parse_string(source) do
              {:ok, ast} -> collector.(ast, acc)
              _ -> acc
            end

          _ ->
            acc
        end
      end)
    else
      init_acc
    end
  end

  defp collect_from_ast(ast, acc) do
    {_ast, refs} =
      Macro.prewalk(ast, acc, fn node, refs_acc ->
        {node, collect_from_node(node, refs_acc)}
      end)

    refs
  end

  defp collect_functions_from_ast(ast, acc) do
    {_ast, refs} =
      Macro.prewalk(ast, acc, fn node, refs_acc ->
        {node, collect_function_from_node(node, refs_acc)}
      end)

    refs
  end

  # alias Mod.Name (single)
  defp collect_from_node({:alias, _, [{:__aliases__, _, parts}]}, refs)
       when is_list(parts) do
    add_alias(refs, parts)
  end

  # alias Mod.Name, as: Foo (with opts)
  defp collect_from_node({:alias, _, [{:__aliases__, _, parts}, _opts]}, refs)
       when is_list(parts) do
    add_alias(refs, parts)
  end

  # alias Mod.{A, B, C} — multi-alias expansion
  defp collect_from_node(
         {:alias, _, [{{:., _, [{:__aliases__, _, prefix_parts}, :{}]}, _, suffixes}]},
         refs
       )
       when is_list(prefix_parts) and is_list(suffixes) do
    Enum.reduce(suffixes, refs, fn
      {:__aliases__, _, suffix_parts}, acc ->
        add_alias(acc, prefix_parts ++ suffix_parts)

      _, acc ->
        acc
    end)
  end

  # use / import / require Mod.Name [, opts]
  defp collect_from_node({directive, _, [{:__aliases__, _, parts} | _]}, refs)
       when directive in [:use, :import, :require] and is_list(parts) do
    add_alias(refs, parts)
  end

  # @behaviour Mod.Name
  defp collect_from_node(
         {:@, _, [{:behaviour, _, [{:__aliases__, _, parts}]}]},
         refs
       )
       when is_list(parts) do
    add_alias(refs, parts)
  end

  # Fully-qualified call: Mod.Name.fn(args)
  defp collect_from_node(
         {{:., _, [{:__aliases__, _, parts}, fn_name]}, _, _args},
         refs
       )
       when is_list(parts) and is_atom(fn_name) do
    add_alias(refs, parts)
  end

  # Struct literal: %Mod.Name{...}
  defp collect_from_node(
         {:%, _, [{:__aliases__, _, parts}, _struct_body]},
         refs
       )
       when is_list(parts) do
    add_alias(refs, parts)
  end

  # MFA tuple literal: {Mod.Name, :fn, args}
  defp collect_from_node(
         {:{}, _, [{:__aliases__, _, parts}, _fn_atom, _args]},
         refs
       )
       when is_list(parts) do
    add_alias(refs, parts)
  end

  # Capture: &Mod.Name.fn/N
  defp collect_from_node(
         {:&, _, [{:/, _, [{{:., _, [{:__aliases__, _, parts}, _fn]}, _, []}, _arity]}]},
         refs
       )
       when is_list(parts) do
    add_alias(refs, parts)
  end

  defp collect_from_node(_node, refs), do: refs

  defp add_alias(refs, parts) do
    name =
      parts
      |> Enum.map(&part_to_string/1)
      |> Enum.join(".")

    if name != "", do: MapSet.put(refs, name), else: refs
  end

  defp part_to_string(part) when is_atom(part), do: Atom.to_string(part)
  defp part_to_string({:__MODULE__, _, _}), do: "__MODULE__"
  defp part_to_string(other), do: inspect(other)

  # ============================================================================
  # Function-level reference collection (referenced_functions/1)
  # ============================================================================

  # Fully-qualified call: Mod.Name.fn(arg1, arg2)
  defp collect_function_from_node(
         {{:., _, [{:__aliases__, _, parts}, fn_name]}, _, args},
         refs
       )
       when is_list(parts) and is_atom(fn_name) and is_list(args) do
    add_function(refs, parts, fn_name, length(args))
  end

  # MFA tuple literal: {Mod.Name, :fn, [args]}
  defp collect_function_from_node(
         {:{}, _, [{:__aliases__, _, parts}, fn_atom, args_term]},
         refs
       )
       when is_list(parts) do
    case {resolve_atom_literal(fn_atom), resolve_list_arity(args_term)} do
      {{:ok, fn_name}, {:ok, arity}} -> add_function(refs, parts, fn_name, arity)
      _ -> refs
    end
  end

  # Capture: &Mod.Name.fn/N
  defp collect_function_from_node(
         {:&, _, [{:/, _, [{{:., _, [{:__aliases__, _, parts}, fn_name]}, _, []}, arity_term]}]},
         refs
       )
       when is_list(parts) and is_atom(fn_name) do
    case resolve_int_literal(arity_term) do
      {:ok, arity} -> add_function(refs, parts, fn_name, arity)
      :skip -> refs
    end
  end

  defp collect_function_from_node(_node, refs), do: refs

  defp add_function(refs, parts, fn_name, arity) do
    module = parts |> Enum.map(&part_to_string/1) |> Enum.join(".")

    if module != "" do
      MapSet.put(refs, "#{module}.#{fn_name}/#{arity}")
    else
      refs
    end
  end

  defp resolve_atom_literal(atom) when is_atom(atom) and atom not in [nil, true, false],
    do: {:ok, atom}

  defp resolve_atom_literal({:__block__, _, [atom]})
       when is_atom(atom) and atom not in [nil, true, false],
       do: {:ok, atom}

  defp resolve_atom_literal(_), do: :skip

  defp resolve_list_arity(list) when is_list(list), do: {:ok, length(list)}

  defp resolve_list_arity({:__block__, _, [list]}) when is_list(list),
    do: {:ok, length(list)}

  defp resolve_list_arity(_), do: :skip

  defp resolve_int_literal(int) when is_integer(int), do: {:ok, int}

  defp resolve_int_literal({:__block__, _, [int]}) when is_integer(int),
    do: {:ok, int}

  defp resolve_int_literal(_), do: :skip
end
