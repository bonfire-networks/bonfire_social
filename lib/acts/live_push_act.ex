defmodule Bonfire.Social.Acts.LivePush do
  @moduledoc """
  An Act (as specified by `Bonfire.Epics`) that translates creates an activity for a object (eg. post) or changeset.

  Act Options:
    * `on` - key in assigns to find the object, default: `:post`
    * `feeds` - key
    * `notify_feeds` - key 
  """

  use Bonfire.Common.Utils
  alias Bonfire.Epics
  # alias Bonfire.Epics.Act
  alias Bonfire.Epics.Epic

  import Epics

  def run(epic, act) do
    if epic.errors == [] do
      on = Keyword.get(act.options, :on, :activity)

      case epic.assigns[on] do
        nil ->
          maybe_debug(epic, act, on, "Skipping: no activity at")
          epic

        activity ->
          ## {inspect activity}
          maybe_debug(epic, act, on, "Publishing activity at")

          feeds_key = Keyword.get(act.options, :feeds, :feed_ids)

          notify_feeds_key = Keyword.get(act.options, :notify_feeds, :notify_feeds)

          feeds = Map.get(epic.assigns, feeds_key, [])

          maybe_debug(
            epic,
            act,
            feeds,
            "Publishing to feeds at assign #{feeds_key}"
          )

          Bonfire.Social.LivePush.push_activity(
            feeds,
            activity,
            notify: Map.get(epic.assigns, notify_feeds_key, [])
          )
          |> debug("pushed")
          |> Epic.assign(epic, on, ...)
      end
    else
      maybe_debug(act, length(epic.errors), "Skipping due to errors!")
      epic
    end
  end
end
