defmodule Smithy.AcknowledgeTest do
  use ExUnit.Case, async: false

  alias Smithy.{Acknowledge, Config}

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "smithy-ack-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    previous_home = System.get_env("HOME")
    System.put_env("HOME", tmp_dir)

    on_exit(fn ->
      if previous_home, do: System.put_env("HOME", previous_home)
      File.rm_rf!(tmp_dir)
    end)

    # Sanity check: a freshly pointed HOME has no acknowledgement.
    refute Smithy.Acknowledge.acknowledged?(),
           "test isolation broke: ack-tmp HOME #{tmp_dir} resolves to acknowledged config"

    %{tmp_dir: tmp_dir}
  end

  describe "acknowledged?/0" do
    test "false before any acknowledgement" do
      refute Acknowledge.acknowledged?()
      assert Acknowledge.required?()
    end

    test "true after :auto run" do
      assert :ok = Acknowledge.run(auto: true, puts: fn _ -> :ok end)
      assert Acknowledge.acknowledged?()
      refute Acknowledge.required?()
    end
  end

  describe "run/1 interactive" do
    test "yes records the acknowledgement with ISO8601 timestamp" do
      now = ~U[2026-05-12 14:50:00Z]
      collected = collector()

      assert :ok =
               Acknowledge.run(
                 gets: fake_gets(["yes\n"]),
                 puts: collected.puts,
                 now: fn -> now end
               )

      output = collected.fetch.()
      assert output =~ "Smithy hold-harmless acknowledgement"
      assert output =~ "Acknowledgement recorded at 2026-05-12T14:50:00Z."

      {:ok, config} = Config.load()
      assert config.acknowledged_at == "2026-05-12T14:50:00Z"
    end

    test "y accepts the shorthand" do
      assert :ok =
               Acknowledge.run(
                 gets: fake_gets(["y\n"]),
                 puts: fn _ -> :ok end,
                 now: fn -> DateTime.utc_now() end
               )

      assert Acknowledge.acknowledged?()
    end

    test "no returns :declined and persists nothing" do
      assert {:error, :declined} =
               Acknowledge.run(
                 gets: fake_gets(["no\n"]),
                 puts: fn _ -> :ok end,
                 now: fn -> DateTime.utc_now() end
               )

      refute Acknowledge.acknowledged?()
    end

    test "n accepts the shorthand" do
      assert {:error, :declined} =
               Acknowledge.run(
                 gets: fake_gets(["n\n"]),
                 puts: fn _ -> :ok end,
                 now: fn -> DateTime.utc_now() end
               )
    end

    test "EOF (Ctrl-D) declines" do
      assert {:error, :declined} =
               Acknowledge.run(
                 gets: fn _ -> :eof end,
                 puts: fn _ -> :ok end,
                 now: fn -> DateTime.utc_now() end
               )

      refute Acknowledge.acknowledged?()
    end

    test "reprompts on garbage input until clear yes/no" do
      collected = collector()

      assert :ok =
               Acknowledge.run(
                 gets: fake_gets(["maybe\n", "what?\n", "yes\n"]),
                 puts: collected.puts,
                 now: fn -> ~U[2026-05-12 15:00:00Z] end
               )

      assert Acknowledge.acknowledged?()
    end
  end

  describe "reset/0" do
    test "clears an existing acknowledgement" do
      assert :ok = Acknowledge.run(auto: true, puts: fn _ -> :ok end)
      assert Acknowledge.acknowledged?()

      assert :ok = Acknowledge.reset()
      refute Acknowledge.acknowledged?()
    end

    test "is a no-op when no acknowledgement exists" do
      refute Acknowledge.acknowledged?()
      assert :ok = Acknowledge.reset()
      refute Acknowledge.acknowledged?()
    end
  end

  # ----- test helpers -----

  defp fake_gets(responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    fn _prompt ->
      Agent.get_and_update(agent, fn
        [] -> {:eof, []}
        [next | rest] -> {next, rest}
      end)
    end
  end

  defp collector do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    %{
      puts: fn line -> Agent.update(agent, fn lines -> lines ++ [line] end) end,
      fetch: fn -> agent |> Agent.get(& &1) |> Enum.join("\n") end
    }
  end
end
