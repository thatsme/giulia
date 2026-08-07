defmodule Giulia.Knowledge.ResolverContractsTest do
  @moduledoc """
  L0 phase 2a — resolver contracts: universally-quantified invariants on
  Pass 6 module resolution, property-tested over GENERATED inputs. The
  golden suite pins enumerated constructs; these contracts bind the
  un-enumerated space, so a resolver edit cannot reintroduce the f515d2e
  fabrication class for any name nobody thought to enumerate.

  Contracts:
    C1 stdlib supremacy  — a bare alias loadable in the analyzer runtime
       never resolves to a project module via the prefix fallback.
    C2 identity supremacy — any name in the project set (including
       stdlib-colliding ones) resolves to itself by direct membership.
       This is the cond-ordering invariant: membership is checked BEFORE
       loadability, and a clause swap must fail this property.
    C3 fallback soundness — resolution can narrow, never invent: every
       {:ok, m} satisfies m ∈ all_modules, for arbitrary inputs.
    C4 no atom minting   — probing arbitrary unseen names never grows
       the atom table (the to_existing_atom discipline as a property).
       Only bindable at the resolver: the pipeline path re-parses with
       Sourceror, whose tokenizer legitimately mints atoms.
    C5 pipeline binding  — bounded-runs end-to-end property through
       analyze_file + full build_graph: bare stdlib usage in a project
       with a colliding module fabricates nothing, while an explicit
       full-name reference (anti-vacuity witness) still resolves.

  async: false — C4 asserts on the VM-global atom counter.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Giulia.Knowledge.Builder

  # Single-segment module names loadable in this runtime whose bare atom
  # exists (alias parts arrive as bare atoms; a name whose atom was never
  # minted can't appear in an AST in the first place). Computed live from
  # :code.all_loaded/0 so the pool tracks the actual runtime, not a
  # hand-maintained list.
  @stdlib_pool (fn ->
                  bare_atom_exists? = fn s ->
                    try do
                      _ = String.to_existing_atom(s)
                      true
                    rescue
                      ArgumentError -> false
                    end
                  end

                  :code.all_loaded()
                  |> Enum.map(fn {mod, _file} -> Atom.to_string(mod) end)
                  |> Enum.filter(&String.starts_with?(&1, "Elixir."))
                  |> Enum.map(&String.replace_prefix(&1, "Elixir.", ""))
                  |> Enum.reject(&String.contains?(&1, "."))
                  |> Enum.filter(bare_atom_exists?)
                  |> Enum.sort()
                end).()

  # Bounded atom vocabulary for arbitrary-input generators — property
  # iterations must not mint atoms themselves.
  @atom_pool [
    :Alpha,
    :Beta,
    :Gamma,
    :Delta,
    :Worker,
    :Server,
    :Core,
    :Impl,
    :Utils,
    :Application,
    :Version,
    :Registry,
    :Enum
  ]

  test "stdlib pool sanity: non-empty and contains the known collision names" do
    assert @stdlib_pool != []
    assert "Application" in @stdlib_pool
    assert "Version" in @stdlib_pool
  end

  # --------------------------------------------------------------------
  # C1 — stdlib supremacy
  # --------------------------------------------------------------------
  property "C1: bare loadable alias never resolves to a project module via prefix fallback" do
    check all prefix <- prefix_gen(),
              stdlib <- member_of(@stdlib_pool) do
      caller = prefix <> ".Worker"
      colliding = prefix <> "." <> stdlib
      all_modules = MapSet.new([caller, colliding])
      prefixes = Builder.caller_namespace_prefixes(caller)
      parts = [String.to_existing_atom(stdlib)]

      assert Builder.resolve_with_fallback(parts, caller, prefixes, all_modules) == :not_found,
             "bare #{stdlib} inside #{prefix}.* must not resolve to #{colliding}"
    end
  end

  # --------------------------------------------------------------------
  # C2 — identity supremacy (the cond-ordering invariant)
  # --------------------------------------------------------------------
  property "C2: any name in the project set resolves to itself, even stdlib-colliding" do
    # Prefix drawn from the bounded atom vocabulary (atoms must pre-exist:
    # AST alias parts are atoms, so a never-minted name cannot appear in
    # an AST). The vocabulary includes stdlib-colliding segments, so this
    # also pins identity winning when the WHOLE dotted name is built from
    # loadable segments (e.g. project module "Application.Enum").
    check all prefix <- module_name_gen(),
              stdlib <- member_of(~w(Application Version Registry Enum)) do
      full = prefix <> "." <> stdlib
      all_modules = MapSet.new([full])
      parts = Enum.map(String.split(full, "."), &String.to_existing_atom/1)
      prefixes = Builder.caller_namespace_prefixes("#{prefix}.Other")

      assert Builder.resolve_with_fallback(parts, "#{prefix}.Other", prefixes, all_modules) ==
               {:ok, full}
    end
  end

  test "C2 boundary: a project module literally named Application resolves by identity" do
    all_modules = MapSet.new(["Application"])

    assert Builder.resolve_with_fallback(
             [:Application],
             "Whatever.Caller",
             ["Whatever"],
             all_modules
           ) ==
             {:ok, "Application"}
  end

  # --------------------------------------------------------------------
  # C3 — fallback soundness: narrow, never invent
  # --------------------------------------------------------------------
  property "C3: every {:ok, m} result is a member of all_modules" do
    check all parts <- parts_gen(),
              caller <- module_name_gen(),
              mods <- modules_set_gen() do
      prefixes = Builder.caller_namespace_prefixes(caller)

      case Builder.resolve_with_fallback(parts, caller, prefixes, mods) do
        {:ok, m} -> assert MapSet.member?(mods, m)
        :not_found -> :ok
      end
    end
  end

  # --------------------------------------------------------------------
  # C4 — no atom minting on unseen names
  # --------------------------------------------------------------------
  property "C4: probing arbitrary unseen names never grows the atom table" do
    check all n <- positive_integer() do
      name = "Zx#{n}Q#{:erlang.unique_integer([:positive])}"
      before_count = :erlang.system_info(:atom_count)

      refute Builder.loadable_runtime_module?(name)

      assert :erlang.system_info(:atom_count) == before_count,
             "loadable_runtime_module?(#{inspect(name)}) minted an atom"
    end
  end

  # --------------------------------------------------------------------
  # C5 — pipeline binding (bounded runs; real files, full Builder)
  # --------------------------------------------------------------------
  property "C5: pipeline fabricates nothing on bare stdlib collisions; explicit refs survive" do
    check all prefix <- prefix_gen(),
              stdlib <- member_of(["Application", "Version", "Registry", "Supervisor", "Task"]),
              max_runs: 15 do
      dir =
        Path.join(System.tmp_dir!(), "resolver_contract_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(dir)

      try do
        colliding = "#{prefix}.#{stdlib}"
        caller = "#{prefix}.Worker"
        witness = "#{prefix}.Witness"

        files = %{
          "colliding.ex" => """
          defmodule #{colliding} do
            def marker, do: :ok
          end
          """,
          "worker.ex" => """
          defmodule #{caller} do
            def read, do: #{stdlib}.fetch_thing(:x)
          end
          """,
          "witness.ex" => """
          defmodule #{witness} do
            def target, do: #{colliding}
          end
          """
        }

        ast_data =
          Map.new(files, fn {file, source} ->
            path = Path.join(dir, file)
            File.write!(path, source)
            {:ok, data} = Giulia.AST.Processor.analyze_file(path)
            {path, data}
          end)

        graph = Builder.build_graph(ast_data)

        fabricated = Graph.edges(graph, caller, colliding)

        assert fabricated == [],
               "fabricated #{inspect(Enum.map(fabricated, & &1.label))}: #{caller} -> #{colliding}"

        # Anti-vacuity witness: the property must not pass because nothing
        # emits anything — the explicit full-name reference must resolve.
        assert Graph.edges(graph, witness, colliding) != [],
               "witness reference #{witness} -> #{colliding} missing — pipeline emitted nothing"
      after
        File.rm_rf!(dir)
      end
    end
  end

  # --------------------------------------------------------------------
  # Adversarial minimums (house rules): nil-ish, empty, boundary,
  # structurally-valid-but-semantically-odd
  # --------------------------------------------------------------------
  describe "adversarial edges" do
    test "empty parts resolve to :not_found" do
      assert Builder.resolve_with_fallback([], "P.X", ["P"], MapSet.new(["P.Y"])) == :not_found
    end

    test "empty module set resolves to :not_found for any valid parts" do
      assert Builder.resolve_with_fallback([:Alpha], "P.X", ["P"], MapSet.new()) == :not_found
    end

    test "single-segment caller has no prefixes (fallback has nowhere to walk)" do
      assert Builder.caller_namespace_prefixes("Solo") == []

      assert Builder.resolve_with_fallback([:Beta], "Solo", [], MapSet.new(["Solo.Beta"])) ==
               :not_found
    end

    test "caller_namespace_prefixes returns parents deepest-first" do
      assert Builder.caller_namespace_prefixes("A.B.C") == ["A.B", "A"]
    end

    test "__MODULE__ parts resolve to the caller when the caller is a project module" do
      # Semantically odd but structurally valid: pins that __MODULE__
      # resolves through resolve_module_parts to the caller itself
      # (self-edges are filtered later, in add_reference_edges — not here).
      mods = MapSet.new(["P.X"])

      assert Builder.resolve_with_fallback([{:__MODULE__, [], nil}], "P.X", ["P"], mods) ==
               {:ok, "P.X"}
    end
  end

  # --------------------------------------------------------------------
  # Generators
  # --------------------------------------------------------------------

  # Valid, never-loadable module prefixes: "Px" + capitalized alpha run.
  defp prefix_gen do
    gen all base <- string([?a..?z], min_length: 2, max_length: 6) do
      "Px" <> String.capitalize(base)
    end
  end

  # Arbitrary dotted names from the bounded atom vocabulary.
  defp module_name_gen do
    gen all parts <- list_of(member_of(@atom_pool), min_length: 1, max_length: 3) do
      Enum.map_join(parts, ".", &Atom.to_string/1)
    end
  end

  defp modules_set_gen do
    gen all names <- uniq_list_of(module_name_gen(), max_length: 8) do
      MapSet.new(names)
    end
  end

  # Alias parts as they arrive from the AST: bare atoms, occasionally a
  # __MODULE__ tuple in head position.
  defp parts_gen do
    one_of([
      list_of(member_of(@atom_pool), min_length: 1, max_length: 3),
      constant([{:__MODULE__, [], nil}]),
      gen all rest <- list_of(member_of(@atom_pool), min_length: 1, max_length: 2) do
        [{:__MODULE__, [], nil} | rest]
      end
    ])
  end
end
