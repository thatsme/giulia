defmodule Giulia.Config.OtpChecks do
  @moduledoc """
  Configuration for the OTP deep-analysis checks.

  Loaded once at first call from `priv/config/otp_checks.json` and cached in
  `:persistent_term`. Reads are free; writes only happen on the first call after
  boot. Editing the JSON and restarting the daemon picks up new patterns — no
  recompile, no per-project opt-in. Companion of `ScoringConfig`,
  `DispatchPatterns`, `DispatchInvariants`, `Relevance`, `ScanConfig` — same
  persistence pattern, same loader shape.

  The MFA lists are *data*: which calls count as blocking is policy that varies
  by codebase and by year, so it lives in JSON. Only the matching mechanics live
  here.

  ## Pattern forms

    * `"Req.*"` — any function on that module (prefix form)
    * `"Finch.request"` — that exact `Module.function`
    * `":httpc.*"` / `":gen_tcp.connect"` — Erlang modules, same two forms
    * `repo_convention` — when true, a call to any module whose final segment is
      `Repo` is error-tier. Ecto's naming convention is the only portable way to
      recognise a project's own repo without enumerating every project.

  Public API:

    * `blocking_severity/1` — `"Module.function"` → `:error | :warning | nil`
    * `missing_catch_all_severity/0` — severity string for the handle_info check
    * `sync_chain_max_depth/0`, `singleton_thresholds/0`, `one_for_all_max_children/0`
  """

  @persistent_term_key {__MODULE__, :config}

  @spec current() :: map()
  def current do
    case :persistent_term.get(@persistent_term_key, :unset) do
      :unset ->
        cfg = load()
        :persistent_term.put(@persistent_term_key, cfg)
        cfg

      cfg ->
        cfg
    end
  end

  @spec reload() :: map()
  def reload do
    cfg = load()
    :persistent_term.put(@persistent_term_key, cfg)
    cfg
  end

  @doc """
  Severity for a call inside `init/1`, or `nil` when it is not blocking.

  `mfa` is the rendered `"Module.function"` — `"Req.get"`, `"MyApp.Repo.all"`,
  `":timer.sleep"`. Error tier wins over warning tier when both would match.
  """
  @spec blocking_severity(String.t()) :: :error | :warning | nil
  def blocking_severity(mfa) when is_binary(mfa) do
    cfg = current().blocking_init

    cond do
      matches_any?(mfa, cfg.error_mfas) -> :error
      cfg.repo_convention and repo_call?(mfa) -> :error
      matches_any?(mfa, cfg.warning_mfas) -> :warning
      true -> nil
    end
  end

  @spec missing_catch_all_severity() :: String.t()
  def missing_catch_all_severity, do: current().missing_catch_all_severity

  @spec sync_chain_max_depth() :: non_neg_integer()
  def sync_chain_max_depth, do: current().sync_chain_max_depth

  @spec singleton_thresholds() :: %{fan_in: non_neg_integer(), queue_len: non_neg_integer()}
  def singleton_thresholds, do: current().singleton

  @spec one_for_all_max_children() :: non_neg_integer()
  def one_for_all_max_children, do: current().one_for_all_max_children

  # Patterns are stored split into {prefixes, exacts} at load time so matching is
  # two set lookups per call site rather than a scan with string surgery.
  defp matches_any?(mfa, %{prefixes: prefixes, exacts: exacts}) do
    MapSet.member?(exacts, mfa) or Enum.any?(prefixes, &String.starts_with?(mfa, &1))
  end

  # Ecto convention: the module's final segment is exactly "Repo". Matches
  # "MyApp.Repo.all" and "MyApp.Tenant.Repo.one"; does not match "RepoHelper".
  defp repo_call?(mfa) do
    case String.split(mfa, ".") do
      [_single] -> false
      segments -> segments |> Enum.drop(-1) |> List.last() == "Repo"
    end
  end

  defp load do
    path = Path.join(:code.priv_dir(:giulia), "config/otp_checks.json")

    case File.read(path) do
      {:ok, body} ->
        raw = Jason.decode!(body)
        blocking = fetch_map!(raw, "blocking_init")

        %{
          blocking_init: %{
            error_mfas: compile_patterns!(blocking, "error_mfas"),
            warning_mfas: compile_patterns!(blocking, "warning_mfas"),
            repo_convention: fetch_bool!(blocking, "repo_convention")
          },
          missing_catch_all_severity:
            raw |> fetch_map!("missing_catch_all_handle_info") |> fetch_string!("severity"),
          sync_chain_max_depth: raw |> fetch_map!("sync_chain") |> fetch_int!("max_depth"),
          singleton: %{
            fan_in: raw |> fetch_map!("singleton_bottleneck") |> fetch_int!("fan_in_threshold"),
            queue_len:
              raw |> fetch_map!("singleton_bottleneck") |> fetch_int!("queue_len_threshold")
          },
          one_for_all_max_children: raw |> fetch_map!("one_for_all") |> fetch_int!("max_children")
        }

      {:error, reason} ->
        raise "OtpChecks: cannot read #{path}: #{inspect(reason)}"
    end
  end

  defp compile_patterns!(map, key) do
    list = Map.fetch!(map, key)

    unless is_list(list) and Enum.all?(list, &is_binary/1) do
      raise "OtpChecks: #{key} must be a list of strings, got #{inspect(list)}"
    end

    {prefix_patterns, exact_patterns} = Enum.split_with(list, &String.ends_with?(&1, ".*"))

    %{
      prefixes: Enum.map(prefix_patterns, &String.replace_suffix(&1, "*", "")),
      exacts: MapSet.new(exact_patterns)
    }
  end

  defp fetch_map!(raw, key) do
    case Map.fetch(raw, key) do
      {:ok, %{} = value} -> value
      _ -> raise "OtpChecks: #{key} must be an object"
    end
  end

  defp fetch_bool!(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_boolean(value) -> value
      other -> raise "OtpChecks: #{key} must be a boolean, got #{inspect(other)}"
    end
  end

  defp fetch_string!(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> value
      other -> raise "OtpChecks: #{key} must be a string, got #{inspect(other)}"
    end
  end

  defp fetch_int!(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) -> value
      other -> raise "OtpChecks: #{key} must be an integer, got #{inspect(other)}"
    end
  end
end
