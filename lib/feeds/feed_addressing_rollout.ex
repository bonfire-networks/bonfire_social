defmodule Bonfire.Social.Feeds.Addressing.Rollout do
  @moduledoc """
  One-shot per-instance rollout of write feed-addressing, run once per boot by
  `Bonfire.Common.StartupTasks` (see that module for the boot-time contract).

  When the `feed_addressing` WRITE flag is still off, it reclassifies the legacy origin feeds into the `(origin × boundary)` buckets (`Bonfire.Social.Feeds.Addressing.Backfill` + `.Fill`) and then flips the flag ON via instance Settings (durable in the DB + mirrored into live Config, and reloaded on subsequent boots). Gated on the flag itself: once on, this is a no-op on every later boot, so the multi-million-row reclassify never re-scans.

  Non-boot-blocking by design: the READ path is already correct without the backfill (the `:addressed` bucket union subsumes the legacy `3SERS…`/`7EDER…` feeds), so this churns in the background while the app is already serving. It only enables (a) the #1586 preset partitioning and (b) write-addressing, neither urgent.

  ⚠️ Ordering: the backfill runs with the write flag OFF (this flips it ON only at the very end), so legacy `3SERS…` rows stay unambiguously classifiable, see the `Backfill` moduledoc.
  """
  @behaviour Bonfire.Common.StartupTask
  use Bonfire.Common.Config
  require Logger

  alias Bonfire.Common.Settings
  alias Bonfire.Social.Feeds.Addressing.{Backfill, Fill}

  @flag [Bonfire.Social.Feeds, :feed_addressing]

  @impl Bonfire.Common.StartupTask
  def run do
    cond do
      not run_in_env?() ->
        Logger.info(
          "Feed-addressing rollout: skipped in the test env, where `config/test.exs` declares the end state instead."
        )

        :skip

      enabled?() ->
        Logger.info("Feed-addressing rollout: write-addressing already enabled, nothing to do.")
        :skip

      true ->
        do_run()
    end
  end

  # Ordinary test runs declare `feed_addressing` statically in `config/test.exs` (there is nothing to backfill in a fresh test DB, and a data migration writing instance Settings at boot does not mix with the Ecto sandbox). Instances booted for federation dance tests (`TEST_INSTANCE=yes`) are exempt.
  defp run_in_env?,
    do: Config.env() != :test or System.get_env("TEST_INSTANCE") == "yes"

  defp do_run do
    Logger.info(
      "Feed-addressing rollout: reclassifying legacy origin feeds into buckets (write flag still OFF)…"
    )

    Backfill.run()
    EctoSparkles.DataMigration.Runner.run(Fill)

    # flip write-addressing ON to persist to instance Settings *and* updates live Config:
    {:ok, _} = Settings.put(@flag, true, skip_boundary_check: true, scope: :instance)

    Logger.info("Feed-addressing rollout: complete — write-addressing enabled for this instance.")

    :ok
  end

  @doc "Whether write feed-addressing is already enabled for this instance."
  def enabled?, do: Config.get(@flag, false) == true
end
