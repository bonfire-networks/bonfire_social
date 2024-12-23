defmodule Bonfire.Social.Feeds.DocTest do
  use Bonfire.Social.DataCase, async: true

  doctest Bonfire.Social.Feeds, import: true
  doctest Bonfire.Social.Activities, import: true
  doctest Bonfire.Social.FeedActivities, import: true
  doctest Bonfire.Social.FeedLoader, import: true
end
