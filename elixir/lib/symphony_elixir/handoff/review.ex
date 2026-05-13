defmodule SymphonyElixir.Handoff.Review do
  @moduledoc """
  Parses the `REVIEW.md` structured handoff written by a reviewer agent.

  The reviewer agent (`mode: reviewer`) writes this file at the workspace root
  and exits. Symphony parses it to decide the Linear state transition:

    * `status: pass` -> `Human Review` (or `Done` if `auto-merge` label is set)
    * `status: fail` -> `Rework`, findings appended to workpad
    * malformed     -> `harness-blocked` label, stays in `Adversarial Review`

  ## Schema

      ---
      status: pass | fail
      findings:
        - finding: "<text>"
          grade: blocker | polish | future | rebuild-from-scratch
      notes: |
        Optional longer prose context.
      ---

      Optional human-readable markdown body (ignored).

  ## Validation rules

    * `status: fail` requires at least one finding with `grade: blocker`.
      Polish-only or future-only with `status: fail` is malformed - the parser
      refuses to upgrade polish to blocker; that is the agent's job.
    * `status: pass` with any findings is fine (advisory items the orchestrator
      surfaces in the workpad).
    * Unknown `grade` values are rejected.
    * Missing `status` is rejected.
    * Each `findings[]` entry must carry both `finding` and `grade`. Missing
      either is rejected.
    * Empty `findings` list is allowed (clean pass with no advisory).

  Pure functions; the only IO is `parse_file/1` reading the path.

  Ported from `anvil/src/review.rs`.
  """

  @type grade :: :blocker | :polish | :future | :rebuild_from_scratch
  @type finding :: %{finding: String.t(), grade: grade()}
  @type status :: :pass | :fail

  @type t :: %__MODULE__{
          status: status(),
          findings: [finding()],
          notes: String.t() | nil
        }

  defstruct [:status, findings: [], notes: nil]

  @doc """
  Read `REVIEW.md` from disk and parse it.

  Returns `{:ok, %Review{}}` on success or `{:error, reason}` where `reason`
  is a descriptive binary. Never raises.
  """
  @spec parse_file(Path.t()) :: {:ok, t()} | {:error, binary()}
  def parse_file(path) do
    case File.read(path) do
      {:ok, content} -> parse(content)
      {:error, posix} -> {:error, "read REVIEW.md at #{path}: #{:file.format_error(posix)}"}
    end
  end

  @doc """
  Parse a REVIEW.md string into a `%Review{}`.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, binary()}
  def parse(content) when is_binary(content) do
    with {:ok, yaml} <- split_frontmatter(content),
         {:ok, raw} <- decode_yaml(yaml),
         {:ok, status} <- parse_status(raw),
         {:ok, findings} <- parse_findings(Map.get(raw, "findings", [])),
         :ok <- validate_fail_requires_blocker(status, findings) do
      {:ok,
       %__MODULE__{
         status: status,
         findings: findings,
         notes: parse_notes(Map.get(raw, "notes"))
       }}
    end
  end

  # ----- frontmatter splitting -----

  defp split_frontmatter(content) do
    lines = String.split(content, "\n", trim: false)
    {leading, rest} = drop_leading_blanks(lines)

    case rest do
      [] ->
        {:error, "malformed_frontmatter: REVIEW.md is empty"}

      [first | tail] ->
        if String.trim(first) == "---" do
          collect_frontmatter(tail, [])
        else
          _ = leading
          {:error, "malformed_frontmatter: expected `---` at start of REVIEW.md, got `#{first}`"}
        end
    end
  end

  defp drop_leading_blanks(lines) do
    Enum.split_while(lines, fn line -> String.trim(line) == "" end)
  end

  defp collect_frontmatter([], _acc) do
    {:error, "malformed_frontmatter: REVIEW.md missing closing `---`"}
  end

  defp collect_frontmatter([line | rest], acc) do
    if String.trim(line) == "---" do
      {:ok, acc |> Enum.reverse() |> Enum.join("\n")}
    else
      collect_frontmatter(rest, [line | acc])
    end
  end

  # ----- YAML decoding -----

  defp decode_yaml(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, nil} -> {:ok, %{}}
      {:ok, _other} -> {:error, "malformed_frontmatter: REVIEW.md frontmatter must be a YAML map"}
      {:error, %{message: msg}} -> {:error, "malformed_frontmatter: parse REVIEW.md frontmatter: #{msg}"}
      {:error, reason} -> {:error, "malformed_frontmatter: parse REVIEW.md frontmatter: #{inspect(reason)}"}
    end
  end

  # ----- status -----

  defp parse_status(raw) do
    case Map.get(raw, "status") do
      nil ->
        {:error, "missing_status: REVIEW.md missing required `status` field"}

      value when is_binary(value) ->
        case value |> String.trim() |> String.downcase() do
          "pass" -> {:ok, :pass}
          "fail" -> {:ok, :fail}
          other -> {:error, "invalid_status: unknown status `#{other}`; expected pass|fail"}
        end

      other ->
        {:error, "invalid_status: status must be a string, got #{inspect(other)}"}
    end
  end

  # ----- findings -----

  defp parse_findings(nil), do: {:ok, []}

  defp parse_findings(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case parse_finding(item) do
        {:ok, finding} -> {:cont, {:ok, [finding | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp parse_findings(other) do
    {:error, "invalid_finding: findings must be a list, got #{inspect(other)}"}
  end

  defp parse_finding(item) when is_map(item) do
    with {:ok, text} <- fetch_finding_text(item),
         {:ok, grade} <- fetch_finding_grade(item) do
      {:ok, %{finding: text, grade: grade}}
    end
  end

  defp parse_finding(other) do
    {:error, "invalid_finding: finding entry must be a map, got #{inspect(other)}"}
  end

  defp fetch_finding_text(item) do
    case Map.get(item, "finding") do
      nil -> {:error, "invalid_finding: finding missing required `finding` field"}
      text when is_binary(text) -> {:ok, text}
      other -> {:error, "invalid_finding: `finding` must be a string, got #{inspect(other)}"}
    end
  end

  defp fetch_finding_grade(item) do
    case Map.get(item, "grade") do
      nil ->
        {:error, "invalid_finding: finding missing required `grade` field"}

      value when is_binary(value) ->
        case value |> String.trim() |> String.downcase() do
          "blocker" -> {:ok, :blocker}
          "polish" -> {:ok, :polish}
          "future" -> {:ok, :future}
          "rebuild-from-scratch" -> {:ok, :rebuild_from_scratch}
          other -> {:error, {:invalid_grade, other}}
        end

      other ->
        {:error, {:invalid_grade, inspect(other)}}
    end
  end

  # ----- invariants -----

  defp validate_fail_requires_blocker(:fail, findings) do
    if Enum.any?(findings, fn f -> f.grade in [:blocker, :rebuild_from_scratch] end) do
      :ok
    else
      {:error, "fail_without_blocker: status=fail requires at least one finding with grade=blocker or rebuild-from-scratch"}
    end
  end

  defp validate_fail_requires_blocker(:pass, _findings), do: :ok

  # ----- notes -----

  defp parse_notes(nil), do: nil
  defp parse_notes(""), do: nil

  defp parse_notes(value) when is_binary(value) do
    # Preserve the literal block scalar content as YAML decoded it. Trim only
    # a single trailing newline that YAML appends to `|` blocks, leaving any
    # interior structure intact.
    case String.ends_with?(value, "\n") do
      true -> String.replace_suffix(value, "\n", "")
      false -> value
    end
  end

  defp parse_notes(other), do: to_string(other)
end
