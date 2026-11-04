defmodule Bonfire.Social.PostContents.DocTest do
  # only the examples that run on their own: the module's other examples are illustrations that need a database and fixtures
  use Bonfire.Social.DataCase, async: true
  @moduletag :backend

  doctest Bonfire.Social.PostContents, only: [unless_repeating: 3]
end
