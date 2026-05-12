defmodule SymphonyElixir.Personas.PersonaTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Personas.Persona

  @fixture_anvil_reviewer "test/support/fixtures/anvil_reviewer_persona.md"

  @min """
  ---
  name: smithy-reviewer
  description: Adversarial code reviewer
  mode: reviewer
  runtime: claude_code
  model_hint: sonnet
  ---
  You are reviewing {{identifier}}: {{title}}.

  The diff is below.
  {{diff}}
  """

  describe "parse/1" do
    test "loads minimal persona" do
      assert {:ok, persona} = Persona.parse(@min)
      assert persona.name == "smithy-reviewer"
      assert persona.description == "Adversarial code reviewer"
      assert persona.mode == :reviewer
      assert persona.runtime == :claude_code
      assert persona.model_hint == "sonnet"
      assert String.starts_with?(persona.body, "You are reviewing")
      assert String.contains?(persona.body, "{{diff}}")
    end

    test "treats mode and runtime as optional and nil-defaulted" do
      raw = """
      ---
      name: x
      description: y
      ---
      body
      """

      assert {:ok, persona} = Persona.parse(raw)
      assert persona.mode == nil
      assert persona.runtime == nil
      assert persona.model_hint == nil
    end

    test "drops unknown mode / runtime values to nil rather than crashing" do
      raw = """
      ---
      name: x
      description: y
      mode: bogus_not_a_real_atom_xyz
      runtime: also_bogus_xyz
      ---
      body
      """

      assert {:ok, persona} = Persona.parse(raw)
      assert persona.mode == nil
      assert persona.runtime == nil
    end

    test "rejects persona without frontmatter" do
      raw = "no fences here, just markdown\n"
      assert {:error, reason} = Persona.parse(raw)
      assert is_binary(reason)
      assert reason =~ "---"
    end

    test "rejects persona with unclosed frontmatter" do
      raw = "---\nname: x\ndescription: y\n"
      assert {:error, reason} = Persona.parse(raw)
      assert reason =~ "closing"
    end

    test "rejects persona missing required name" do
      raw = """
      ---
      name: ""
      description: x
      ---
      body
      """

      assert {:error, reason} = Persona.parse(raw)
      assert reason =~ "name"
    end

    test "rejects persona missing required description" do
      raw = """
      ---
      name: x
      ---
      body
      """

      assert {:error, reason} = Persona.parse(raw)
      assert reason =~ "description"
    end

    test "skips leading blank lines before opening fence" do
      raw = "\n\n---\nname: x\ndescription: y\n---\nbody\n"
      assert {:ok, persona} = Persona.parse(raw)
      assert persona.name == "x"
      assert persona.description == "y"
    end

    test "rejects empty file" do
      assert {:error, reason} = Persona.parse("")
      assert is_binary(reason)
    end

    test "rejects non-mapping YAML frontmatter" do
      raw = """
      ---
      - just
      - a
      - list
      ---
      body
      """

      assert {:error, reason} = Persona.parse(raw)
      assert reason =~ "mapping"
    end
  end

  describe "render/2" do
    test "substitutes known vars" do
      {:ok, persona} = Persona.parse(@min)

      out =
        Persona.render(persona, %{
          "identifier" => "PER-99",
          "title" => "fix the thing",
          "diff" => "@@ -1 +1 @@\n- old\n+ new\n"
        })

      assert out =~ "PER-99: fix the thing"
      assert out =~ "+ new"
      refute out =~ "{{identifier}}"
      refute out =~ "{{diff}}"
    end

    test "leaves unknown vars in place so bugs surface" do
      {:ok, persona} = Persona.parse(@min)
      out = Persona.render(persona, %{})
      assert out =~ "{{identifier}}"
      assert out =~ "{{title}}"
      assert out =~ "{{diff}}"
    end

    test "trims whitespace inside braces" do
      {:ok, persona} =
        Persona.parse("""
        ---
        name: x
        description: y
        ---
        hi {{ name }}!
        """)

      assert Persona.render(persona, %{"name" => "Shawn"}) =~ "hi Shawn!"
    end

    test "passes through `{{` without a closing pair" do
      {:ok, persona} =
        Persona.parse("""
        ---
        name: x
        description: y
        ---
        literal {{not a placeholder
        """)

      out = Persona.render(persona, %{})
      assert out =~ "{{not a placeholder"
    end

    test "renders multiple instances of the same var" do
      {:ok, persona} =
        Persona.parse("""
        ---
        name: x
        description: y
        ---
        {{x}} and {{x}} again
        """)

      assert Persona.render(persona, %{"x" => "ok"}) =~ "ok and ok again"
    end
  end

  describe "load/1" do
    test "reads and parses the anvil reviewer fixture end-to-end" do
      assert {:ok, persona} = Persona.load(@fixture_anvil_reviewer)
      assert persona.name == "anvil-reviewer"
      assert persona.description =~ "Adversarial code reviewer"
      # The anvil fixture predates the mode/runtime split, so those are nil.
      # `model_hint` survives the port verbatim.
      assert persona.model_hint == "sonnet"
      assert persona.mode == nil
      assert persona.runtime == nil

      rendered =
        Persona.render(persona, %{
          "identifier" => "PER-123",
          "title" => "refactor the widget",
          "branch" => "spike/widget",
          "workspace_path" => "/tmp/ws",
          "description" => "Make the widget better.",
          "diff" => "@@ -1 +1 @@\n- a\n+ b\n"
        })

      assert rendered =~ "PER-123"
      assert rendered =~ "refactor the widget"
      assert rendered =~ "/tmp/ws"
      assert rendered =~ "+ b"
      refute rendered =~ "{{identifier}}"
      refute rendered =~ "{{diff}}"
    end

    test "returns an error tuple for a missing file" do
      assert {:error, reason} = Persona.load("test/support/fixtures/does_not_exist.md")
      assert is_binary(reason)
      assert reason =~ "does_not_exist.md"
    end
  end
end
