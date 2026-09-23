defmodule Bonfire.Social.FeedFiltersSchemaTest do
  @moduledoc """
  What `FeedFilters` accepts has to be the struct's own fields, no more and no less.

  Two failures this rules out, and they look nothing alike from the outside. A filter key the struct has but the accepted list forgot is dropped by `changeset/2` before any query sees it, so the filter silently does nothing; that is what a hand-written copy of the schema costs the first time the two drift, and an extension declaring a field in config could never keep such a list up to date. A key the struct does not have must still be dropped, so a typo stays a typo rather than becoming a filter nobody applies.
  """
  use Bonfire.Social.DataCase, async: true
  @moduletag :backend

  alias Bonfire.Social.FeedFilters

  test "the accepted filters are exactly the struct's fields" do
    assert FeedFilters.supported_filters() == FeedFilters.__schema__(:fields)
  end

  test "every accepted filter can be cast, so none of them is accepted in name only" do
    for field <- FeedFilters.supported_filters() do
      assert FeedFilters.__schema__(:type, field),
             "#{field} is offered as a filter but is not a field of the struct"
    end
  end

  test "a key the struct does not have is dropped rather than carried" do
    assert {:ok, filters} = FeedFilters.validate(%{no_such_filter: "surprise"})
    refute Map.has_key?(filters, :no_such_filter)
  end
end
