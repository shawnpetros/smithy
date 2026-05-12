defmodule SymphonyElixir.Handoff.Triage do
  @moduledoc """
  Parses `TRIAGE.md` handoff artifacts written by a `mode: triager` agent.

  Triager runs front-of-queue on tickets carrying `agent-ready` and decides
  whether the ticket is well-specified enough to dispatch a builder. The
  decision is recorded in a YAML front-matter block at the top of
  `TRIAGE.md`:

      ---
      decision: proceed | flag
      reasons:
        - "Where: identifies lib/foo/bar.ex"
        - "What: adds X behavior"
      gap_comment: |
        Multi-line comment posted to the workpad when decision is flag.
      ---

  Validation rules enforced here:

    * `decision` is required and must be `"proceed"` or `"flag"`.
    * `decision: flag` requires a non-empty `gap_comment` (it is the comment
      posted to the workpad when the ticket bounces back to Backlog).
    * `decision: proceed` may have an empty or absent `gap_comment`.
    * `reasons` is optional; when present, must be a list of strings.

  Pure functions except `parse_file/1`. Body text after the closing `---`
  is permitted but ignored.
  """

  @type decision :: :proceed | :flag

  @type t :: %__MODULE__{
          decision: decision(),
          reasons: [String.t()],
          gap_comment: String.t() | nil
        }

  @type error_reason ::
          :malformed_frontmatter
          | :missing_decision
          | :invalid_decision
          | :flag_without_gap_comment
          | {:invalid_reasons, term()}
          | {:yaml_error, term()}

  defstruct [:decision, reasons: [], gap_comment: nil]

  @doc """
  Reads a `TRIAGE.md` file from disk and parses its front matter.
  """
  @spec parse_file(Path.t()) :: {:ok, t()} | {:error, error_reason() | File.posix()}
  def parse_file(path) do
    case File.read(path) do
      {:ok, content} -> parse(content)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Parses the raw string contents of a `TRIAGE.md` artifact.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, error_reason()}
  def parse(content) when is_binary(content) do
    with {:ok, yaml} <- extract_front_matter(content),
         {:ok, map} <- decode_yaml(yaml),
         {:ok, decision} <- fetch_decision(map),
         {:ok, reasons} <- fetch_reasons(map),
         gap_comment = normalize_gap_comment(Map.get(map, "gap_comment")),
         :ok <- validate_gap_comment(decision, gap_comment) do
      {:ok,
       %__MODULE__{
         decision: decision,
         reasons: reasons,
         gap_comment: gap_comment
       }}
    end
  end

  # ----- front-matter extraction -----

  defp extract_front_matter(content) do
    lines = String.split(content, ~r/\R/, trim: false)

    case lines do
      ["---" | tail] ->
        case Enum.split_while(tail, &(&1 != "---")) do
          {_front, []} ->
            {:error, :malformed_frontmatter}

          {front, ["---" | _body]} ->
            {:ok, Enum.join(front, "\n")}
        end

      _ ->
        {:error, :malformed_frontmatter}
    end
  end

  defp decode_yaml(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, :malformed_frontmatter}
      {:error, reason} -> {:error, {:yaml_error, reason}}
    end
  end

  # ----- field validation -----

  defp fetch_decision(map) do
    case Map.get(map, "decision") do
      nil ->
        {:error, :missing_decision}

      value when is_binary(value) ->
        case String.trim(value) do
          "proceed" -> {:ok, :proceed}
          "flag" -> {:ok, :flag}
          "" -> {:error, :missing_decision}
          _ -> {:error, :invalid_decision}
        end

      _ ->
        {:error, :invalid_decision}
    end
  end

  defp fetch_reasons(map) do
    case Map.get(map, "reasons") do
      nil ->
        {:ok, []}

      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1) do
          {:ok, list}
        else
          {:error, {:invalid_reasons, list}}
        end

      other ->
        {:error, {:invalid_reasons, other}}
    end
  end

  defp normalize_gap_comment(nil), do: nil

  defp normalize_gap_comment(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _ -> value
    end
  end

  defp normalize_gap_comment(_), do: nil

  defp validate_gap_comment(:flag, nil), do: {:error, :flag_without_gap_comment}
  defp validate_gap_comment(:flag, _comment), do: :ok
  defp validate_gap_comment(:proceed, _comment), do: :ok
end
