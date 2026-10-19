defmodule Bonfire.Social.FeedsBlockKeywordsBenchmarkTest do
  @moduledoc """
  Cost of a user's filtered keywords on feed loading. Excluded from the normal suite (`@moduletag :benchmark`).

  The keywords are stored in each user's settings row, as in production. Do not `Process.put` the keyword key here: in test env that short-circuits `Settings.get` before the DB path and the settings load hook never runs.

  Run: `just test extensions/bonfire_social/test/feeds/feeds_block_keywords_benchmark_test.exs --only benchmark`
  """
  use Bonfire.Social.DataCase, async: false
  import Bonfire.Social.Fake
  import Bonfire.Posts.Fake

  alias Bonfire.Social.FeedLoader
  alias Bonfire.Boundaries.BlockKeywords

  @moduletag :benchmark
  @moduletag :backend
  @moduletag timeout: :infinity

  @settings_get {Bonfire.Common.Settings, :__get__, 3}
  @load_hook {BlockKeywords, :settings_load_hook_process, 1}
  @compile_patterns {BlockKeywords, :compile_patterns, 1}

  setup do
    author = fake_user!("kw_bench_author")

    for i <- 1..20 do
      body = if i <= 2, do: "Amazing deal on viagra #{i}", else: "Plain post number #{i}"
      fake_post!(author, "public", %{post_content: %{name: "Post #{i}", html_body: body}})
    end

    %{
      viewers: %{
        "0 keywords" => user_with_keywords("kw_bench_0", 0),
        "20 keywords" => user_with_keywords("kw_bench_20", 20),
        "200 keywords" => user_with_keywords("kw_bench_200", 200)
      }
    }
  end

  @tag :benchmark
  test "filtered keyword count vs Settings.get and feed loading cost", %{viewers: viewers} do
    load_feed = fn user ->
      FeedLoader.feed_postloaded(:explore, limit: 20, current_user: user)
    end

    # correctness: the keywords reach the filter through the DB path, and only for the user who set them
    refute FeedLoader.feed_contains?(
             load_feed.(viewers["200 keywords"]),
             "Amazing deal on viagra", postload: false)

    assert FeedLoader.feed_contains?(load_feed.(viewers["0 keywords"]), "Amazing deal on viagra",
             postload: false
           )

    IO.puts("\n=== calls during one feed load ===")

    for {label, user} <- Enum.sort(viewers) do
      counts =
        call_counts([@settings_get, @load_hook, @compile_patterns], fn -> load_feed.(user) end)

      IO.puts(
        "#{label}: #{inspect(counts[@settings_get])} Settings.get, " <>
          "#{inspect(counts[@load_hook])} settings_load_hook_process, " <>
          "#{inspect(counts[@compile_patterns])} compile_patterns"
      )
    end

    IO.puts("\n=== Benchee (p50/p99) ===")

    Benchee.run(
      %{
        "Settings.get unrelated key" => fn user ->
          Bonfire.Common.Settings.get([:bonfire_social, :bench_unset_key], nil,
            current_user: user
          )
        end,
        "block_keywords_settings" => fn user ->
          BlockKeywords.block_keywords_settings(current_user: user)
        end,
        "feed_postloaded :explore" => load_feed
      },
      inputs: viewers,
      warmup: 2,
      time: 5,
      percentiles: [50, 99],
      print: [fast_warning: false]
    )
  end

  defp user_with_keywords(name, count) do
    user = fake_user!(name)

    if count > 0 do
      keywords = ["viagra" | for(i <- 1..(count - 1)//1, do: "blockedword#{i}")]
      {:ok, _} = BlockKeywords.put_block_keywords_settings(keywords, current_user: user)
    end

    Bonfire.Common.Repo.preload(user, :settings, force: true)
  end

  # Counts calls to each {module, fun, arity} made by any process while `fun` runs. A function that does not exist (yet) reports `:not_defined`.
  defp call_counts(mfas, fun) do
    Enum.each(mfas, fn {mod, _, _} = mfa ->
      Code.ensure_loaded(mod)
      :erlang.trace_pattern(mfa, true, [:call_count])
    end)

    try do
      fun.()

      Map.new(mfas, fn mfa ->
        case :erlang.trace_info(mfa, :call_count) do
          {:call_count, n} when is_integer(n) -> {mfa, n}
          _ -> {mfa, :not_defined}
        end
      end)
    after
      Enum.each(mfas, &:erlang.trace_pattern(&1, false, [:call_count]))
    end
  end
end
