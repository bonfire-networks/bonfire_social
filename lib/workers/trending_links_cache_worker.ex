# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Social.TrendingLinksCacheWorker do
  @moduledoc """
  Oban worker that warms the trending links cache periodically.

  This ensures users see cached data immediately without triggering
  slow queries from the UI. Configure in runtime.exs crontab:

      {"@hourly", Bonfire.Social.TrendingLinksCacheWorker, max_attempts: 1}
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1

  import Untangle

  @impl Oban.Worker
  def perform(_job) do
    info("Warming trending links cache...")

    case Bonfire.Social.Media.warm_cache() do
      {:ok, count} ->
        info("Trending links cache warmed with #{count} links")
        :ok

      {:error, reason} ->
        error(reason, "Failed to warm trending links cache")
        {:error, reason}
    end
  end
end
