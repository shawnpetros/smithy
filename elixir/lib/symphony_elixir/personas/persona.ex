defmodule SymphonyElixir.Personas.Persona do
  @moduledoc """
  Persona loader for Symphony's three-axis agent config (mode, runtime, persona).

  A persona is a markdown file with YAML frontmatter that describes how to
  invoke an agent and a body that becomes the prompt template. Future personas
  (reviewer, architect-reviewer, triager, builder variants) all follow the same
  shape: frontmatter meta plus markdown body plus `{{var}}` placeholders.

  Ported from Anvil's `persona.rs`. Two intentional divergences:

    1. `agent_command` is replaced by separate `mode` and `runtime` axes per
       v2/SPEC.md "Three-axis agent config". The runtime axis selects the
       subprocess adapter; the mode axis selects state-machine behavior.
    2. Frontmatter `mode` / `runtime` are parsed to atoms with a safe fallback
       to `nil` for unknown values, so an old persona file with a bogus value
       does not crash the loader. Validation against the allowed set is the
       caller's job at dispatch time, not this module's.

  ## Frontmatter shape

      ---
      name: reviewer
      description: Adversarial code reviewer
      mode: reviewer
      runtime: claude_code
      model_hint: sonnet
      ---
      You are reviewing {{identifier}}: {{title}}.
      ...

  Required fields: `name`, `description`. Others optional.

  ## Variable substitution

  `{{var}}` is replaced with `vars[var]` (binary key, value trimmed of the
  brace tokens only; whitespace inside the braces is allowed and trimmed).
  Unknown keys are left in place so missing-var bugs surface in the rendered
  prompt rather than disappearing silently.

  All errors are returned as `{:error, binary_reason}`; the module never raises.
  """

  # Reference the allowed atoms at compile time so `String.to_existing_atom/1`
  # has them in the atom table when persona files are loaded at runtime.
  @allowed_atoms [:builder, :reviewer, :triager, :codex, :claude_code]
  _ = @allowed_atoms

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          mode: atom() | nil,
          runtime: atom() | nil,
          model_hint: String.t() | nil,
          body: String.t()
        }

  defstruct [:name, :description, :mode, :runtime, :model_hint, body: ""]

  @doc """
  Read a persona file off disk and parse it.
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        parse(content)

      {:error, reason} ->
        {:error, "read persona at #{path}: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  Parse a persona from an in-memory string. Same logic as `load/1`, exposed
  for tests so they don't need a tempfile.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse(content) when is_binary(content) do
    with {:ok, yaml, body} <- split_frontmatter(content),
         {:ok, meta} <- decode_yaml(yaml) do
      build(meta, body)
    end
  end

  @doc """
  Render the persona body by replacing `{{var}}` occurrences with the value
  from `vars`. Unknown keys are left in place.
  """
  @spec render(t(), %{required(String.t()) => String.t()}) :: String.t()
  def render(%__MODULE__{body: body}, vars) when is_map(vars) do
    render_template(body, vars)
  end

  # ----- frontmatter split -----

  defp split_frontmatter(content) do
    lines = String.split(content, ~r/\R/, trim: false)
    {_skipped, rest} = Enum.split_while(lines, &blank?/1)

    case rest do
      [] ->
        {:error, "persona file is empty"}

      [first | tail] ->
        case String.trim(first) do
          "---" ->
            collect_frontmatter(tail, [])

          other ->
            {:error,
             "expected `---` at start of persona frontmatter, got `#{other}`"}
        end
    end
  end

  defp collect_frontmatter([], _acc) do
    {:error, "persona frontmatter missing closing `---`"}
  end

  defp collect_frontmatter([line | rest], acc) do
    if String.trim(line) == "---" do
      yaml = acc |> Enum.reverse() |> Enum.join("\n")
      body = Enum.join(rest, "\n")
      {:ok, yaml, body}
    else
      collect_frontmatter(rest, [line | acc])
    end
  end

  defp blank?(line), do: String.trim(line) == ""

  # ----- YAML decode -----

  defp decode_yaml(""), do: {:ok, %{}}

  defp decode_yaml(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      {:ok, _other} ->
        {:error, "persona frontmatter must be a YAML mapping"}

      {:error, reason} ->
        {:error, "parse persona YAML frontmatter: #{inspect(reason)}"}
    end
  end

  # ----- struct build + validation -----

  defp build(meta, body) do
    name = fetch_string(meta, "name")
    description = fetch_string(meta, "description")

    cond do
      is_nil(name) or String.trim(name) == "" ->
        {:error, "persona frontmatter `name` is required"}

      is_nil(description) or String.trim(description) == "" ->
        {:error, "persona frontmatter `description` is required"}

      true ->
        {:ok,
         %__MODULE__{
           name: name,
           description: description,
           mode: safe_atom(meta["mode"]),
           runtime: safe_atom(meta["runtime"]),
           model_hint: fetch_string(meta, "model_hint"),
           body: body
         }}
    end
  end

  defp fetch_string(meta, key) do
    case Map.get(meta, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  # Convert a frontmatter string value to an atom only if that atom already
  # exists. Unknown / non-string / nil values become nil so a typo'd value
  # does not crash the loader. Callers validate against an allowlist at
  # dispatch time.
  defp safe_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp safe_atom(_), do: nil

  # ----- template render -----

  defp render_template(body, vars) do
    render_template(body, vars, <<>>)
  end

  defp render_template(<<"{{", rest::binary>>, vars, acc) do
    case :binary.split(rest, "}}") do
      [key, tail] ->
        trimmed = String.trim(key)

        case Map.fetch(vars, trimmed) do
          {:ok, value} when is_binary(value) ->
            render_template(tail, vars, acc <> value)

          _ ->
            # Unknown key: emit the original `{{key}}` so the bug is visible.
            render_template(tail, vars, acc <> "{{" <> key <> "}}")
        end

      [_only] ->
        # No closing `}}` anywhere: pass through verbatim.
        acc <> "{{" <> rest
    end
  end

  defp render_template(<<char::utf8, rest::binary>>, vars, acc) do
    render_template(rest, vars, acc <> <<char::utf8>>)
  end

  defp render_template(<<>>, _vars, acc), do: acc
end
