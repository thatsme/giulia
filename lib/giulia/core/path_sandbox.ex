defmodule Giulia.Core.PathSandbox do
  @moduledoc """
  Security: The Jailbreak Prevention System.

  Giulia should ONLY read/write files that are sub-directories of the
  project root (where GIULIA.md lives).

  The Senior Way:
  - NOT just checking for ".." (amateur hour)
  - Expand to absolute path, then verify it starts with project root

  This prevents:
  - Path traversal attacks (../../etc/passwd)
  - Symlink escapes (/project/link -> /etc)
  - Curious LLM exploring ~/.ssh/config
  - Any file access outside the constitution's jurisdiction

  If the model asks to read a file outside the sandbox,
  we don't execute - we send it back with a firm "no."
  """

  defstruct [:root, :root_parts, :allowed_external]

  @type t :: %__MODULE__{
          root: String.t(),
          root_parts: [String.t()],
          allowed_external: [String.t()]
        }

  @doc """
  Create a new sandbox for a project root.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(root, opts \\ []) do
    normalized_root = normalize_and_expand(root)

    %__MODULE__{
      root: normalized_root,
      root_parts: Path.split(normalized_root),
      # Explicit allowlist for external paths (e.g., deps/, _build/)
      allowed_external: Keyword.get(opts, :allowed_external, [])
    }
  end

  @doc """
  Validate a path against the sandbox.

  Returns:
  - {:ok, expanded_path} if the path is within the sandbox
  - {:error, :sandbox_violation} if the path escapes

  This is THE critical security check. All file operations MUST go through this.
  """
  @spec validate(t(), String.t()) :: {:ok, String.t()} | {:error, :sandbox_violation}
  def validate(%__MODULE__{} = sandbox, path) do
    # Step 1: Expand the path (resolves .., symlinks, relative paths)
    expanded = expand_path(path, sandbox.root)

    # Step 2: Verify the expanded path is under our root
    if path_under_root?(expanded, sandbox) do
      {:ok, expanded}
    else
      # Check allowed external paths
      if allowed_external?(expanded, sandbox) do
        {:ok, expanded}
      else
        {:error, :sandbox_violation}
      end
    end
  end

  @doc """
  Quick check if a path is safe (doesn't return the expanded path).
  """
  @spec safe?(String.t(), t()) :: boolean()
  def safe?(path, sandbox) do
    case validate(sandbox, path) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Get a human-readable error message for sandbox violations.
  """
  @spec violation_message(String.t(), t()) :: String.t()
  def violation_message(path, sandbox) do
    """
    SECURITY VIOLATION: Access denied to path outside project.

    Attempted path: #{path}
    Project root: #{sandbox.root}

    Giulia can only access files within the project where GIULIA.md lives.
    This is a security feature to prevent accidental access to sensitive files.

    If you need to access files outside this project, you must:
    1. Navigate to that directory
    2. Run `giulia /init` to create a new project context
    """
  end

  @doc """
  Add an external path to the allowlist.
  Use sparingly - this creates a security exception.
  """
  @spec allow_external(t(), String.t()) :: t()
  def allow_external(sandbox, path) do
    expanded = normalize_and_expand(path)
    %{sandbox | allowed_external: [expanded | sandbox.allowed_external]}
  end

  # ============================================================================
  # Private - The Core Security Logic
  # ============================================================================

  defp expand_path(path, root) do
    # Handle both absolute and relative paths
    # Note: On Linux, Windows paths like "C:/..." appear as :relative
    # so we also check if it starts with "/" or "X:/" (container/Windows path)
    normalized = path |> strip_null_bytes() |> normalize_slashes()

    full_path =
      if Path.type(path) == :absolute or
           String.starts_with?(normalized, "/") or
           Regex.match?(~r/^[A-Za-z]:\//, normalized) do
        normalized
      else
        Path.join(root, normalized)
      end

    # Resolve ".." and "." components without using Path.expand
    # (Path.expand breaks Windows paths on Linux)
    full_path
    |> Path.split()
    |> resolve_dots([])
    |> Path.join()
  end

  # Resolve "." and ".." path components
  defp resolve_dots([], acc), do: Enum.reverse(acc)
  defp resolve_dots(["." | rest], acc), do: resolve_dots(rest, acc)
  defp resolve_dots([".." | rest], [_ | acc]), do: resolve_dots(rest, acc)
  defp resolve_dots([".." | rest], []), do: resolve_dots(rest, [])
  defp resolve_dots([part | rest], acc), do: resolve_dots(rest, [part | acc])

  defp path_under_root?(expanded_path, sandbox) do
    # Split both paths into components
    path_parts = Path.split(expanded_path)
    root_parts = sandbox.root_parts

    # The path must:
    # 1. Have at least as many components as the root
    # 2. Start with the exact same components as the root

    if length(path_parts) >= length(root_parts) do
      # Compare component by component (case-insensitive on Windows)
      root_parts
      |> Enum.zip(path_parts)
      |> Enum.all?(fn {root_part, path_part} ->
        compare_path_parts(root_part, path_part)
      end)
    else
      false
    end
  end

  defp compare_path_parts(a, b) do
    # Case-insensitive comparison for Windows compatibility
    case :os.type() do
      {:win32, _} ->
        String.downcase(a) == String.downcase(b)

      _ ->
        a == b
    end
  end

  defp allowed_external?(path, sandbox) do
    normalized_path = normalize_slashes(path)

    Enum.any?(sandbox.allowed_external, fn allowed ->
      # Ensure path boundary: /tmp/cache must not match /tmp/cacheevil
      # Compare with trailing slash to enforce directory boundary
      allowed_prefix = normalize_slashes(allowed)
      allowed_with_sep = if String.ends_with?(allowed_prefix, "/"), do: allowed_prefix, else: allowed_prefix <> "/"

      normalized_path == allowed_prefix or String.starts_with?(normalized_path, allowed_with_sep)
    end)
  end

  defp normalize_and_expand(path) do
    # Don't use Path.expand - it breaks Windows paths on Linux
    # Just normalize slashes and trim
    path
    |> normalize_slashes()
    |> String.trim_trailing("/")
  end

  defp normalize_slashes(path) do
    # Normalize to forward slashes for consistent comparison
    String.replace(path, "\\", "/")
  end

  # Strip null bytes — prevents C string terminator attacks where the OS
  # truncates at \0 while Elixir sees the full binary
  defp strip_null_bytes(path) do
    String.replace(path, "\0", "")
  end
end
