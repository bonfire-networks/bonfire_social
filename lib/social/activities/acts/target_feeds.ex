defmodule Bonfire.Social.Feeds.TargetFeeds do
  @moduledoc """
  Finds a list of appropriate feeds into which to post.

  Epic Options:
    * `:current_user` - current user. required.
    * `:boundary` - preset string or custom boundaries. default: nil

  Act Options:
    * `:changeset` - key in assigns to find changeset, required
  """

  alias Bonfire.Epics.Act
  alias Bonfire.Social.Feeds
  alias Ecto.Changeset
  require Act
  import Where

  def run(epic, act) do
    if epic.errors == [] do
      changeset_key = Keyword.fetch!(act.options, :changeset)
      changeset = Map.fetch!(epic.assigns, changeset_key)
      current_user = Keyword.fetch!(epic.assigns.options, :current_user)
      boundary = epic.assigns.options[:boundary]
      case changeset do
        %Changeset{valid?: true}=changeset ->
          Act.debug(act, changeset, "valid changeset")
          ids = Feeds.target_feeds(changeset, current_user, boundary)
          %{ epic | assigns: Map.update(epic.assigns, :feed_ids, ids, &(ids ++ &1)) }
        %Changeset{valid?: false}=changeset ->
          Act.debug(act, changeset, "invalid changeset")
          epic
        other ->
          error(other, "Expected changeset, got: #{inspect(other)}")
          Epic.add_error(epic, act, {:expected_changeset, other})
       end
    else
      Act.debug(act, length(epic.errors), "Skipping due to errors")
      epic
    end
  end
end
