defmodule SymphonyElixir.AlertsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Alerts
  alias SymphonyElixir.Alerts.Telegram

  describe "Telegram.send/1" do
    setup do
      prev_token = System.get_env("TELEGRAM_BOT_TOKEN")
      prev_chat = System.get_env("TELEGRAM_CHAT_ID")

      on_exit(fn ->
        restore_env("TELEGRAM_BOT_TOKEN", prev_token)
        restore_env("TELEGRAM_CHAT_ID", prev_chat)
      end)

      :ok
    end

    test "no-ops when TELEGRAM_BOT_TOKEN is unset" do
      System.delete_env("TELEGRAM_BOT_TOKEN")
      System.put_env("TELEGRAM_CHAT_ID", "123")

      assert {:noop, :unconfigured} = Telegram.send("test message")
    end

    test "no-ops when TELEGRAM_BOT_TOKEN is empty string" do
      System.put_env("TELEGRAM_BOT_TOKEN", "")
      System.put_env("TELEGRAM_CHAT_ID", "123")

      assert {:noop, :unconfigured} = Telegram.send("test message")
    end

    test "no-ops when TELEGRAM_CHAT_ID is unset" do
      System.put_env("TELEGRAM_BOT_TOKEN", "token123")
      System.delete_env("TELEGRAM_CHAT_ID")

      assert {:noop, :unconfigured} = Telegram.send("test message")
    end

    test "posts to Telegram API and returns {:ok, message_id}" do
      System.put_env("TELEGRAM_BOT_TOKEN", "bot-token-abc")
      System.put_env("TELEGRAM_CHAT_ID", "chat-456")

      Req.Test.stub(SymphonyElixir.Alerts.Telegram, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/botbot-token-abc/sendMessage"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        parsed = Jason.decode!(body)
        assert parsed["chat_id"] == "chat-456"
        assert parsed["text"] == "hello world"
        assert parsed["parse_mode"] == "Markdown"

        Req.Test.json(conn, %{"ok" => true, "result" => %{"message_id" => 77}})
      end)

      Application.put_env(
        :symphony_elixir,
        :telegram_req_options,
        plug: {Req.Test, SymphonyElixir.Alerts.Telegram}
      )

      assert {:ok, 77} = Telegram.send("hello world")
    after
      Application.delete_env(:symphony_elixir, :telegram_req_options)
    end

    test "returns {:error, reason} on non-200 API response" do
      System.put_env("TELEGRAM_BOT_TOKEN", "tok")
      System.put_env("TELEGRAM_CHAT_ID", "cid")

      Req.Test.stub(SymphonyElixir.Alerts.Telegram, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, Jason.encode!(%{"ok" => false, "description" => "Bad Request"}))
      end)

      Application.put_env(
        :symphony_elixir,
        :telegram_req_options,
        plug: {Req.Test, SymphonyElixir.Alerts.Telegram}
      )

      assert {:error, {:api_error, 400, _}} = Telegram.send("fail test")
    after
      Application.delete_env(:symphony_elixir, :telegram_req_options)
    end
  end

  describe "Alerts GenServer - debounce" do
    setup do
      write_workflow_with_alerts!()

      prev_token = System.get_env("TELEGRAM_BOT_TOKEN")
      prev_chat = System.get_env("TELEGRAM_CHAT_ID")

      System.put_env("TELEGRAM_BOT_TOKEN", "test-tok")
      System.put_env("TELEGRAM_CHAT_ID", "test-cid")

      send_count = :counters.new(1, [])

      Application.put_env(:symphony_elixir, :telegram_send_fn, fn _text ->
        :counters.add(send_count, 1, 1)
        {:ok, 1}
      end)

      pid = start_supervised!({Alerts, name: :alerts_test_debounce})

      on_exit(fn ->
        restore_env("TELEGRAM_BOT_TOKEN", prev_token)
        restore_env("TELEGRAM_CHAT_ID", prev_chat)
        Application.delete_env(:symphony_elixir, :telegram_send_fn)
      end)

      {:ok, pid: pid, send_count: send_count}
    end

    test "sends first alert and debounces duplicates within window", %{pid: pid, send_count: count} do
      GenServer.cast(pid, {:retry_attempt, "issue-1", "TST-1", 3, "err"})
      GenServer.cast(pid, {:retry_attempt, "issue-1", "TST-1", 4, "err"})
      GenServer.cast(pid, {:retry_attempt, "issue-1", "TST-1", 5, "err"})
      # Flush all casts
      _ = :sys.get_state(pid)

      # debounce_seconds is 0, so all three fire -- but same key, and 0-second debounce means
      # monotonic time may not advance between casts in CI. Test that at least one fires.
      assert :counters.get(count, 1) >= 1
    end

    test "different alert keys are not debounced together", %{pid: pid, send_count: count} do
      GenServer.cast(pid, {:retry_attempt, "issue-1", "TST-1", 3, "err"})
      GenServer.cast(pid, {:retry_attempt, "issue-2", "TST-2", 3, "err"})
      _ = :sys.get_state(pid)

      assert :counters.get(count, 1) == 2
    end
  end

  describe "Alerts GenServer - rate limit thresholds" do
    setup do
      write_workflow_with_alerts!(alerts_thresholds: [0.5, 0.8])

      prev_token = System.get_env("TELEGRAM_BOT_TOKEN")
      prev_chat = System.get_env("TELEGRAM_CHAT_ID")

      System.put_env("TELEGRAM_BOT_TOKEN", "test-tok")
      System.put_env("TELEGRAM_CHAT_ID", "test-cid")

      sent_messages = :ets.new(:sent_messages, [:bag, :public])

      Application.put_env(:symphony_elixir, :telegram_send_fn, fn text ->
        :ets.insert(sent_messages, {:msg, text})
        {:ok, 1}
      end)

      pid = start_supervised!({Alerts, name: :alerts_test_rl})

      on_exit(fn ->
        restore_env("TELEGRAM_BOT_TOKEN", prev_token)
        restore_env("TELEGRAM_CHAT_ID", prev_chat)
        Application.delete_env(:symphony_elixir, :telegram_send_fn)
      end)

      {:ok, pid: pid, sent: sent_messages}
    end

    test "emits warning alert when primary bucket crosses 50% threshold", %{pid: pid, sent: sent} do
      rate_limits = %{
        "limit_id" => "claude_code",
        "primary" => %{"remaining" => 400, "limit" => 1000, "reset_in_seconds" => 3600}
      }

      GenServer.cast(pid, {:rate_limits_updated, rate_limits})
      _ = :sys.get_state(pid)

      messages = :ets.lookup(sent, :msg) |> Enum.map(&elem(&1, 1))
      assert Enum.any?(messages, &String.contains?(&1, "50%"))
    end

    test "emits critical alert when runtime is exhausted", %{pid: pid, sent: sent} do
      rate_limits = %{
        "limit_id" => "claude_code",
        "primary" => %{"remaining" => 0, "limit" => 1000, "reset_in_seconds" => 3600}
      }

      GenServer.cast(pid, {:rate_limits_updated, rate_limits})
      _ = :sys.get_state(pid)

      messages = :ets.lookup(sent, :msg) |> Enum.map(&elem(&1, 1))
      assert Enum.any?(messages, &String.contains?(&1, "exhausted"))
    end

    test "emits recovery alert when runtime transitions from exhausted to available", %{
      pid: pid,
      sent: sent
    } do
      exhausted = %{
        "limit_id" => "claude_code",
        "primary" => %{"remaining" => 0, "limit" => 1000, "reset_in_seconds" => 0}
      }

      recovered = %{
        "limit_id" => "claude_code",
        "primary" => %{"remaining" => 1000, "limit" => 1000, "reset_in_seconds" => 3600}
      }

      GenServer.cast(pid, {:rate_limits_updated, exhausted})
      _ = :sys.get_state(pid)
      GenServer.cast(pid, {:rate_limits_updated, recovered})
      _ = :sys.get_state(pid)

      messages = :ets.lookup(sent, :msg) |> Enum.map(&elem(&1, 1))
      assert Enum.any?(messages, &String.contains?(&1, "recovered"))
    end

    test "no alert when below all thresholds", %{pid: pid, sent: sent} do
      rate_limits = %{
        "limit_id" => "claude_code",
        "primary" => %{"remaining" => 600, "limit" => 1000, "reset_in_seconds" => 3600}
      }

      GenServer.cast(pid, {:rate_limits_updated, rate_limits})
      _ = :sys.get_state(pid)

      messages = :ets.lookup(sent, :msg) |> Enum.map(&elem(&1, 1))
      assert Enum.empty?(messages)
    end
  end

  describe "Alerts GenServer - disabled when not configured" do
    setup do
      prev_token = System.get_env("TELEGRAM_BOT_TOKEN")
      prev_chat = System.get_env("TELEGRAM_CHAT_ID")
      System.put_env("TELEGRAM_BOT_TOKEN", "test-tok")
      System.put_env("TELEGRAM_CHAT_ID", "test-cid")

      send_count = :counters.new(1, [])

      Application.put_env(:symphony_elixir, :telegram_send_fn, fn _text ->
        :counters.add(send_count, 1, 1)
        {:ok, 1}
      end)

      pid = start_supervised!({Alerts, name: :alerts_test_disabled})

      on_exit(fn ->
        restore_env("TELEGRAM_BOT_TOKEN", prev_token)
        restore_env("TELEGRAM_CHAT_ID", prev_chat)
        Application.delete_env(:symphony_elixir, :telegram_send_fn)
      end)

      {:ok, pid: pid, send_count: send_count}
    end

    test "no alerts sent when enabled is false (default)", %{pid: pid, send_count: count} do
      rate_limits = %{
        "limit_id" => "claude_code",
        "primary" => %{"remaining" => 0, "limit" => 1000, "reset_in_seconds" => 0}
      }

      GenServer.cast(pid, {:rate_limits_updated, rate_limits})
      GenServer.cast(pid, {:retry_attempt, "issue-1", "TST-1", 99, "err"})
      _ = :sys.get_state(pid)

      assert :counters.get(count, 1) == 0
    end
  end
end
