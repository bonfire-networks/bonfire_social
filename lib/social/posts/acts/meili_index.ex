defmodule Bonfire.Social.Posts.MeiliIndex do
  @moduledoc """
  An Act that posts a post activity to meilisearch for indexing.

  Act Options:
    * `activity` - key in assigns to find the activity, default: `:activity`
  """

  alias Bonfire.Epics.Act
  alias Bonfire.Social.Posts
  require Act

  def run(epic, act) do
    if epic.errors == [] do
      key = Keyword.get(epic.assigns.options, :activity, :activity)
      case epic.assigns[key] do
        nil ->
          Act.debug(act, "Skipping, assign #{key} is nil")
        activity ->
          Act.debug(act, "publishing to meili")
          Posts.maybe_index(activity)
      end
    else
      Act.debug(act, length(epic.errors), "Skipping because of errors")
    end
    epic
  end
end
