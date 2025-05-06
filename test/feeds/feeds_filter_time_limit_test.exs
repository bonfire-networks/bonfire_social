defmodule Bonfire.Social.FeedsFilterTimeLimitTest do
  use Bonfire.Social.DataCase, async: true
  use Bonfire.Common.Utils

  alias Bonfire.Social.FeedLoader
  alias Bonfire.Social.Feeds
  alias Bonfire.Posts
  alias Bonfire.Me.Users
  import Bonfire.Social.Fake
  import Bonfire.Posts.Fake

  describe "date-based feed filtering" do
    setup do
      Process.put([:bonfire, :default_pagination_limit], 10)

      user = fake_user!("date_test_user")

      # Create posts with systematically varied dates
      # today
      today_post =
        fake_post!(user, "public", %{
          post_content: %{
            name: "Today's post",
            html_body: "This post was created today"
          }
          # id: DatesTimes.now() |> DatesTimes.generate_ulid()
        })

      # yesterday
      yesterday_post =
        fake_post!(user, "public", %{
          post_content: %{
            name: "Yesterday's post",
            html_body: "This post was created yesterday"
          },
          id: DatesTimes.past(1, :day) |> DatesTimes.generate_ulid()
        })

      # Day 3 (three days ago)
      three_days_ago_post =
        fake_post!(user, "public", %{
          post_content: %{
            name: "Three days ago post",
            html_body: "This post was created 3 days ago"
          },
          id: DatesTimes.past(3, :day) |> DatesTimes.generate_ulid()
        })

      # Day 7 (one week ago)
      week_ago_post =
        fake_post!(user, "public", %{
          post_content: %{
            name: "Week-old post",
            html_body: "This post was created a week ago"
          },
          id: DatesTimes.past(7, :day) |> DatesTimes.generate_ulid()
        })

      # Day 14 (two weeks ago)
      two_weeks_ago_post =
        fake_post!(user, "public", %{
          post_content: %{
            name: "Two weeks ago post",
            html_body: "This post was created 2 weeks ago"
          },
          id: DatesTimes.past(14, :day) |> DatesTimes.generate_ulid()
        })

      # Day 30 (a month ago)
      month_ago_post =
        fake_post!(user, "public", %{
          post_content: %{
            name: "Month-old post",
            html_body: "This post was created a month ago"
          },
          id: DatesTimes.past(30, :day) |> DatesTimes.generate_ulid()
        })

      # Day 90 (three months ago)
      three_months_ago_post =
        fake_post!(user, "public", %{
          post_content: %{
            name: "Three months ago post",
            html_body: "This post was created 3 months ago"
          },
          id: DatesTimes.past(90, :day) |> DatesTimes.generate_ulid()
        })

      # Day 365 (a year ago)
      year_ago_post =
        fake_post!(user, "public", %{
          post_content: %{
            name: "Year-old post",
            html_body: "This post was created a year ago"
          },
          id: DatesTimes.past(365, :day) |> DatesTimes.generate_ulid()
        })

      %{
        user: user,
        today_post: today_post,
        yesterday_post: yesterday_post,
        three_days_ago_post: three_days_ago_post,
        week_ago_post: week_ago_post,
        two_weeks_ago_post: two_weeks_ago_post,
        month_ago_post: month_ago_post,
        three_months_ago_post: three_months_ago_post,
        year_ago_post: year_ago_post
      }
    end

    test "filters by common time periods", %{
      user: user,
      today_post: today_post,
      yesterday_post: yesterday_post,
      three_days_ago_post: three_days_ago_post,
      week_ago_post: week_ago_post,
      month_ago_post: month_ago_post,
      three_months_ago_post: three_months_ago_post,
      year_ago_post: year_ago_post
    } do
      # Filter for posts within the last day (should only include today_post)
      feed = FeedLoader.feed(:custom, %{time_limit: 1}, current_user: user)

      assert FeedLoader.feed_contains?(feed, today_post, current_user: user)
      assert FeedLoader.feed_contains?(feed, yesterday_post, current_user: user)
      refute FeedLoader.feed_contains?(feed, three_days_ago_post, current_user: user)

      # Filter for posts within the last 2 days (should include today and yesterday)
      feed = FeedLoader.feed(:custom, %{time_limit: 2}, current_user: user)

      assert FeedLoader.feed_contains?(feed, today_post, current_user: user)
      assert FeedLoader.feed_contains?(feed, yesterday_post, current_user: user)
      refute FeedLoader.feed_contains?(feed, three_days_ago_post, current_user: user)

      # Filter for posts within the last week (7 days)
      feed = FeedLoader.feed(:custom, %{time_limit: 7}, current_user: user)

      assert FeedLoader.feed_contains?(feed, today_post, current_user: user)
      assert FeedLoader.feed_contains?(feed, week_ago_post, current_user: user)
      refute FeedLoader.feed_contains?(feed, month_ago_post, current_user: user)

      # Filter for posts within the last month (30 days)
      feed = FeedLoader.feed(:custom, %{time_limit: 30}, current_user: user)

      assert FeedLoader.feed_contains?(feed, today_post, current_user: user)
      assert FeedLoader.feed_contains?(feed, week_ago_post, current_user: user)
      assert FeedLoader.feed_contains?(feed, month_ago_post, current_user: user)
      refute FeedLoader.feed_contains?(feed, three_months_ago_post, current_user: user)

      # Filter for posts within the last year (365 days)
      feed = FeedLoader.feed(:custom, %{time_limit: 365}, current_user: user)

      assert FeedLoader.feed_contains?(feed, today_post, current_user: user)
      assert FeedLoader.feed_contains?(feed, month_ago_post, current_user: user)
      assert FeedLoader.feed_contains?(feed, three_months_ago_post, current_user: user)
      assert FeedLoader.feed_contains?(feed, year_ago_post, current_user: user)
    end

    test "handles edge cases", %{
      user: user,
      today_post: today_post
    } do
      # Test with zero value (no limit)
      feed = FeedLoader.feed(:custom, %{time_limit: 0}, current_user: user)

      assert FeedLoader.feed_contains?(feed, today_post, current_user: user)

      # Test with string numeric value
      feed = FeedLoader.feed(:custom, %{time_limit: "7"}, current_user: user)

      assert FeedLoader.feed_contains?(feed, today_post, current_user: user)

      # Test with very large value
      feed = FeedLoader.feed(:custom, %{time_limit: 100_000}, current_user: user)
    end

    test "handles invalid time_limit values", %{
      user: user,
      today_post: today_post,
      yesterday_post: yesterday_post,
      three_days_ago_post: three_days_ago_post
    } do
      # Use decimal value
      assert {:error, feed} = FeedLoader.feed(:custom, %{time_limit: 1.5}, current_user: user)

      # Test with negative value
      assert {:error, feed} = FeedLoader.feed(:custom, %{time_limit: -10}, current_user: user)

      # Test with non-numeric value 
      assert {:error, feed} =
               FeedLoader.feed(:custom, %{time_limit: "invalid"}, current_user: user)
    end
  end
end
