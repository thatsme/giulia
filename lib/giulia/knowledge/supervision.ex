defmodule Giulia.Knowledge.Supervision do
  @moduledoc """
  Supervision topology extraction — pure AST analysis.

  Backs Builder Pass 12. Parses `Supervisor.start_link/2`, `Supervisor.init/2`
  and `DynamicSupervisor.start_link/2` call sites into supervisor declarations
  with their child lists, so the knowledge graph can carry `{:supervises, ...}`
  edges.

  ## Identity

  Supervision identity is not module identity. In a typical OTP app the root
  supervisor is a *registered name* (`Giulia.Supervisor`) with no `defmodule`
  anywhere, several children are external modules (`Registry`, `Bandit`), and
  two `{DynamicSupervisor, name: X}` declarations share one module. One rule
  covers every endpoint:

      process key = name_option || module

  ## Bounded binding resolution

  Child lists are rarely literal arguments — the common idiom builds tiers in
  separate variables and concatenates them. Resolution is deliberately bounded
  to single-assignment variables, literal lists, `++` chains and `if`/`case`
  branches, all within the enclosing function. Anything else (function calls,
  `Enum.*`, config-driven lists) yields `children_unresolved: true` and **no**
  child edges: a partial child list presented as complete would become a false
  negative in every downstream check that reasons over this tree.

  ## Union per registered name

  One registered name may be started from several call sites — an app that
  starts an empty tree in client mode and a full tree in daemon mode uses the
  same name for both. Children are therefore unioned per key across all call
  sites, never taken from the first match. A child absent from some branch is
  flagged `conditional: true`.
  """

  # Recursion bound, not a modelling limit: it exists to stop runaway descent on
  # pathological input, so it must clear realistic nesting comfortably. The
  # tiered-children idiom alone reaches depth 9 — `children` → `if` → else
  # branch → `all_children ++ [extra]` → a five-variable `++` chain → each
  # tier's own `if`. A tight bound silently returns `children_unresolved: true`
  # for ordinary code, which is exactly the false negative this pass exists to
  # avoid.
  @max_binding_depth 32

  @type child :: %{
          key: String.t(),
          module: String.t() | nil,
          restart: :permanent | :transient | :temporary | :unknown,
          order: non_neg_integer(),
          conditional: boolean()
        }

  @type supervisor_decl :: %{
          key: String.t(),
          module: String.t() | nil,
          registered_name: String.t() | nil,
          dynamic: boolean(),
          strategy: String.t() | nil,
          children: [child()],
          children_unresolved: boolean()
        }

  @doc """
  Extract supervisor declarations from parsed project sources.

  Takes `%{file_path => ast_data_map}` as handed to `Builder.build_graph/1`.
  Returns one declaration per distinct process key, with children unioned
  across every call site that starts that key.
  """
  @spec extract(%{String.t() => map()}) :: [supervisor_decl()]
  def extract(ast_data) do
    ast_data
    |> Enum.flat_map(fn {path, _data} -> extract_from_file(path) end)
    |> Enum.reject(&is_nil(&1.key))
    |> merge_by_key()
  end

  @doc """
  Build the supervision tree from an already-built graph.

  Reads the `{:supervises, meta}` edges Pass 12 emitted rather than re-parsing
  source, so the endpoint serves whatever the current build contains. Returns
  the nested tree plus the flat edge list — the flat form is what Cytoscape
  consumes, the nested form is what humans read.

  Roots are supervisor vertices with no inbound `:supervises` edge. A
  supervision tree should never cycle, but `visited` guards the descent anyway:
  a fabricated cycle would otherwise hang the endpoint rather than show up as
  bad data.
  """
  @spec tree(Graph.t()) :: map()
  def tree(graph) do
    edges = supervises_edges(graph)
    by_parent = Enum.group_by(edges, & &1.from)
    child_keys = MapSet.new(edges, & &1.to)

    roots =
      by_parent
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(child_keys, &1))
      |> Enum.sort()

    # Counting edge sources alone undercounts: a DynamicSupervisor has no child
    # edges by construction, so a tree containing two of them reported
    # `supervisor_count: 2` while showing four supervisors — a count that
    # contradicts the tree it describes.
    #
    # The union with `:supervisor`-labelled vertices is still a lower bound, and
    # deliberately so: Pass 12 never re-labels an existing vertex, so a
    # supervisor that is also a project module keeps `[:module]` alone and is
    # only counted here if it has children. Under-reporting is the safe
    # direction for a summary figure.
    labelled_supervisors =
      graph
      |> Graph.vertices()
      |> Enum.filter(&(:supervisor in Graph.vertex_labels(graph, &1)))
      |> MapSet.new()

    supervisors =
      by_parent
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.union(labelled_supervisors)

    %{
      roots: Enum.map(roots, &build_node(&1, by_parent, MapSet.new())),
      edges: Enum.sort_by(edges, &{&1.from, &1.order}),
      supervisor_count: MapSet.size(supervisors),
      supervised_count: MapSet.size(child_keys)
    }
  end

  defp supervises_edges(graph) do
    graph
    |> Graph.edges()
    |> Enum.flat_map(fn
      %Graph.Edge{v1: from, v2: to, label: {:supervises, meta}} ->
        [
          %{
            from: from,
            to: to,
            restart: Map.get(meta, :restart, :unknown),
            order: Map.get(meta, :order, 0),
            strategy: Map.get(meta, :strategy),
            conditional: Map.get(meta, :conditional, false)
          }
        ]

      _other ->
        []
    end)
  end

  defp build_node(key, by_parent, visited) do
    if MapSet.member?(visited, key) do
      %{key: key, children: [], cycle: true}
    else
      visited = MapSet.put(visited, key)

      children =
        by_parent
        |> Map.get(key, [])
        |> Enum.sort_by(& &1.order)
        |> Enum.map(fn edge ->
          edge.to
          |> build_node(by_parent, visited)
          |> Map.merge(%{
            restart: edge.restart,
            order: edge.order,
            conditional: edge.conditional
          })
        end)

      %{key: key, children: children}
    end
  end

  defp extract_from_file(path) do
    # `Code.string_to_quoted/1`, not `Sourceror.parse_string/1`: Sourceror
    # returns a formatter-style AST that wraps every literal and keyword key in
    # a `{:__block__, meta, [literal]}` node to preserve formatting. Pass 6 is
    # unaffected because it only matches `__aliases__`, but this pass reads
    # keyword options, atom strategies and list literals throughout — the
    # standard AST keeps those as plain terms.
    with {:ok, source} <- File.read(path),
         {:ok, ast} <- Code.string_to_quoted(source) do
      ast
      |> function_bodies()
      |> Enum.flat_map(fn {module, body} -> declarations_in_body(body, module) end)
    else
      _ -> []
    end
  end

  # Every `def`/`defp` body in the file, paired with its innermost enclosing
  # module. Binding resolution never crosses one of these boundaries — that is
  # the whole point of the bound.
  #
  # The module is not decoration: an anonymous `Supervisor.start_link(children,
  # strategy: :one_for_one)` has no `name:` option, and the enclosing module is
  # then its only identity. Falling back to a constant instead would collide
  # every unnamed supervisor in a project onto one fabricated vertex.
  defp function_bodies(ast) do
    {_ast, {_stack, bodies}} =
      Macro.traverse(
        ast,
        {[], []},
        fn
          {:defmodule, _meta, [alias_ast | _rest]} = node, {stack, acc} ->
            {node, {[render_module(alias_ast) | stack], acc}}

          {def_kind, _meta, [_head, body_kw]} = node, {stack, acc}
          when def_kind in [:def, :defp] and is_list(body_kw) ->
            case Keyword.fetch(body_kw, :do) do
              {:ok, body} -> {node, {stack, [{List.first(stack), body} | acc]}}
              :error -> {node, {stack, acc}}
            end

          node, state ->
            {node, state}
        end,
        fn
          {:defmodule, _meta, _args} = node, {[_popped | rest], acc} -> {node, {rest, acc}}
          node, state -> {node, state}
        end
      )

    bodies
  end

  # ============================================================================
  # Call-site discovery
  # ============================================================================

  defp declarations_in_body(body, module) do
    bindings = collect_bindings(body)

    {_ast, calls} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, [mod]}, fun]}, _meta, [children_expr, opts_expr]} = node, acc
        when mod in [:Supervisor, :DynamicSupervisor] and fun in [:start_link, :init] ->
          {node, [{mod, children_expr, opts_expr} | acc]}

        # `DynamicSupervisor.start_link(opts)` — no child list by definition.
        {{:., _, [{:__aliases__, _, [:DynamicSupervisor]}, fun]}, _meta, [opts_expr]} = node, acc
        when fun in [:start_link, :init] ->
          {node, [{:DynamicSupervisor, [], opts_expr} | acc]}

        node, acc ->
          {node, acc}
      end)

    declarations =
      Enum.map(calls, fn {mod, children_expr, opts_expr} ->
        build_declaration(mod, children_expr, opts_expr, bindings, module)
      end)

    declarations ++ Enum.flat_map(declarations, &dynamic_children_as_declarations/1)
  end

  # A `{DynamicSupervisor, name: X}` child spec declares a supervisor in its own
  # right: X supervises runtime-started children that static analysis cannot
  # see. Emit it so the vertex exists and is flagged, rather than leaving a
  # tree node that silently looks childless-by-omission.
  defp dynamic_children_as_declarations(%{children: children}) do
    children
    |> Enum.filter(&(&1.module == "DynamicSupervisor"))
    |> Enum.map(fn child ->
      %{
        key: child.key,
        module: "DynamicSupervisor",
        registered_name: child.key,
        dynamic: true,
        strategy: nil,
        children: [],
        children_unresolved: false
      }
    end)
  end

  defp build_declaration(mod, children_expr, opts_expr, bindings, module) do
    opts = resolve_expr(opts_expr, bindings, 0)
    dynamic? = mod == :DynamicSupervisor

    name = opts |> keyword_value(:name) |> render_name(module)
    strategy = opts |> keyword_value(:strategy) |> render_atom()

    {children, unresolved?} =
      if dynamic? do
        # DynamicSupervisor children are started at runtime via start_child/2.
        # Absent children are correct here, not an unresolved list.
        {[], false}
      else
        {specs, unresolved?} = resolve_children(children_expr, bindings)

        children =
          specs
          |> Enum.with_index()
          |> Enum.map(fn {{spec, conditional?}, order} ->
            child_from_spec(spec, order, conditional?)
          end)
          |> Enum.reject(&is_nil/1)

        {children, unresolved?}
      end

    %{
      key: name || module,
      module: module,
      registered_name: name,
      dynamic: dynamic?,
      strategy: strategy,
      children: children,
      children_unresolved: unresolved?
    }
  end

  # ============================================================================
  # Bounded binding resolution
  # ============================================================================

  # Single-assignment bindings in this body: `var = rhs`. A variable assigned
  # more than once is dropped entirely rather than guessed at.
  defp collect_bindings(body) do
    {_ast, pairs} =
      Macro.prewalk(body, [], fn
        {:=, _meta, [{var, _, ctx}, rhs]} = node, acc when is_atom(var) and is_atom(ctx) ->
          {node, [{var, rhs} | acc]}

        node, acc ->
          {node, acc}
      end)

    pairs
    |> Enum.group_by(fn {var, _} -> var end, fn {_, rhs} -> rhs end)
    |> Enum.flat_map(fn
      {var, [rhs]} -> [{var, rhs}]
      {_var, _many} -> []
    end)
    |> Map.new()
  end

  # Resolve an expression to a plain value where the bound rules allow it.
  # Returns `:unresolved` for anything outside them.
  defp resolve_expr(_expr, _bindings, depth) when depth > @max_binding_depth, do: :unresolved

  # `__MODULE__` parses as `{:__MODULE__, meta, ctx}`, which matches the
  # variable clause below — `:__MODULE__` is an atom and so is the context. It
  # would then resolve to no binding and return the `:unresolved` sentinel,
  # which `render_name/2` faithfully rendered as a process named
  # `":unresolved"`. Since `name: __MODULE__` is the most common supervisor
  # naming idiom in Elixir, that fabricated a root for most real applications.
  # Pass it through intact so the caller, which knows the enclosing module, can
  # resolve it.
  defp resolve_expr({:__MODULE__, _meta, ctx} = ast, _bindings, _depth) when is_atom(ctx), do: ast

  defp resolve_expr({var, _meta, ctx}, bindings, depth) when is_atom(var) and is_atom(ctx) do
    case Map.fetch(bindings, var) do
      {:ok, rhs} -> resolve_expr(rhs, bindings, depth + 1)
      :error -> :unresolved
    end
  end

  defp resolve_expr(list, bindings, depth) when is_list(list) do
    Enum.map(list, fn
      {k, v} when is_atom(k) -> {k, resolve_expr(v, bindings, depth + 1)}
      other -> other
    end)
  end

  defp resolve_expr(other, _bindings, _depth), do: other

  # Resolve a child-list expression into ordered child specs.
  # `{children, unresolved?}` — unresolved? true means "emit no child edges".
  defp resolve_children(expr, bindings), do: do_resolve_children(expr, bindings, 0)

  defp do_resolve_children(_expr, _bindings, depth) when depth > @max_binding_depth,
    do: {[], true}

  # Literal list — the base case.
  defp do_resolve_children(list, _bindings, _depth) when is_list(list) do
    {Enum.map(list, &{&1, false}), false}
  end

  # `a ++ b` — concatenation of two resolvable lists.
  defp do_resolve_children({:++, _meta, [left, right]}, bindings, depth) do
    {l, l_un} = do_resolve_children(left, bindings, depth + 1)
    {r, r_un} = do_resolve_children(right, bindings, depth + 1)
    {l ++ r, l_un or r_un}
  end

  # `if cond do a else b end` — union of both branches. A child missing from
  # any branch is conditional.
  defp do_resolve_children({:if, _meta, [_cond, branches]}, bindings, depth)
       when is_list(branches) do
    do_branch_union(
      [Keyword.get(branches, :do), Keyword.get(branches, :else, [])],
      bindings,
      depth
    )
  end

  # `case x do ... end` — union across every clause body.
  defp do_resolve_children({:case, _meta, [_subject, clauses]}, bindings, depth)
       when is_list(clauses) do
    bodies =
      clauses
      |> Keyword.get(:do, [])
      |> Enum.map(fn
        {:->, _, [_pattern, body]} -> body
        _ -> []
      end)

    do_branch_union(bodies, bindings, depth)
  end

  # A variable — follow its single binding.
  defp do_resolve_children({var, _meta, ctx}, bindings, depth)
       when is_atom(var) and is_atom(ctx) do
    case Map.fetch(bindings, var) do
      {:ok, rhs} -> do_resolve_children(rhs, bindings, depth + 1)
      :error -> {[], true}
    end
  end

  # Function calls, Enum.*, comprehensions, config lookups — out of bounds.
  defp do_resolve_children(_other, _bindings, _depth), do: {[], true}

  defp do_branch_union(branch_exprs, bindings, depth) do
    resolved = Enum.map(branch_exprs, &do_resolve_children(&1, bindings, depth + 1))

    if Enum.any?(resolved, fn {_children, unresolved?} -> unresolved? end) do
      {[], true}
    else
      branch_lists = Enum.map(resolved, fn {children, _} -> children end)

      common =
        branch_lists
        |> Enum.map(fn pairs -> pairs |> Enum.map(&elem(&1, 0)) |> MapSet.new() end)
        |> Enum.reduce(&MapSet.intersection/2)

      # Conditionality accumulates outward. A child already flagged conditional
      # by an inner branch (a tier gated on GIULIA_ROLE) stays conditional even
      # when the variable holding it appears in every branch of an outer `if` —
      # dropping the inner flag here would report env-gated children as
      # unconditionally started.
      merged =
        branch_lists
        |> Enum.concat()
        |> Enum.uniq_by(&elem(&1, 0))
        |> Enum.map(fn {spec, inner_conditional?} ->
          {spec, inner_conditional? or not MapSet.member?(common, spec)}
        end)

      {merged, false}
    end
  end

  # ============================================================================
  # Child-spec shapes
  # ============================================================================

  @doc """
  Render one child-spec AST node into a child map, or `nil` when the shape
  carries no statically determinable module.

  Handles the four forms in general use: bare module alias, `{module, opts}`,
  a full `%{id:, start:, restart:}` spec map, and `Supervisor.child_spec/2`.
  """
  @spec child_from_spec(Macro.t(), non_neg_integer(), boolean()) :: child() | nil
  def child_from_spec(spec, order, conditional?)

  # `Supervisor.child_spec(child, overrides)` — unwrap to the inner spec,
  # letting the overrides supply restart/id.
  def child_from_spec(
        {{:., _, [{:__aliases__, _, [:Supervisor]}, :child_spec]}, _meta, [inner, overrides]},
        order,
        conditional?
      ) do
    case child_from_spec(inner, order, conditional?) do
      nil ->
        nil

      child ->
        case keyword_value(overrides, :restart) do
          nil -> child
          restart -> %{child | restart: render_restart(restart)}
        end
    end
  end

  # `%{id: ..., start: {Mod, :start_link, []}, restart: ...}`
  def child_from_spec({:%{}, _meta, pairs}, order, conditional?) when is_list(pairs) do
    # `{Mod, :start_link, []}` is a three-element tuple, which the AST
    # represents as `{:{}, meta, [mod, fun, args]}` — only two-element tuples
    # stay literal.
    module =
      case keyword_value(pairs, :start) do
        {:{}, _meta, [mod_ast, _fun, _args]} -> render_module(mod_ast)
        _ -> pairs |> keyword_value(:id) |> render_module()
      end

    build_child(module, keyword_value(pairs, :restart), order, conditional?)
  end

  # `{Module, opts}` — the most common tuple form.
  def child_from_spec({mod_ast, opts}, order, conditional?) do
    case render_module(mod_ast) do
      nil ->
        nil

      module ->
        name = opts |> keyword_value(:name) |> render_name()
        child = build_child(module, nil, order, conditional?)
        if name, do: %{child | key: name}, else: child
    end
  end

  # Bare module alias.
  def child_from_spec({:__aliases__, _, _} = mod_ast, order, conditional?) do
    build_child(render_module(mod_ast), nil, order, conditional?)
  end

  def child_from_spec(_other, _order, _conditional?), do: nil

  defp build_child(nil, _restart, _order, _conditional?), do: nil

  defp build_child(module, restart, order, conditional?) do
    %{
      key: module,
      module: module,
      restart: render_restart(restart),
      order: order,
      conditional: conditional?
    }
  end

  # ============================================================================
  # Merge
  # ============================================================================

  # Union children per process key across every call site. Ordering follows
  # first appearance; a child absent from any contributing site stays flagged
  # conditional.
  defp merge_by_key(declarations) do
    declarations
    |> Enum.group_by(& &1.key)
    |> Enum.map(fn {key, decls} ->
      children =
        decls
        |> Enum.flat_map(& &1.children)
        |> Enum.uniq_by(& &1.key)
        |> Enum.with_index()
        |> Enum.map(fn {child, idx} -> %{child | order: idx} end)

      %{
        key: key,
        module: Enum.find_value(decls, & &1.module),
        registered_name: Enum.find_value(decls, & &1.registered_name),
        dynamic: Enum.any?(decls, & &1.dynamic),
        strategy: Enum.find_value(decls, & &1.strategy),
        children: children,
        children_unresolved: Enum.any?(decls, & &1.children_unresolved)
      }
    end)
    |> Enum.sort_by(& &1.key)
  end

  # ============================================================================
  # Rendering — AST to stable string keys
  # ============================================================================

  defp keyword_value(list, key) when is_list(list) do
    Enum.find_value(list, fn
      {^key, value} -> value
      _ -> nil
    end)
  end

  defp keyword_value(_other, _key), do: nil

  defp render_module({:__aliases__, _meta, parts}) do
    if Enum.all?(parts, &is_atom/1), do: Enum.join(parts, "."), else: nil
  end

  defp render_module(atom) when is_atom(atom) and not is_nil(atom), do: inspect(atom)
  defp render_module(_other), do: nil

  # Registered names are either module aliases (`name: Giulia.Registry`) or
  # bare atoms (`name: :my_server`). Bare atoms keep their leading colon so a
  # name can never collide with a module key.
  defp render_name(ast), do: render_name(ast, nil)

  # `enclosing` resolves `name: __MODULE__`. Nil when the caller has no module
  # in hand (a child spec's own `name:`), in which case an unresolvable name
  # yields nil and the child falls back to its module — a missing name is
  # recoverable, a wrong one is not.
  defp render_name({:__MODULE__, _meta, ctx}, enclosing) when is_atom(ctx), do: enclosing
  defp render_name({:__aliases__, _, _} = alias_ast, _enclosing), do: render_module(alias_ast)

  # The resolution sentinel must never become a vertex key.
  defp render_name(:unresolved, _enclosing), do: nil

  defp render_name(atom, _enclosing) when is_atom(atom) and not is_nil(atom), do: inspect(atom)
  defp render_name(_other, _enclosing), do: nil

  defp render_atom(atom) when is_atom(atom) and not is_nil(atom), do: Atom.to_string(atom)
  defp render_atom(_other), do: nil

  defp render_restart(r) when r in [:permanent, :transient, :temporary], do: r
  defp render_restart(_other), do: :unknown
end
