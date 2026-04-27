defmodule Giulia.Tools.TemplateReferences do
  @moduledoc """
  Reference-based template-call detection.

  Walks every `*.heex` and `*.eex` file under a project root and
  extracts function references: qualified (`Module.Sub.fn`,
  `&Module.Sub.fn/N`, HEEx component `<Module.Sub.fn>`) and local
  (bare `fn(...)`, HEEx local component `<.fn>`).

  Used by the dead-code analyzer to exempt template-referenced
  functions from the dead list — closes the false positives where
  view helpers like `PlausibleWeb.LayoutView.plausible_url/0` are
  called only from templates and were otherwise invisible to the
  static AST walker.

  ## Resolution model

  HEEx + EEx have two distinct kinds of function reference:

    * **Qualified** — the template explicitly names the receiving
      module (`{Module.Sub.fn(args)}`, `&Module.Sub.fn/N`,
      `<Module.Sub.fn args />`). Resolve to `"Module.Sub.fn"`
      directly.

    * **Local** — the template invokes a function without a module
      prefix (`{plausible_url()}`, `<.flash_group flash={@flash} />`).
      Resolution requires knowing which View / LiveView / Component
      module the template is bound to. v1 uses Phoenix's path
      conventions:

      - `lib/<app>_web/templates/<view>/<file>.html.heex`
        → `<App>Web.<View>View` (older Phoenix layout)
      - `<dir>/<basename>.html.heex` colocated with `<dir>/<basename>.ex`
        → the module declared in that .ex file
        (LiveView / Components / colocated templates)

      Files whose path matches neither convention contribute their
      local refs to no module — those refs are simply dropped, an
      honest limit of static analysis.

  ## Output

      %{
        qualified: MapSet.t(),                  # "Mod.Sub.fn" strings (no arity)
        local_per_file: %{file_path => MapSet.t(fn_name)}
      }

  Arity is intentionally not preserved. Templates often elide arity
  (interpolation expressions don't carry arity info), and the
  consumer use case (dead-code exemption) needs name-level matching
  anyway — once any arity of `Mod.fn` is referenced from a template,
  every arity of `Mod.fn` is plausibly reachable.
  """

  require Logger

  @type result :: %{
          qualified: MapSet.t(),
          local_per_file: %{String.t() => MapSet.t()}
        }

  @doc """
  Walk the project's `.heex` / `.eex` files and return the reference
  set. Empty result for projects without templates.
  """
  @spec scan(String.t()) :: result()
  def scan(project_path) when is_binary(project_path) do
    files =
      Path.wildcard(Path.join([project_path, "**", "*.heex"])) ++
        Path.wildcard(Path.join([project_path, "**", "*.eex"]))

    Enum.reduce(files, %{qualified: MapSet.new(), local_per_file: %{}}, fn path, acc ->
      case File.read(path) do
        {:ok, source} -> ingest_file(acc, path, source)
        _ -> acc
      end
    end)
  end

  defp ingest_file(acc, path, source) do
    {qualified, locals} = extract_refs(source)

    %{
      qualified: MapSet.union(acc.qualified, qualified),
      local_per_file:
        if(MapSet.size(locals) == 0,
          do: acc.local_per_file,
          else: Map.put(acc.local_per_file, path, locals)
        )
    }
  end

  # ============================================================================
  # Per-file extraction
  # ============================================================================
  #
  # Three syntactic surfaces in HEEx + EEx:
  #
  #   * `<% expr %>` / `<%= expr %>` — old EEx, expression is plain Elixir
  #   * `{expr}` — HEEx interpolation, expression is plain Elixir (HEEx
  #     wraps in `<%= expr %>` at compile time)
  #   * `<Module.Sub.fn ...>` / `<.local_fn ...>` — HEEx component
  #     invocation
  #
  # We pull all expression text out via regex and let `extract_refs_from_text`
  # do the actual qualified/local sniffing on the joined text. Brace
  # balancing is approximate — nested `{}` inside attribute interpolations
  # could cause spillover; for the dead-code use case that's fine
  # (over-counting refs only over-exempts, never wrongly flags).

  defp extract_refs(source) do
    expr_chunks =
      Regex.scan(~r/<%=?\s*(.*?)\s*%>/s, source, capture: :all_but_first)
      |> List.flatten()

    brace_chunks =
      Regex.scan(~r/\{([^{}]+)\}/, source, capture: :all_but_first)
      |> List.flatten()

    expr_text = Enum.join(expr_chunks ++ brace_chunks, "\n")

    {expr_qualified, expr_locals} = extract_refs_from_text(expr_text)

    component_qualified =
      Regex.scan(~r/<([A-Z][\w.]*)\.([\w_!?]+)[\s\/>]/, source, capture: :all_but_first)
      |> Enum.map(fn [mod, fn_name] -> "#{mod}.#{fn_name}" end)
      |> MapSet.new()

    component_locals =
      Regex.scan(~r/<\.([\w_]+)[\s\/>]/, source, capture: :all_but_first)
      |> List.flatten()
      |> MapSet.new()

    {
      MapSet.union(expr_qualified, component_qualified),
      MapSet.union(expr_locals, component_locals)
    }
  end

  defp extract_refs_from_text(text) do
    # Greedy module capture: `MyApp.Helpers.greet` → mod="MyApp.Helpers",
    # fn="greet". Non-greedy `*?` truncates to mod="MyApp" / fn="Helpers"
    # (leaving the function name out of the captured ref).
    qualified =
      Regex.scan(~r/([A-Z][\w.]*)\.([\w_!?]+)/, text, capture: :all_but_first)
      |> Enum.map(fn [mod, fn_name] -> "#{mod}.#{fn_name}" end)
      |> MapSet.new()

    captures =
      Regex.scan(~r/&([A-Z][\w.]*)\.([\w_!?]+)\/(\d+)/, text, capture: :all_but_first)
      |> Enum.map(fn [mod, fn_name, _arity] -> "#{mod}.#{fn_name}" end)
      |> MapSet.new()

    locals =
      Regex.scan(~r/(?:^|[^\w.])([a-z_][\w_!?]*)\s*\(/, text, capture: :all_but_first)
      |> List.flatten()
      |> Enum.reject(&local_keyword?/1)
      |> MapSet.new()

    {MapSet.union(qualified, captures), locals}
  end

  # Don't treat Elixir keywords / common builtins as local function refs.
  @reserved_locals ~w(
    if unless case cond do end fn for with try catch rescue after else
    when in not and or true false nil
    raise throw send self spawn spawn_link
    is_atom is_binary is_boolean is_function is_integer is_list is_map
    is_nil is_number is_pid is_port is_reference is_tuple
  )
  defp local_keyword?(name), do: name in @reserved_locals

  # ============================================================================
  # Conventional View resolution
  # ============================================================================
  #
  # Given a template path, return the module name that local function
  # calls inside that template most likely resolve to. Returns nil if
  # no convention matches.
  #
  # Resolution order (try each, first match wins):
  #
  #   1. Strip `.heex` / `.eex` (and a preceding `.html` if present),
  #      append `.ex` — if that .ex file is in `module_index`, use the
  #      module declared there. Catches LiveView / Component / colocated
  #      templates.
  #
  #   2. Match `lib/<app>_web/templates/<view>/<basename>.html.heex` →
  #      `<App>Web.<View>View`. Older Phoenix template layout.

  @spec conventional_view_module(String.t(), %{String.t() => String.t()}) :: String.t() | nil
  def conventional_view_module(template_path, module_index) do
    sibling_match(template_path, module_index) ||
      legacy_template_match(template_path)
  end

  defp sibling_match(template_path, module_index) do
    candidate =
      template_path
      |> String.replace_suffix(".heex", "")
      |> String.replace_suffix(".eex", "")
      |> String.replace_suffix(".html", "")
      |> Kernel.<>(".ex")

    Map.get(module_index, candidate)
  end

  defp legacy_template_match(template_path) do
    case Regex.run(
           ~r{lib/([^/]+)_web/templates/([^/]+)/[^/]+$},
           template_path,
           capture: :all_but_first
         ) do
      [app, view] ->
        "#{Macro.camelize(app)}Web.#{Macro.camelize(view)}View"

      _ ->
        nil
    end
  end
end
