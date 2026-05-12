defmodule SymphonyElixir.Workpad do
  @moduledoc """
  Workpad comment management for Linear-tracked issues.

  Every Linear ticket has at most one persistent comment whose body begins with
  the marker header `## Codex Workpad`. All progress notes, plans, validation,
  review findings, and confusions live in that single comment per the universal
  AGENTS.md convention (`v2/SPEC.md` "Workpad" / "Universal AGENTS.md template").
  Modes (builder, reviewer, triager) update the workpad by *appending* dated
  subsections to specific sections (e.g. the reviewer appends a dated
  `### Adversarial Review` subsection on every pass).

  ## Section ownership

  Per v2/SPEC.md "Universal AGENTS.md template":

    * `### Plan` (builder owns)
    * `### Acceptance Criteria` (builder owns)
    * `### Validation` (builder owns)
    * `### Notes` (builder owns)
    * `### Adversarial Review` (reviewer appends, dated subsections)
    * `### Confusions` (any agent may append)

  This module is purely a *section-management* layer. It does not enforce
  ownership: any caller may append to any section. Enforcement lives in the
  caller (e.g. the reviewer pipeline restricts itself to `:adversarial_review`).

  ## Injectable client

  All Linear IO routes through a client module supplied via `opts`. The default
  client (`SymphonyElixir.Workpad.LinearClient`) shells to the existing
  `SymphonyElixir.Linear.Client.graphql/3` helper. Tests pass an in-memory
  Agent-backed client to avoid hitting the network.

  Client contract:

    * `list_comments(issue_id) :: {:ok, [%{id: String.t(), body: String.t()}]} | {:error, term()}`
    * `create_comment(issue_id, body) :: {:ok, comment_id :: String.t()} | {:error, term()}`
    * `update_comment(comment_id, body) :: {:ok, comment_id :: String.t()} | {:error, term()}`

  The existing `SymphonyElixir.Tracker` boundary returns `:ok` from
  `create_comment/2` without a comment id, and has no list/update operations.
  That boundary is preserved untouched; the Workpad module talks to its own
  Linear client behaviour so existing callers keep working.
  """

  @marker_header "## Codex Workpad"

  @section_headers %{
    plan: "Plan",
    acceptance_criteria: "Acceptance Criteria",
    validation: "Validation",
    notes: "Notes",
    adversarial_review: "Adversarial Review",
    confusions: "Confusions"
  }

  @canonical_section_order [
    :plan,
    :acceptance_criteria,
    :validation,
    :notes,
    :adversarial_review,
    :confusions
  ]

  @type issue_id :: String.t() | integer()
  @type comment_id :: String.t()
  @type section ::
          :plan
          | :acceptance_criteria
          | :validation
          | :notes
          | :adversarial_review
          | :confusions

  @doc """
  Find the existing workpad comment on `issue_id`.

  Returns `{:ok, comment_id, body}` when exactly one workpad exists,
  `:not_found` when none exists, and `{:error, reason}` on any client failure.
  If the issue somehow has multiple `## Codex Workpad` comments (shouldn't
  happen, but defensive), returns the first one and ignores the rest.
  """
  @spec find(issue_id(), keyword()) ::
          {:ok, comment_id(), String.t()} | :not_found | {:error, term()}
  def find(issue_id, opts \\ []) do
    client = resolve_client(opts)

    case client.list_comments(to_string(issue_id)) do
      {:ok, comments} ->
        case Enum.find(comments, &workpad_comment?/1) do
          nil -> :not_found
          %{id: id, body: body} -> {:ok, id, body}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Create a workpad comment on `issue_id` if one doesn't already exist.

  Returns `{:ok, comment_id}` on creation. If a workpad already exists, returns
  `{:ok, existing_comment_id}` without creating a duplicate (idempotent).

  Options:

    * `:template_vars` - map passed to `render_template/1` for the new comment
      body. Defaults to `%{}` (renders the canonical template with empty
      placeholder values).
    * `:body` - explicit comment body to use instead of the rendered template.
      Useful when a caller has already composed the workpad.
    * `:client` - client module override (see module docs).
  """
  @spec create(issue_id(), keyword()) :: {:ok, comment_id()} | {:error, term()}
  def create(issue_id, opts \\ []) do
    client = resolve_client(opts)

    case find(issue_id, opts) do
      {:ok, id, _body} ->
        {:ok, id}

      :not_found ->
        body =
          case Keyword.get(opts, :body) do
            nil -> render_template(Keyword.get(opts, :template_vars, %{}))
            value when is_binary(value) -> value
          end

        client.create_comment(to_string(issue_id), body)

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Append a dated subsection to a workpad section.

  The reviewer calls `append_section(issue_id, :adversarial_review, "PASS\\n...")`
  to add a dated `#### <timestamp> PASS` subsection at the end of the existing
  `### Adversarial Review` section. If the section header doesn't exist yet
  (e.g. first reviewer pass on a fresh ticket), the section header is created
  in canonical order and the dated subsection becomes its first entry.

  If the workpad comment itself doesn't exist yet, it is created with the
  canonical template and then the section is appended.

  ## Options

    * `:heading` - the inline heading appended after the timestamp on the
      `####` line. Defaults to `""`. For the reviewer, this is `"PASS"` or
      `"FAIL (second pass)"`.
    * `:datetime` - the `DateTime` (or any value with a `.to_iso8601/1` or
      `to_string/1` representation) used for the dated subsection. Defaults
      to `DateTime.utc_now/0`. Tests inject a fixed value for determinism.
    * `:datetime_format` - `(DateTime.t() -> String.t())` formatter. Defaults
      to `"YYYY-MM-DD HH:MM"` UTC.
    * `:client` - client module override.

  ## Return

  Returns `{:ok, comment_id}` on success (whether updating an existing comment
  or creating then updating). Errors from the client bubble up as
  `{:error, reason}`.
  """
  @spec append_section(issue_id(), section(), String.t(), keyword()) ::
          {:ok, comment_id()} | {:error, term()}
  def append_section(issue_id, section, content, opts \\ [])
      when is_atom(section) and is_binary(content) do
    unless Map.has_key?(@section_headers, section) do
      raise ArgumentError, "unknown workpad section: #{inspect(section)}"
    end

    client = resolve_client(opts)
    heading = Keyword.get(opts, :heading, "")
    datetime = Keyword.get(opts, :datetime, DateTime.utc_now())
    formatter = Keyword.get(opts, :datetime_format, &default_datetime_format/1)
    timestamp = formatter.(datetime)

    subsection = render_dated_subsection(timestamp, heading, content)

    with {:ok, comment_id, body} <- ensure_workpad(issue_id, opts),
         new_body <- insert_into_section(body, section, subsection),
         {:ok, _id} = ok <- client.update_comment(comment_id, new_body) do
      ok
    end
  end

  @doc """
  Render the canonical workpad template.

  Variables (all optional, default to empty placeholder strings):

    * `:identity` - the `<hostname>:<abs-path>@<short-sha>` identity line
    * `:plan_items` - list of strings; each becomes a `- [ ] <item>` line.
      Defaults to `["1. Parent task"]`.
    * `:acceptance_criteria` - list of strings. Defaults to `["Criterion 1"]`.
    * `:validation_items` - list of strings. Defaults to
      `["targeted tests: `<command>`"]`.
    * `:notes` - list of strings (no checkbox). Defaults to `[]`.
    * `:confusions` - list of strings. Defaults to `[]` (section omitted when
      empty, per WORKFLOW.md `<only include when something was confusing>`).

  Keys may be provided as atoms or strings; missing keys fall back to defaults.
  """
  @spec render_template(map()) :: String.t()
  def render_template(vars) when is_map(vars) do
    identity = get_var(vars, :identity, "<hostname>:<abs-path>@<short-sha>")
    plan_items = get_var(vars, :plan_items, ["1. Parent task"])
    acceptance_criteria = get_var(vars, :acceptance_criteria, ["Criterion 1"])
    validation_items = get_var(vars, :validation_items, ["targeted tests: `<command>`"])
    notes = get_var(vars, :notes, [])
    confusions = get_var(vars, :confusions, [])

    sections = [
      "## Codex Workpad",
      "",
      "```text",
      identity,
      "```",
      "",
      "### Plan",
      "",
      render_checklist(plan_items),
      "### Acceptance Criteria",
      "",
      render_checklist(acceptance_criteria),
      "### Validation",
      "",
      render_checklist(validation_items),
      "### Notes",
      "",
      render_bullets_or_placeholder(notes, "- <short progress note with timestamp>")
    ]

    sections =
      if confusions == [] do
        sections
      else
        sections ++
          [
            "### Confusions",
            "",
            render_bullets_or_placeholder(confusions, "- <only include when something was confusing>")
          ]
      end

    sections
    |> Enum.join("\n")
    |> ensure_trailing_newline()
  end

  # --- public helpers (used by tests and adapters) -------------------------

  @doc false
  @spec marker_header() :: String.t()
  def marker_header, do: @marker_header

  @doc false
  @spec section_header(section()) :: String.t()
  def section_header(section) when is_map_key(@section_headers, section) do
    "### " <> Map.fetch!(@section_headers, section)
  end

  # --- workpad detection ---------------------------------------------------

  defp workpad_comment?(%{body: body}) when is_binary(body) do
    body
    |> String.trim_leading()
    |> String.starts_with?(@marker_header)
  end

  defp workpad_comment?(_), do: false

  # --- ensure_workpad: idempotent find-or-create ---------------------------

  defp ensure_workpad(issue_id, opts) do
    case find(issue_id, opts) do
      {:ok, id, body} ->
        {:ok, id, body}

      :not_found ->
        client = resolve_client(opts)
        body = render_template(Keyword.get(opts, :template_vars, %{}))

        case client.create_comment(to_string(issue_id), body) do
          {:ok, id} -> {:ok, id, body}
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  # --- section insertion ---------------------------------------------------

  # Insert `subsection` text at the end of the named section in `body`.
  # If the section doesn't exist, the section header is created in canonical
  # order (i.e. before the next section that *does* exist downstream of it,
  # or at end-of-comment if no later section exists).
  defp insert_into_section(body, section, subsection) do
    header_line = section_header(section)
    lines = String.split(body, "\n", trim: false)

    case locate_section(lines, header_line) do
      {:found, start_idx, end_idx} ->
        insert_subsection_in_existing(lines, start_idx, end_idx, subsection)

      :not_found ->
        insert_new_section(lines, section, header_line, subsection)
    end
  end

  # locate_section returns {:found, start_idx, end_idx} where:
  #   start_idx = index of the `### <Header>` line
  #   end_idx   = index of the next `### ` line (or :eof for end of comment)
  defp locate_section(lines, header_line) do
    Enum.with_index(lines)
    |> Enum.find(fn {line, _idx} -> String.trim_trailing(line) == header_line end)
    |> case do
      nil ->
        :not_found

      {_line, start_idx} ->
        end_idx = find_next_section_index(lines, start_idx + 1)
        {:found, start_idx, end_idx}
    end
  end

  # Find the index of the next `### ` header after `from_idx`, or :eof.
  defp find_next_section_index(lines, from_idx) do
    lines
    |> Enum.drop(from_idx)
    |> Enum.with_index(from_idx)
    |> Enum.find(fn {line, _idx} ->
      trimmed = String.trim_trailing(line)
      String.starts_with?(trimmed, "### ") and not String.starts_with?(trimmed, "####")
    end)
    |> case do
      nil -> :eof
      {_line, idx} -> idx
    end
  end

  # When the section exists, insert `subsection` just before `end_idx`, after
  # trimming trailing blank lines from the section's existing content so the
  # new subsection sits flush.
  defp insert_subsection_in_existing(lines, start_idx, end_idx, subsection) do
    {before_section, rest} = Enum.split(lines, start_idx + 1)

    {section_body_with_tail, tail_starting_at_next_section} =
      case end_idx do
        :eof -> {rest, []}
        idx -> Enum.split(rest, idx - start_idx - 1)
      end

    trimmed_section_body = trim_trailing_blank_lines(section_body_with_tail)

    new_section_lines =
      trimmed_section_body
      |> append_subsection_lines(subsection)
      |> ensure_trailing_blank_before_next_section(tail_starting_at_next_section)

    (before_section ++ new_section_lines ++ tail_starting_at_next_section)
    |> Enum.join("\n")
  end

  defp append_subsection_lines(section_body_lines, subsection) do
    subsection_lines = String.split(subsection, "\n", trim: false)

    # If section_body has actual content, ensure exactly one blank line between
    # existing content and the new subsection. If it has no content yet (just
    # the blank line right after the section header), no extra separator.
    cond do
      section_body_lines == [] ->
        [""] ++ subsection_lines

      Enum.all?(section_body_lines, &(String.trim(&1) == "")) ->
        # Section header is followed only by blanks: keep one blank, then sub.
        [""] ++ subsection_lines

      true ->
        section_body_lines ++ [""] ++ subsection_lines
    end
  end

  defp ensure_trailing_blank_before_next_section(section_lines, []), do: section_lines

  defp ensure_trailing_blank_before_next_section(section_lines, _next_section_lines) do
    case List.last(section_lines) do
      "" -> section_lines
      _ -> section_lines ++ [""]
    end
  end

  defp trim_trailing_blank_lines(lines) do
    lines
    |> Enum.reverse()
    |> Enum.drop_while(&(String.trim(&1) == ""))
    |> Enum.reverse()
  end

  # When the section doesn't exist yet, insert a new `### <Section>` block in
  # canonical order (per @canonical_section_order). If no later canonical
  # section exists in the body, append at the end of the comment.
  defp insert_new_section(lines, section, header_line, subsection) do
    later_sections =
      @canonical_section_order
      |> Enum.drop_while(&(&1 != section))
      |> Enum.drop(1)

    insertion_idx = find_first_existing_section_index(lines, later_sections)

    new_section_lines =
      [header_line, ""] ++ String.split(subsection, "\n", trim: false)

    case insertion_idx do
      :append ->
        # Insert before any trailing blank lines so the comment doesn't grow
        # extra padding on each append.
        {body_lines, trailing_blanks} = split_trailing_blanks(lines)

        joined =
          body_lines
          |> ensure_one_blank_at_end()
          |> Kernel.++(new_section_lines)
          |> Kernel.++(trailing_blanks)

        Enum.join(joined, "\n")

      idx when is_integer(idx) ->
        {before_lines, after_lines} = Enum.split(lines, idx)

        joined =
          before_lines
          |> ensure_one_blank_at_end()
          |> Kernel.++(new_section_lines)
          |> Kernel.++([""])
          |> Kernel.++(after_lines)

        Enum.join(joined, "\n")
    end
  end

  defp find_first_existing_section_index(_lines, []), do: :append

  defp find_first_existing_section_index(lines, later_sections) do
    later_headers = Enum.map(later_sections, &section_header/1)

    lines
    |> Enum.with_index()
    |> Enum.find(fn {line, _idx} ->
      String.trim_trailing(line) in later_headers
    end)
    |> case do
      nil -> :append
      {_line, idx} -> idx
    end
  end

  defp split_trailing_blanks(lines) do
    reversed = Enum.reverse(lines)
    {blanks_rev, body_rev} = Enum.split_while(reversed, &(String.trim(&1) == ""))
    {Enum.reverse(body_rev), Enum.reverse(blanks_rev)}
  end

  defp ensure_one_blank_at_end([]), do: [""]

  defp ensure_one_blank_at_end(lines) do
    case List.last(lines) do
      "" -> lines
      _ -> lines ++ [""]
    end
  end

  # --- subsection rendering ------------------------------------------------

  defp render_dated_subsection(timestamp, heading, content) do
    heading_suffix =
      case String.trim(heading) do
        "" -> ""
        trimmed -> " " <> trimmed
      end

    trimmed_content =
      content
      |> String.replace_suffix("\n", "")
      |> String.trim_trailing()

    "#### " <> timestamp <> heading_suffix <> "\n\n" <> trimmed_content
  end

  defp default_datetime_format(%DateTime{} = dt) do
    truncated = DateTime.truncate(dt, :second)

    pad = fn n -> n |> Integer.to_string() |> String.pad_leading(2, "0") end

    "#{truncated.year}-#{pad.(truncated.month)}-#{pad.(truncated.day)} " <>
      "#{pad.(truncated.hour)}:#{pad.(truncated.minute)}"
  end

  defp default_datetime_format(other), do: to_string(other)

  # --- template rendering helpers ------------------------------------------

  defp render_checklist([]), do: "- [ ] \n"

  defp render_checklist(items) when is_list(items) do
    items
    |> Enum.map(fn item -> "- [ ] " <> to_string(item) end)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp render_bullets_or_placeholder([], placeholder), do: placeholder <> "\n"

  defp render_bullets_or_placeholder(items, _placeholder) when is_list(items) do
    items
    |> Enum.map(fn item -> "- " <> to_string(item) end)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp ensure_trailing_newline(string) do
    if String.ends_with?(string, "\n"), do: string, else: string <> "\n"
  end

  defp get_var(vars, key, default) when is_map(vars) do
    case Map.get(vars, key) do
      nil -> Map.get(vars, to_string(key), default)
      value -> value
    end
  end

  # --- client resolution ---------------------------------------------------

  defp resolve_client(opts) do
    case Keyword.get(opts, :client) do
      nil -> SymphonyElixir.Workpad.LinearClient
      mod when is_atom(mod) -> mod
    end
  end
end
