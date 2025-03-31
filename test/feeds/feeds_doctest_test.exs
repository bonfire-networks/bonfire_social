defmodule Bonfire.Social.Feeds.DocTest do
  use Bonfire.Social.DataCase, async: true

  alias Bonfire.Social.FeedFilters

  doctest Bonfire.Social.Feeds, import: true
  doctest Bonfire.Social.Activities, import: true
  doctest Bonfire.Social.FeedActivities, import: true
  doctest Bonfire.Social.FeedLoader, import: true
  doctest Bonfire.Social.FeedFilters, import: true
  doctest Bonfire.Social.FeedFilters.Atom
  doctest Bonfire.Social.FeedFilters.StringList
  doctest Bonfire.Social.FeedFilters.AtomOrStringList
end
