defmodule SymphonyElixir.RuntimeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Runtime

  describe "adapter_for/1" do
    test "resolves :codex to the existing Codex AppServer" do
      assert Runtime.adapter_for(:codex) == SymphonyElixir.Codex.AppServer
    end

    test "resolves :claude_code to the ClaudeCode AppServer module name" do
      assert Runtime.adapter_for(:claude_code) ==
               SymphonyElixir.Runtime.ClaudeCode.AppServer
    end

    test "raises FunctionClauseError for unknown runtime atoms" do
      # Use a runtime-computed atom to dodge compile-time type checking;
      # the contract under test is the runtime behavior, not the dialyzer hint.
      unknown = String.to_atom("nonexistent_runtime_" <> Integer.to_string(:rand.uniform(1000)))

      assert_raise FunctionClauseError, fn ->
        Runtime.adapter_for(unknown)
      end
    end

    test "raises FunctionClauseError for non-atom input" do
      not_an_atom = "codex" |> String.upcase() |> String.downcase()

      assert_raise FunctionClauseError, fn ->
        Runtime.adapter_for(not_an_atom)
      end
    end
  end

  describe "supported_runtimes/0" do
    test "returns the list of supported runtime atoms" do
      assert Runtime.supported_runtimes() == [:codex, :claude_code]
    end

    test "every supported runtime resolves via adapter_for/1" do
      for runtime <- Runtime.supported_runtimes() do
        assert is_atom(Runtime.adapter_for(runtime))
      end
    end
  end

  describe "behaviour contract" do
    test "declares the three lifecycle callbacks" do
      callbacks = Runtime.behaviour_info(:callbacks)

      assert {:start_session, 2} in callbacks
      assert {:run_turn, 4} in callbacks
      assert {:stop_session, 1} in callbacks
    end
  end
end
