defmodule SymphonyElixir.Telemetry.StoreTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Telemetry.{Event, Store}

  setup do
    unique = :erlang.unique_integer([:positive, :monotonic])
    dir = Path.join(System.tmp_dir!(), "smithy-telemetry-store-#{unique}")
    File.rm_rf!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "write/2" do
    test "appends an event to the correct date-partitioned file", %{dir: dir} do
      event =
        Event.build(:turn_end,
          ticket: "PER-1",
          repo_slug: "smithy",
          occurred_at: ~U[2026-05-12 10:00:00Z],
          duration_ms: 100,
          outcome: :success
        )

      assert :ok = Store.write(event, telemetry_dir: dir)

      expected = Path.join([dir, "smithy", "2026-05-12.jsonl"])
      assert File.exists?(expected)

      contents = File.read!(expected)
      assert String.ends_with?(contents, "\n")

      [line] = String.split(contents, "\n", trim: true)
      decoded = Jason.decode!(line)
      assert decoded["ticket"] == "PER-1"
      assert decoded["event"] == "turn_end"
    end

    test "creates the directory if missing", %{dir: dir} do
      refute File.exists?(dir)

      event =
        Event.build(:session_start,
          ticket: "PER-2",
          repo_slug: "smithy",
          occurred_at: ~U[2026-05-12 10:00:00Z]
        )

      assert :ok = Store.write(event, telemetry_dir: dir)
      assert File.dir?(Path.join(dir, "smithy"))
    end

    test "appends multiple events to the same file in order", %{dir: dir} do
      ev1 =
        Event.build(:turn_start,
          ticket: "PER-3",
          repo_slug: "smithy",
          occurred_at: ~U[2026-05-12 10:00:00Z]
        )

      ev2 =
        Event.build(:turn_end,
          ticket: "PER-3",
          repo_slug: "smithy",
          occurred_at: ~U[2026-05-12 10:01:00Z],
          duration_ms: 60_000,
          outcome: :success
        )

      :ok = Store.write(ev1, telemetry_dir: dir)
      :ok = Store.write(ev2, telemetry_dir: dir)

      path = Path.join([dir, "smithy", "2026-05-12.jsonl"])
      lines = path |> File.read!() |> String.split("\n", trim: true)
      assert length(lines) == 2

      assert Enum.at(lines, 0) |> Jason.decode!() |> Map.get("event") == "turn_start"
      assert Enum.at(lines, 1) |> Jason.decode!() |> Map.get("event") == "turn_end"
    end

    test "events without repo_slug land in _no_repo", %{dir: dir} do
      event = Event.build(:error, occurred_at: ~U[2026-05-12 10:00:00Z])
      :ok = Store.write(event, telemetry_dir: dir)

      assert File.exists?(Path.join([dir, "_no_repo", "2026-05-12.jsonl"]))
    end
  end

  describe "read_stream/1" do
    test "round-trips written events", %{dir: dir} do
      events =
        for i <- 1..3 do
          Event.build(:turn_end,
            ticket: "PER-#{i}",
            repo_slug: "smithy",
            occurred_at: ~U[2026-05-12 10:00:00Z],
            duration_ms: i * 100,
            outcome: :success
          )
        end

      Enum.each(events, &Store.write(&1, telemetry_dir: dir))

      read = Store.read_stream(telemetry_dir: dir) |> Enum.to_list()

      assert length(read) == 3
      tickets = Enum.map(read, & &1.ticket) |> Enum.sort()
      assert tickets == ["PER-1", "PER-2", "PER-3"]
    end

    test "filters by repo_slug", %{dir: dir} do
      Store.write(
        Event.build(:turn_end,
          ticket: "A-1",
          repo_slug: "repo-a",
          occurred_at: ~U[2026-05-12 10:00:00Z]
        ),
        telemetry_dir: dir
      )

      Store.write(
        Event.build(:turn_end,
          ticket: "B-1",
          repo_slug: "repo-b",
          occurred_at: ~U[2026-05-12 10:00:00Z]
        ),
        telemetry_dir: dir
      )

      a_only = Store.read_stream(telemetry_dir: dir, repo_slug: "repo-a") |> Enum.to_list()
      assert length(a_only) == 1
      assert hd(a_only).ticket == "A-1"
    end

    test "filters by date range", %{dir: dir} do
      Store.write(
        Event.build(:turn_end,
          ticket: "OLD",
          repo_slug: "smithy",
          occurred_at: ~U[2026-05-10 10:00:00Z]
        ),
        telemetry_dir: dir
      )

      Store.write(
        Event.build(:turn_end,
          ticket: "MID",
          repo_slug: "smithy",
          occurred_at: ~U[2026-05-12 10:00:00Z]
        ),
        telemetry_dir: dir
      )

      Store.write(
        Event.build(:turn_end,
          ticket: "NEW",
          repo_slug: "smithy",
          occurred_at: ~U[2026-05-14 10:00:00Z]
        ),
        telemetry_dir: dir
      )

      events =
        Store.read_stream(
          telemetry_dir: dir,
          from: ~D[2026-05-11],
          to: ~D[2026-05-13]
        )
        |> Enum.to_list()

      assert Enum.map(events, & &1.ticket) == ["MID"]
    end

    test "returns empty stream when directory missing", %{dir: dir} do
      assert Store.read_stream(telemetry_dir: dir) |> Enum.to_list() == []
    end

    test "skips malformed lines", %{dir: dir} do
      good_event =
        Event.build(:turn_end,
          ticket: "PER-1",
          repo_slug: "smithy",
          occurred_at: ~U[2026-05-12 10:00:00Z]
        )

      :ok = Store.write(good_event, telemetry_dir: dir)

      path = Path.join([dir, "smithy", "2026-05-12.jsonl"])
      File.write!(path, ["{garbage\n", File.read!(path)])

      events = Store.read_stream(telemetry_dir: dir) |> Enum.to_list()
      assert length(events) == 1
      assert hd(events).ticket == "PER-1"
    end
  end

  describe "list_files/1" do
    test "lists files for a single repo", %{dir: dir} do
      Store.write(
        Event.build(:turn_end,
          ticket: "PER-1",
          repo_slug: "smithy",
          occurred_at: ~U[2026-05-12 10:00:00Z]
        ),
        telemetry_dir: dir
      )

      Store.write(
        Event.build(:turn_end,
          ticket: "PER-2",
          repo_slug: "smithy",
          occurred_at: ~U[2026-05-13 10:00:00Z]
        ),
        telemetry_dir: dir
      )

      files = Store.list_files(telemetry_dir: dir, repo_slug: "smithy")
      assert length(files) == 2

      filenames = Enum.map(files, &Path.basename/1)
      assert "2026-05-12.jsonl" in filenames
      assert "2026-05-13.jsonl" in filenames
    end

    test "filters with a date window", %{dir: dir} do
      for date <- [~U[2026-05-10 10:00:00Z], ~U[2026-05-12 10:00:00Z], ~U[2026-05-14 10:00:00Z]] do
        Store.write(
          Event.build(:turn_end,
            ticket: "T",
            repo_slug: "smithy",
            occurred_at: date
          ),
          telemetry_dir: dir
        )
      end

      files =
        Store.list_files(
          telemetry_dir: dir,
          from: ~D[2026-05-11],
          to: ~D[2026-05-13]
        )

      assert Enum.map(files, &Path.basename/1) == ["2026-05-12.jsonl"]
    end

    test "returns [] for an empty/missing telemetry dir", %{dir: dir} do
      assert Store.list_files(telemetry_dir: dir) == []
    end
  end
end
