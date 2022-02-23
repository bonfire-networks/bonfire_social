defmodule Bonfire.Social.Acts.Feeds do
  @moduledoc """
  Finds a list of appropriate feeds into which to post.

  Epic Options:
    * `:current_user` - current user. required.
    * `:boundary` - preset string or custom boundaries. default: nil

  Act Options:
    * `:changeset` - key in assigns to find changeset, required
  """

  alias Bonfire.Epics
  alias Bonfire.Epics.{Act, Epic}
  alias Bonfire.Social.Feeds
  alias Ecto.Changeset
  import Epics
  import Where

  def run(epic, act) do
    if epic.errors == [] do
      on = Keyword.fetch!(act.options, :on)
      changeset = epic.assigns[on]
      current_user = Keyword.fetch!(epic.assigns[:options], :current_user)
      boundary = epic.assigns[:options][:boundary]
      case changeset do
        %Changeset{valid?: true}=changeset ->
          Epics.smart(epic, act, changeset, "valid changeset")
          ids = Feeds.target_feeds(changeset, current_user, boundary)
          %{ epic | assigns: Map.update(epic.assigns, :feed_ids, ids, &(ids ++ &1)) }
        %Changeset{valid?: false}=changeset ->
          maybe_debug(epic, act, changeset, "invalid changeset")
          epic
        other ->
          error(other, "Expected changeset, got: #{inspect(other)}")
          Epic.add_error(epic, act, {:expected_changeset, other})
       end
    else
      Epics.smart(epic, act, epic.errors, "Skipping due to epic errors")
      epic
    end
  end
end
