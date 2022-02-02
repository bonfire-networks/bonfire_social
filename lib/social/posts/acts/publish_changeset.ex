defmodule Bonfire.Social.Posts.PublishChangeset do
  @moduledoc """
  Creates a changeset for publishing.

  Epic Options:
    *

  Act Options:
    * `:changeset` - key to assign changeset to, default: `Bonfire.Social.Posts.PublishChangeset`
  """

  alias Bonfire.Social.Posts
  alias Bonfire.Epics.{Act, Epic}
  use Arrows
  require Act

  # TODO: figure out how to promote changeset errors so we can elide
  # doing a transaction at all but also without knackering
  # composability.

  def run(epic, act) do
    if epic.errors == [] do
      current_user = Keyword.fetch!(epic.assigns.options, :current_user)
      attrs = Keyword.fetch!(epic.assigns.options, :post_attrs)
      boundary = epic.assigns.options[:boundary]
      key = Keyword.get(act.options, :changeset, __MODULE__)
      Act.debug(act, "Assigning changeset to #{key}")
      Posts.changeset(:create, attrs, current_user, boundary)
      |> Epic.assign(epic, key, ...)
    else
      Act.debug(act, length(epic.errors), "Skipping due to epic errors")
      epic
    end
  end
end
